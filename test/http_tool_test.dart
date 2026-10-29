import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/http_tool.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:ai_chat_app/services/tools/http_tool_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

HttpTool tool({
  String id = 't1',
  String name = 'query_weather',
  String urlTemplate = 'https://api.example.com/weather?city={city}',
  String method = 'GET',
  String headersJson = '',
  String bodyTemplate = '',
  String parametersJson = '',
  String responsePath = '',
  int maxResponseChars = 4000,
  bool enabled = true,
}) =>
  HttpTool(
    id: id,
    name: name,
    description: '查询天气',
    urlTemplate: urlTemplate,
    method: method,
    headersJson: headersJson,
    bodyTemplate: bodyTemplate,
    parametersJson: parametersJson,
    responsePath: responsePath,
    maxResponseChars: maxResponseChars,
    enabled: enabled,
    createdAt: 1000,
    updatedAt: 1000,
  );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('HttpTool 模型', () {
    test('toMap/fromMap 往返', () {
      final t = tool(
        headersJson: '{"Authorization": "Bearer abc"}',
        bodyTemplate: '{"q": "{city}"}',
        parametersJson: '{"city": {"type": "string"}}',
        responsePath: 'data.temp',
        maxResponseChars: 800,
        enabled: false,
      );
      final back = HttpTool.fromMap(t.toMap());
      expect(back.id, 't1');
      expect(back.name, 'query_weather');
      expect(back.description, '查询天气');
      expect(back.urlTemplate, 'https://api.example.com/weather?city={city}');
      expect(back.method, 'GET');
      expect(back.headersJson, '{"Authorization": "Bearer abc"}');
      expect(back.bodyTemplate, '{"q": "{city}"}');
      expect(back.parametersJson, '{"city": {"type": "string"}}');
      expect(back.responsePath, 'data.temp');
      expect(back.maxResponseChars, 800);
      expect(back.enabled, isFalse);
      expect(back.createdAt, 1000);
    });

    test('fromMap 容错：缺字段用默认值', () {
      final t = HttpTool.fromMap({'id': 'x', 'name': 'n'});
      expect(t.method, 'GET');
      expect(t.maxResponseChars, 4000);
      expect(t.enabled, isTrue);
      expect(t.urlTemplate, isEmpty);
    });

    test('placeholdersIn：提取去重保序', () {
      expect(
        HttpTool.placeholdersIn('/a/{city}/b/{city}?q={q}&r={city}'),
        ['city', 'q'],
      );
      // 非法占位符（数字开头/空）不提取
      expect(HttpTool.placeholdersIn('/{1bad}/{ }/{ok}'), ['ok']);
      // 无占位符
      expect(HttpTool.placeholdersIn('/plain'), isEmpty);
    });

    test('placeholders：URL + body 合并去重', () {
      final t = tool(
        urlTemplate: 'https://x.com/{city}/info',
        bodyTemplate: '{"q": "{city}", "unit": "{unit}"}',
      );
      expect(t.placeholders, ['city', 'unit']);
    });

    test('headers：合法 JSON 解析，坏 JSON 返回空', () {
      expect(
        tool(headersJson: '{"A": "1", "B": 2}').headers,
        {'A': '1', 'B': '2'},
      );
      expect(tool(headersJson: '不是 JSON').headers, isEmpty);
      expect(tool(headersJson: '[1,2]').headers, isEmpty);
      expect(tool(headersJson: '').headers, isEmpty);
    });

    test('parameters：合法 JSON 解析，坏 JSON 返回空', () {
      expect(
        tool(parametersJson: '{"city": {"type": "string"}}').parameters,
        {'city': {'type': 'string'}},
      );
      expect(tool(parametersJson: 'bad').parameters, isEmpty);
      // 非对象（数组）返回空
      expect(tool(parametersJson: '[1]').parameters, isEmpty);
    });

    test('parametersSchema：组装 OpenAI 格式', () {
      final schema = tool(
        parametersJson: '{"city": {"type": "string", "description": "城市"}}',
      ).parametersSchema;
      expect(schema['type'], 'object');
      expect(
        (schema['properties'] as Map)['city']['description'],
        '城市',
      );
    });

    test('isValidName：OpenAI function name 规范', () {
      expect(HttpTool.isValidName('query_weather'), isTrue);
      expect(HttpTool.isValidName('get-user-2'), isTrue);
      expect(HttpTool.isValidName(''), isFalse);
      expect(HttpTool.isValidName('带中文'), isFalse);
      expect(HttpTool.isValidName('has space'), isFalse);
      expect(HttpTool.isValidName('a' * 65), isFalse);
    });

    test('copyWith 保留不可变字段', () {
      final t = tool();
      final c = t.copyWith(name: 'new_name', enabled: false, updatedAt: 2000);
      expect(c.id, 't1');
      expect(c.createdAt, 1000);
      expect(c.name, 'new_name');
      expect(c.enabled, isFalse);
      expect(c.updatedAt, 2000);
    });
  });

  group('DB v10 http_tools 表', () {
    late DatabaseService db;

    setUp(() async {
      final inMemory = await openTestDb();
      db = DatabaseService.instance;
      await db.initForTest(inMemory);
    });

    tearDown(() async {
      await db.close();
    });

    test('CRUD 往返', () async {
      final t = tool(
        id: 'tool-1',
        headersJson: '{"Authorization": "Bearer k"}',
        parametersJson: '{"city": {"type": "string"}}',
      );
      await db.insertHttpTool(t);

      var all = await db.getAllHttpTools();
      expect(all.length, 1);
      expect(all.single.name, 'query_weather');
      expect(all.single.headersJson, '{"Authorization": "Bearer k"}');

      // update
      await db.updateHttpTool(t.copyWith(name: 'renamed', updatedAt: 2000));
      all = await db.getAllHttpTools();
      expect(all.single.name, 'renamed');

      // get
      final got = await db.getHttpTool('tool-1');
      expect(got?.name, 'renamed');
      expect(await db.getHttpTool('nope'), isNull);

      // delete
      await db.deleteHttpTool('tool-1');
      expect(await db.getAllHttpTools(), isEmpty);
    });

    test('按创建时间正序排列', () async {
      await db.insertHttpTool(tool(id: 'b', name: 'second'));
      await db.insertHttpTool(tool(id: 'a', name: 'first'));
      // 手动改 created_at 验证排序
      final d = await db.database;
      await d.update('http_tools', {'created_at': 500},
          where: 'id = ?', whereArgs: ['a']);
      final all = await db.getAllHttpTools();
      expect(all.map((t) => t.id).toList(), ['a', 'b']);
    });

    test('v9 老库迁移到 v10：http_tools 表建立，老数据不受影响', () async {
      // 手写 v9 历史 schema（被测对象是迁移逻辑本身），升级走生产 onUpgrade 本尊。
      // messages 表 v1 就存在（v8 时已带 token 列），v11 迁移步会 ALTER 它；
      // sessions 表 v12 迁移步会 ALTER（加 pinned 列），老 schema 必须带上
      final dir = await databaseFactory.getDatabasesPath();
      final dbPath = '$dir/v9_to_v10_test.db';
      await databaseFactory.deleteDatabase(dbPath);
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 9),
      );
      await old.execute('''
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          profile_id TEXT NOT NULL,
          model TEXT NOT NULL,
          effort TEXT NOT NULL DEFAULT 'max',
          temperature REAL,
          skill_id TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
      await old.execute('''
        CREATE TABLE messages (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL DEFAULT '',
          reasoning TEXT NOT NULL DEFAULT '',
          attachments TEXT NOT NULL DEFAULT '[]',
          tool_calls TEXT NOT NULL DEFAULT '[]',
          tool_call_id TEXT,
          prompt_tokens INTEGER,
          completion_tokens INTEGER,
          created_at INTEGER NOT NULL
        )
      ''');
      await old.execute('''
        CREATE TABLE memories (
          id TEXT PRIMARY KEY,
          content TEXT NOT NULL,
          tag TEXT,
          source_skill TEXT,
          pinned INTEGER,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
      await old.insert('memories', {
        'id': 'm1',
        'content': '老记忆',
        'created_at': 1,
        'updated_at': 1,
      });
      await old.close();

      final upgraded = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: DatabaseService.dbVersion,
          onCreate: DatabaseService.onCreate,
          onUpgrade: DatabaseService.onUpgrade,
        ),
      );

      // 老数据保留
      final mems = await upgraded.query('memories');
      expect(mems.single['content'], '老记忆');

      // http_tools 表已建且可写入
      await upgraded.insert('http_tools', {
        'id': 'm1',
        'name': 'migrated',
        'created_at': 1,
        'updated_at': 1,
      });
      final rows = await upgraded.query('http_tools');
      expect(rows.single['name'], 'migrated');

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });
  });

  group('ChatProvider 目录合并（T1）', () {
    late DatabaseService db;

    setUp(() async {
      final inMemory = await openTestDb();
      db = DatabaseService.instance;
      await db.initForTest(inMemory);
    });

    tearDown(() async {
      await db.close();
    });

    ChatProvider makeProvider({
      Agent? agent,
      required List<HttpTool> httpTools,
    }) =>
        ChatProvider(
          database: db,
          api: ApiService(baseUrl: 'http://127.0.0.1:1', apiKey: 'test'),
          session: ChatSession(
              id: 's1', title: 't', createdAt: 1, updatedAt: 1),
          profile: ProviderProfile.builtinCompany(),
          model: 'glm5.1',
          agent: agent,
          // 复刻 home_page 的目录组装：只取启用中的工具
          toolCatalog: [
            ...builtinTools,
            for (final t in httpTools.where((t) => t.enabled))
              HttpToolHandler(t),
          ],
        );

    test('自定义 HTTP 工具进目录：toolCount = 内置 + 自定义', () {
      final provider = makeProvider(httpTools: [
        tool(id: 'a', name: 'query_weather'),
        tool(id: 'b', name: 'nas_status'),
      ]);
      expect(provider.toolCount, builtinTools.length + 2);
      provider.dispose();
    });

    test('禁用工具不进目录', () {
      final provider = makeProvider(httpTools: [
        tool(id: 'a', name: 'on_tool', enabled: true),
        tool(id: 'b', name: 'off_tool', enabled: false),
      ]);
      expect(provider.toolCount, builtinTools.length + 1);
      provider.dispose();
    });

    test('Agent 白名单可纳管自定义工具（toolNames 子集）', () {
      final provider = makeProvider(
        agent: Agent(
            id: 'sk',
            name: 'S',
            prompt: 'p',
            toolNames: const ['query_weather', 'calculate']),
        httpTools: [tool(id: 'a', name: 'query_weather')],
      );
      expect(provider.toolCount, 2);
      provider.dispose();
    });

    test('HttpToolHandler 生成 OpenAI tools 定义', () {
      final handler = HttpToolHandler(tool(
        name: 'query_weather',
        parametersJson: '{"city": {"type": "string"}}',
      ));
      final registry = ToolRegistry()..register(handler);
      final tools = registry.toOpenAiTools();
      expect(tools.single['type'], 'function');
      final fn = tools.single['function'] as Map;
      expect(fn['name'], 'query_weather');
      expect(fn['description'], '查询天气');
      expect((fn['parameters'] as Map)['properties'], isNotEmpty);
    });
  });
}
