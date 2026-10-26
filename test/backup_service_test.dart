import 'dart:convert';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/http_tool.dart';
import 'package:ai_chat_app/models/memory.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/models/skill.dart';
import 'package:ai_chat_app/services/backup_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late SettingsService settings;
  late BackupService service;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);

    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    service = BackupService(database: db, settings: settings);
  });

  tearDown(() async {
    await db.close();
  });

  /// 预置全 section 数据
  Future<void> seedAll() async {
    await db.insertSession(
        ChatSession(id: 's1', title: '会话一', createdAt: 1, updatedAt: 1));
    await db.insertSession(
        ChatSession(id: 's2', title: '会话二', createdAt: 2, updatedAt: 2));
    await db.insertMessage(ChatMessage(
      id: 'm1',
      sessionId: 's1',
      role: 'user',
      content: '你好',
      promptTokens: 10,
      completionTokens: 5,
      createdAt: 1,
    ));
    await db.insertMessage(ChatMessage(
      id: 'm2',
      sessionId: 's1',
      role: 'assistant',
      content: '回复',
      createdAt: 2,
    ));
    await db.insertSkill(Skill(
      id: 'sk1',
      name: '架构师',
      prompt: '你是架构师',
      isBuiltin: true,
    ));
    await db.insertMemory(Memory(
      id: 'mem1',
      content: '用户喜欢简洁',
      createdAt: 1,
      updatedAt: 1,
    ));
    await db.insertProvider(
        ProviderProfile.builtinCompany().copyWith(apiKey: 'sk-secret'));
    await db.insertProvider(ProviderProfile(
      id: 'custom1',
      name: '自定义',
      baseUrl: 'https://x/v1',
      apiKey: 'sk-custom',
    ));
    await db.insertHttpTool(HttpTool(
      id: 'ht1',
      name: 'query_weather',
      description: '查询天气',
      urlTemplate: 'https://api.example.com/w?city={city}',
      method: 'GET',
      parametersJson: '{"city": {"type": "string"}}',
      createdAt: 1,
      updatedAt: 1,
    ));
    await settings.setThemeId('deepseek');
    await settings.setDefaultEffort('high');
    await settings.setTemperature(0.9);
    await settings.setAutoMemory(false);
  }

  group('buildBackup：导出结构', () {
    test('含全部 section 且条数正确', () async {
      await seedAll();
      final backup = await service.buildBackup();

      expect(backup['schema'], 1);
      expect(backup['exported_at'], isA<int>());
      final data = backup['data'] as Map<String, dynamic>;
      expect((data['sessions'] as List).length, 2);
      expect((data['messages'] as List).length, 2);
      expect((data['skills'] as List).length, 1);
      expect((data['memories'] as List).length, 1);
      expect((data['providers'] as List).length, 2);
      expect((data['http_tools'] as List).length, 1);
    });

    test('http_tools 段：字段完整往返', () async {
      await seedAll();
      final data =
          (await service.buildBackup())['data'] as Map<String, dynamic>;
      final t = (data['http_tools'] as List).single as Map<String, dynamic>;
      expect(t['name'], 'query_weather');
      expect(t['url_template'], 'https://api.example.com/w?city={city}');
      expect(t['method'], 'GET');
      expect(t['enabled'], 1);
    });

    test('E1 硬性要求：导出不含任何 api_key 值', () async {
      await seedAll();
      final json = jsonEncode(await service.buildBackup());

      expect(json.contains('sk-secret'), isFalse);
      expect(json.contains('sk-custom'), isFalse);
      // api_key 字段存在但值为空
      final data =
          (await service.buildBackup())['data'] as Map<String, dynamic>;
      for (final p in data['providers'] as List) {
        expect((p as Map<String, dynamic>)['api_key'], '');
      }
    });

    test('settings 段含主题/档位/温度/自动记忆开关', () async {
      await seedAll();
      final data =
          (await service.buildBackup())['data'] as Map<String, dynamic>;
      final s = data['settings'] as Map<String, dynamic>;
      expect(s['theme_id'], 'deepseek');
      expect(s['default_effort'], 'high');
      expect(s['temperature'], 0.9);
      expect(s['auto_memory'], isFalse);
    });
  });

  group('restore：导入校验与整库替换', () {
    test('导出 → 导入往返一致（清空后重灌）', () async {
      await seedAll();
      final json = jsonEncode(await service.buildBackup());

      // 清空当前库（模拟换机后空库）
      final raw = await db.database;
      for (final t in ['messages', 'sessions', 'skills', 'memories']) {
        await raw.delete(t);
      }
      expect((await raw.query('sessions')).length, 0);

      final stats = await service.restore(json);
      expect(stats.sessions, 2);
      expect(stats.messages, 2);
      expect(stats.skills, 1);
      expect(stats.memories, 1);
      expect(stats.providers, 2);
      expect(stats.httpTools, 1);

      // 数据完整
      final sessions = await db.getAllSessions();
      expect(sessions.map((s) => s.title), containsAll(['会话一', '会话二']));
      final msgs = await db.getMessages('s1');
      expect(msgs.length, 2);
      expect(msgs.first.promptTokens, 10);
      final skill = await db.getSkill('sk1');
      expect(skill!.prompt, '你是架构师');
      final mem = await db.getAllMemories();
      expect(mem.first.content, '用户喜欢简洁');
      final tools = await db.getAllHttpTools();
      expect(tools.single.name, 'query_weather');
      expect(tools.single.urlTemplate, 'https://api.example.com/w?city={city}');
    });

    test('E1 双保险：导入的 provider Key 强制为空', () async {
      await seedAll();
      final json = jsonEncode(await service.buildBackup());
      await service.restore(json);

      final providers = await db.getAllProviders();
      for (final p in providers) {
        expect(p.apiKey, '');
      }
    });

    test('schema 版本高于支持：拒绝并报错', () async {
      const json = '{"schema": 99, "data": {"sessions": [], "messages": []}}';
      expect(() => service.restore(json), throwsA(isA<BackupFormatException>()));
    });

    test('缺 data 段：拒绝', () async {
      const json = '{"schema": 1}';
      expect(() => service.restore(json), throwsA(isA<BackupFormatException>()));
    });

    test('缺 sessions/messages 段：拒绝', () async {
      const json = '{"schema": 1, "data": {"skills": []}}';
      expect(() => service.restore(json), throwsA(isA<BackupFormatException>()));
    });

    test('非法 JSON：拒绝', () async {
      expect(() => service.restore('not-json'),
          throwsA(isA<BackupFormatException>()));
    });

    test('导入后旧数据被替换（不叠加）', () async {
      await seedAll();
      final json = jsonEncode(await service.buildBackup());

      // 再塞一条新会话（导入应清掉它）
      await db.insertSession(
          ChatSession(id: 's-new', title: '新会话', createdAt: 9, updatedAt: 9));

      final stats = await service.restore(json);
      expect(stats.sessions, 2);
      final sessions = await db.getAllSessions();
      expect(sessions.map((s) => s.id), containsAll(['s1', 's2']));
      expect(sessions.map((s) => s.id), isNot(contains('s-new')));
    });
  });
}
