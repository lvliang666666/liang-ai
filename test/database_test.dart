import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;

  setUp(() async {
    db = DatabaseService.instance;
    final inMemory = await openTestDb();
    await db.initForTest(inMemory);
  });

  tearDown(() async {
    await db.close();
  });

  ChatSession session(String id, {int at = 1000}) => ChatSession(
        id: id,
        title: '会话 $id',
        createdAt: at,
        updatedAt: at,
      );

  ChatMessage message(String id, String sessionId, String role,
          {String content = '', int at = 1000}) =>
      ChatMessage(
        id: id,
        sessionId: sessionId,
        role: role,
        content: content,
        createdAt: at,
      );

  group('sessions CRUD', () {
    test('插入并按 updated_at 倒序查询', () async {
      await db.insertSession(session('s1', at: 1000));
      await db.insertSession(session('s2', at: 2000));
      await db.insertSession(session('s3', at: 3000));

      final list = await db.getAllSessions();
      expect(list.map((e) => e.id).toList(), ['s3', 's2', 's1']);
    });

    test('getSession 返回 null 当不存在', () async {
      expect(await db.getSession('nope'), isNull);
    });

    test('更新标题', () async {
      await db.insertSession(session('s1'));
      await db.updateSessionTitle('s1', '新标题');
      final s = await db.getSession('s1');
      expect(s!.title, '新标题');
    });

    test('更新档位', () async {
      await db.insertSession(session('s1'));
      await db.updateSessionEffort('s1', 'low');
      final s = await db.getSession('s1');
      expect(s!.effort, 'low');
    });

    test('删除会话级联删除消息', () async {
      await db.insertSession(session('s1'));
      await db.insertMessage(message('m1', 's1', 'user', content: '你好'));
      await db.insertMessage(message('m2', 's1', 'assistant', content: '回复'));

      await db.deleteSession('s1');

      expect(await db.getSession('s1'), isNull);
      expect(await db.getMessages('s1'), isEmpty);
    });
  });

  group('messages CRUD', () {
    test('按时间正序查询会话消息', () async {
      await db.insertSession(session('s1'));
      await db.insertMessage(message('m1', 's1', 'user', at: 3000));
      await db.insertMessage(message('m2', 's1', 'assistant', at: 1000));
      await db.insertMessage(message('m3', 's1', 'user', at: 2000));

      final list = await db.getMessages('s1');
      expect(list.map((e) => e.id).toList(), ['m2', 'm3', 'm1']);
    });

    test('不同会话消息隔离', () async {
      await db.insertSession(session('s1'));
      await db.insertSession(session('s2'));
      await db.insertMessage(message('m1', 's1', 'user'));
      await db.insertMessage(message('m2', 's2', 'user'));

      expect((await db.getMessages('s1')).length, 1);
      expect((await db.getMessages('s2')).length, 1);
    });

    test('更新消息 content 与 reasoning', () async {
      await db.insertSession(session('s1'));
      await db.insertMessage(message('m1', 's1', 'assistant'));

      await db.updateMessageContent('m1',
          content: '答案', reasoning: '思考过程');

      final m = (await db.getMessages('s1')).first;
      expect(m.content, '答案');
      expect(m.reasoning, '思考过程');
    });

    test('删除消息', () async {
      await db.insertSession(session('s1'));
      await db.insertMessage(message('m1', 's1', 'user'));

      await db.deleteMessage('m1');
      expect(await db.getMessages('s1'), isEmpty);
    });
  });

  group('schema 同源与迁移链（E2 根治验证）', () {
    test('v1 老库逐版本迁移到当前版本，schema 与新装一致', () async {
      // v1 基线建库 → 生产 onUpgrade 链升到当前版本
      final migrated = await openTestDbFromVersion(1);

      // 迁移后的表集合与新装库一致（sessions/messages/skills/providers/memories）
      final tables = await migrated.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      );
      expect(
        tables.map((r) => r['name']).toList(),
        containsAll(['sessions', 'messages', 'skills', 'providers', 'memories']),
      );
      expect(tables.length, 5); // agents 表应已在 v6 迁移中删除

      // 迁移后可正常写入读出（走一遍核心链路）
      await migrated.insert('sessions', {
        'id': 's1',
        'title': '迁移后新会话',
        'created_at': 1,
        'updated_at': 1,
      });
      expect((await migrated.query('sessions')).first['title'], '迁移后新会话');
      await migrated.close();
    });

    test('新装库含 memories 表（v7 schema 完整性）', () async {
      final fresh = await openTestDb();
      final cols = await fresh.rawQuery(
        "PRAGMA table_info(memories)",
      );
      expect(
        cols.map((c) => c['name']).toList(),
        containsAll(['id', 'content', 'tag', 'source_skill', 'created_at', 'updated_at']),
      );
      await fresh.close();
    });

    test('新装库 messages 表含 token 列（v8 schema 完整性）', () async {
      final fresh = await openTestDb();
      final cols = await fresh.rawQuery("PRAGMA table_info(messages)");
      expect(
        cols.map((c) => c['name']).toList(),
        containsAll(['prompt_tokens', 'completion_tokens']),
      );
      await fresh.close();
    });

    test('v7 老库迁移到 v8：token 列补齐，老数据保留', () async {
      // 手写 v7 历史 schema（被测对象是迁移逻辑本身），升级走生产 onUpgrade 本尊
      final dir = await databaseFactory.getDatabasesPath();
      final dbPath = '$dir/v7_to_v8_test.db';
      await databaseFactory.deleteDatabase(dbPath);
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 7),
      );
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
          created_at INTEGER NOT NULL
        )
      ''');
      await old.insert('messages', {
        'id': 'm1',
        'session_id': 's1',
        'role': 'assistant',
        'content': '老消息',
        'created_at': 1,
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

      // 老数据保留，token 列为 NULL
      final rows = await upgraded.query('messages');
      expect(rows.length, 1);
      expect(rows.first['content'], '老消息');
      expect(rows.first['prompt_tokens'], isNull);
      expect(rows.first['completion_tokens'], isNull);

      // 新列可写可读
      await upgraded.update(
        'messages',
        {'prompt_tokens': 120, 'completion_tokens': 45},
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      final updated = (await upgraded.query('messages')).first;
      expect(updated['prompt_tokens'], 120);
      expect(updated['completion_tokens'], 45);

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });
  });
}
