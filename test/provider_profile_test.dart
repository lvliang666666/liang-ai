import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('ProviderProfile 模型', () {
    test('toMap/fromMap 往返一致（含 capabilities/dialect）', () {
      final profile = ProviderProfile(
        id: 'p1',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-test',
        defaultModel: 'deepseek-chat',
        capabilities: const ProviderCapabilities(
            vision: true, reasoning: true, toolCalls: true),
        dialect: const ProviderDialect(
            reasoningField: 'reasoning_content', effortParam: null),
      );
      final restored = ProviderProfile.fromMap(profile.toMap());
      expect(restored.id, 'p1');
      expect(restored.name, 'DeepSeek');
      expect(restored.baseUrl, 'https://api.deepseek.com/v1');
      expect(restored.apiKey, 'sk-test');
      expect(restored.defaultModel, 'deepseek-chat');
      expect(restored.capabilities.vision, isTrue);
      expect(restored.capabilities.reasoning, isTrue);
      expect(restored.capabilities.toolCalls, isTrue);
      expect(restored.dialect.reasoningField, 'reasoning_content');
      expect(restored.dialect.effortParam, isNull);
      expect(restored.isBuiltin, isFalse);
    });

    test('坏 JSON 字段容错：回退默认值不崩溃', () {
      final restored = ProviderProfile.fromMap({
        'id': 'p1',
        'name': 'X',
        'capabilities': 'not-a-map',
        'dialect': 123,
      });
      expect(restored.capabilities.vision, isFalse);
      expect(restored.dialect.reasoningField, isNull);
    });

    test('内置公司 profile：glm 方言 + 视觉/思考/工具能力，Key 为空', () {
      final p = ProviderProfile.builtinCompany();
      expect(p.id, ProviderProfile.builtinCompanyId);
      expect(p.isBuiltin, isTrue);
      expect(p.apiKey, ''); // 凭据不入代码库
      expect(p.capabilities.vision, isTrue);
      expect(p.capabilities.reasoning, isTrue);
      expect(p.capabilities.toolCalls, isTrue); // v1.6.0 工具调用
      expect(p.dialect.effortParam, 'reasoning_effort');
      expect(p.dialect.reasoningField, 'reasoning');
    });

    test('copyWith 不可变更新', () {
      final p = ProviderProfile.builtinCompany();
      final updated = p.copyWith(name: '改名', apiKey: 'new-key');
      expect(updated.name, '改名');
      expect(updated.apiKey, 'new-key');
      expect(updated.id, p.id);
      expect(updated.isBuiltin, isTrue);
    });
  });

  group('数据库 v4：providers 表 + 会话绑定', () {
    late DatabaseService db;

    setUp(() async {
      db = DatabaseService.instance;
      final inMemory = await openTestDb();
      await db.initForTest(inMemory);
    });

    tearDown(() async {
      await db.close();
    });

    test('Provider CRUD + 内置排序在前', () async {
      await db.insertProvider(ProviderProfile.builtinCompany());
      await db.insertProvider(ProviderProfile(
        id: 'custom1',
        name: 'A 自定义',
        baseUrl: 'https://x.example.com/v1',
      ));

      final all = await db.getAllProviders();
      expect(all.length, 2);
      expect(all.first.id, ProviderProfile.builtinCompanyId); // 内置在前
      expect(all.last.id, 'custom1');

      // 更新
      await db.updateProvider(all.last.copyWith(name: 'B 改名'));
      expect((await db.getProvider('custom1'))!.name, 'B 改名');

      // 删除
      await db.deleteProvider('custom1');
      expect(await db.getProvider('custom1'), isNull);
    });

    test('capabilities/dialect JSON 序列化往返', () async {
      final profile = ProviderProfile(
        id: 'p1',
        name: 'X',
        baseUrl: 'https://x/v1',
        capabilities: const ProviderCapabilities(vision: true),
        dialect: const ProviderDialect(
            reasoningField: 'reasoning_content', effortParam: 'reasoning_effort'),
      );
      await db.insertProvider(profile);
      final restored = (await db.getProvider('p1'))!;
      expect(restored.capabilities.vision, isTrue);
      expect(restored.capabilities.reasoning, isFalse);
      expect(restored.dialect.reasoningField, 'reasoning_content');
      expect(restored.dialect.effortParam, 'reasoning_effort');
    });

    test('删除供应商时解绑引用会话', () async {
      await db.insertProvider(ProviderProfile.builtinCompany());
      await db.insertProvider(ProviderProfile(
        id: 'custom1',
        name: '自定义',
        baseUrl: 'https://x/v1',
      ));
      final session = ChatSession(
        id: 's1',
        title: 't',
        createdAt: 1,
        updatedAt: 1,
        providerId: 'custom1',
        model: 'some-model',
      );
      await db.insertSession(session);

      await db.deleteProvider('custom1');

      final rows = await db.getAllSessions();
      expect(rows.first.providerId, isNull);
      expect(rows.first.model, isNull);
    });

    test('updateSessionProvider 更新会话绑定', () async {
      final session = ChatSession(
          id: 's1', title: 't', createdAt: 1, updatedAt: 1);
      await db.insertSession(session);

      await db.updateSessionProvider('s1', 'p2', 'model-x');
      final updated = (await db.getSession('s1'))!;
      expect(updated.providerId, 'p2');
      expect(updated.model, 'model-x');

      await db.updateSessionProvider('s1', null, null);
      final reset = (await db.getSession('s1'))!;
      expect(reset.providerId, isNull);
      expect(reset.model, isNull);
    });

    test('hasBuiltinProviders 种子判断', () async {
      expect(await db.hasBuiltinProviders(), isFalse);
      await db.insertProvider(ProviderProfile.builtinCompany());
      expect(await db.hasBuiltinProviders(), isTrue);
    });

    test('能力升级：老种子缺 toolCalls 补写，其他字段不动', () async {
      // 模拟 v1.5.0 老种子：capabilities JSON 缺 tool_calls 位
      final oldProfile = ProviderProfile.builtinCompany().copyWith(
        apiKey: 'sk-legacy',
        capabilities: const ProviderCapabilities(
            vision: true, reasoning: true),
      );
      await db.insertProvider(oldProfile);

      await db.upgradeBuiltinProviderCapabilities();

      final upgraded = (await db.getProvider(
              ProviderProfile.builtinCompanyId))!;
      expect(upgraded.capabilities.toolCalls, isTrue); // 补上了
      expect(upgraded.capabilities.vision, isTrue); // 原有能力保留
      expect(upgraded.capabilities.reasoning, isTrue);
      expect(upgraded.apiKey, 'sk-legacy'); // 凭据不动
      expect(upgraded.dialect.effortParam, 'reasoning_effort');
    });

    test('能力升级幂等：已齐全的 profile 再跑一遍不变', () async {
      await db.insertProvider(ProviderProfile.builtinCompany());

      await db.upgradeBuiltinProviderCapabilities();
      await db.upgradeBuiltinProviderCapabilities(); // 跑两遍

      final p = (await db.getProvider(
              ProviderProfile.builtinCompanyId))!;
      expect(p.capabilities.toolCalls, isTrue);
      expect(p.capabilities.vision, isTrue);
      expect(p.capabilities.reasoning, isTrue);
    });

    test('能力升级不碰自定义供应商', () async {
      final custom = ProviderProfile(
        id: 'custom1',
        name: '自定义',
        baseUrl: 'https://x/v1',
        // 自定义供应商故意不开 toolCalls（用户自己的选择）
      );
      await db.insertProvider(custom);

      await db.upgradeBuiltinProviderCapabilities();

      final p = (await db.getProvider('custom1'))!;
      expect(p.capabilities.toolCalls, isFalse); // 未被误改
    });
  });

  group('数据库 v3 → v4 迁移', () {
    test('v3 老库升级后：sessions 有新列且老数据保留', () async {
      final tmpDir = await databaseFactory.getDatabasesPath();
      final dbPath = p.join(tmpDir, 'migration_v4_test.db');
      await databaseFactory.deleteDatabase(dbPath);

      // 建 v3 结构的库并写入老数据
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 3,
            onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, title TEXT NOT NULL,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              effort TEXT NOT NULL DEFAULT 'max', agent_id TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
              content TEXT NOT NULL DEFAULT '', reasoning TEXT NOT NULL DEFAULT '',
              attachments TEXT NOT NULL DEFAULT '[]',
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE agents (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              icon TEXT NOT NULL DEFAULT '🤖', description TEXT NOT NULL DEFAULT '',
              prompt TEXT NOT NULL DEFAULT '', temperature REAL, effort TEXT,
              is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
        }),
      );
      await old.insert('sessions', {
        'id': 'old1',
        'title': '老会话',
        'created_at': 1,
        'updated_at': 2,
        'effort': 'high',
        'agent_id': 'ag1',
      });
      await old.close();

      // 以 v4 打开，触发生产 onUpgrade 本尊（v3→v4 迁移链）
      final upgraded = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 4,
          onUpgrade: DatabaseService.onUpgrade,
        ),
      );

      final rows = await upgraded.query('sessions');
      expect(rows.length, 1);
      expect(rows.first['title'], '老会话');
      expect(rows.first['agent_id'], 'ag1'); // 老数据保留
      expect(rows.first['provider_id'], isNull); // 新列默认 null
      expect(rows.first['model'], isNull);

      // providers 表可用
      await upgraded.insert('providers', {
        'id': 'p',
        'name': 'N',
        'is_builtin': 1,
      });
      expect((await upgraded.query('providers')).length, 1);

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });
  });

  group('SseParser 方言参数化', () {
    test('reasoningField=null：不解析思考流', () {
      final parser = SseParser(reasoningField: null);
      final events = parser.addChunk(
          'data: {"choices":[{"delta":{"reasoning":"思考","content":"正文"}}]}\n\n');
      expect(events.whereType<SseDeltaReasoning>(), isEmpty);
      expect(events.whereType<SseDeltaContent>().single.text, '正文');
    });

    test('reasoningField=reasoning_content：DeepSeek 方言', () {
      final parser = SseParser(reasoningField: 'reasoning_content');
      final events = parser.addChunk(
          'data: {"choices":[{"delta":{"reasoning_content":"思考","content":"正文"}}]}\n\n');
      expect(events.whereType<SseDeltaReasoning>().single.text, '思考');
      expect(events.whereType<SseDeltaContent>().single.text, '正文');
    });

    test('默认构造：reasoning 字段 + reasoning_content 备用兼容', () {
      final parser = SseParser();
      final events = parser.addChunk(
          'data: {"choices":[{"delta":{"reasoning_content":"备用"}}]}\n\n');
      expect(events.whereType<SseDeltaReasoning>().single.text, '备用');
    });
  });

  group('ApiService 请求体方言组装', () {
    test('glm 方言：发送 chat_template_kwargs', () {
      final body = ApiService.buildBodyForTest(
        profile: ProviderProfile.builtinCompany(),
        messages: const [],
        model: 'glm5.1',
        effort: 'high',
        temperature: 0.7,
      );
      expect(body['chat_template_kwargs'], {'reasoning_effort': 'high'});
      expect(body['model'], 'glm5.1');
      expect(body['stream'], isTrue);
    });

    test('无 effortParam 方言：不发送推理档位参数', () {
      final body = ApiService.buildBodyForTest(
        profile: ProviderProfile(
          id: 'p',
          name: 'X',
          baseUrl: 'https://x/v1',
          dialect: const ProviderDialect(effortParam: null),
        ),
        messages: const [],
        model: 'deepseek-chat',
        effort: 'high',
        temperature: 0.7,
      );
      expect(body.containsKey('chat_template_kwargs'), isFalse);
    });
  });
}
