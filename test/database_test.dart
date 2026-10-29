import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/memory.dart';
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

    test('置顶状态落库与读回（I7）', () async {
      await db.insertSession(session('s1'));

      // 默认不置顶
      expect((await db.getSession('s1'))!.pinned, isFalse);

      // 置顶 → 落库 → 读回
      await db.setSessionPinned('s1', true);
      expect((await db.getSession('s1'))!.pinned, isTrue);

      // 取消置顶
      await db.setSessionPinned('s1', false);
      expect((await db.getSession('s1'))!.pinned, isFalse);
    });

    test('会话列表排序：置顶在前，组内按更新时间倒序（I7）', () async {
      await db.insertSession(session('s1', at: 1000));
      await db.insertSession(session('s2', at: 2000));
      await db.insertSession(session('s3', at: 3000));

      // 置顶最旧的 s1：应排到最前（其余仍按时间倒序）
      await db.setSessionPinned('s1', true);
      final list = await db.getAllSessions();
      expect(list.map((e) => e.id).toList(), ['s1', 's3', 's2']);

      // 再置顶 s2（比 s1 新）：两个置顶组内按时间倒序
      await db.setSessionPinned('s2', true);
      final list2 = await db.getAllSessions();
      expect(list2.map((e) => e.id).toList(), ['s2', 's1', 's3']);
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

    test('钉住状态落库与读回（F2）', () async {
      await db.insertSession(session('s1'));
      await db.insertMessage(message('m1', 's1', 'user', content: '关键约束'));

      // 默认不钉
      expect((await db.getMessages('s1')).first.pinned, isFalse);

      // 钉住 → 落库 → 读回
      await db.setMessagePinned('m1', true);
      final pinned = (await db.getMessages('s1')).first;
      expect(pinned.pinned, isTrue);

      // 取消钉住
      await db.setMessagePinned('m1', false);
      expect((await db.getMessages('s1')).first.pinned, isFalse);
    });

    test('钉住状态随消息序列化往返（toMap/fromMap）', () async {
      await db.insertSession(session('s1'));
      await db.insertMessage(message('m1', 's1', 'user', content: '钉住我'));

      await db.setMessagePinned('m1', true);
      final m = (await db.getMessages('s1')).first;
      expect(m.toMap()['pinned'], 1);
      expect(ChatMessage.fromMap(m.toMap()).pinned, isTrue);
    });

    test('截断删除：删除目标消息及其后全部消息（I4）', () async {
      await db.insertSession(session('s1'));
      await db.insertMessage(message('m1', 's1', 'user', content: '第一问', at: 1000));
      await db.insertMessage(message('m2', 's1', 'assistant', content: '第一答', at: 2000));
      await db.insertMessage(message('m3', 's1', 'user', content: '第二问', at: 3000));
      await db.insertMessage(message('m4', 's1', 'assistant', content: '第二答', at: 4000));

      // 从 m3 截断：m3/m4 删除，m1/m2 保留
      await db.deleteMessagesFrom('m3', 3000);
      final left = await db.getMessages('s1');
      expect(left.map((m) => m.id).toList(), ['m1', 'm2']);

      // 从 m1 截断：全删
      await db.deleteMessagesFrom('m1', 1000);
      expect(await db.getMessages('s1'), isEmpty);
    });

    test('截断删除：其他会话消息不受影响（I4）', () async {
      await db.insertSession(session('s1'));
      await db.insertSession(session('s2'));
      await db.insertMessage(message('m1', 's1', 'user', at: 1000));
      await db.insertMessage(message('m2', 's1', 'assistant', at: 2000));
      await db.insertMessage(message('n1', 's2', 'user', at: 3000));

      await db.deleteMessagesFrom('m1', 1000);
      expect(await db.getMessages('s1'), isEmpty);
      expect((await db.getMessages('s2')).length, 1);
    });
  });

  group('schema 同源与迁移链（E2 根治验证）', () {
    test('v1 老库逐版本迁移到当前版本，schema 与新装一致', () async {
      // v1 基线建库 → 生产 onUpgrade 链升到当前版本
      final migrated = await openTestDbFromVersion(1);

      // 迁移后的表集合与新装库一致（sessions/messages/skills/providers/
      // memories/http_tools/context_summaries/session_summaries）
      final tables = await migrated.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      );
      expect(
        tables.map((r) => r['name']).toList(),
        containsAll([
          'sessions',
          'messages',
          'skills',
          'providers',
          'memories',
          'http_tools',
          'context_summaries',
          'session_summaries',
        ]),
      );
      // v13 起新增 FTS5 虚表 + 影子表（_data/_idx/_content/_docsize/_config）
      // + rowid 映射表；v16 起新增 session_summaries（8 业务表 + 7 FTS 相关）
      expect(tables.length, 15); // agents 表应已在 v6 迁移中删除

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
      // 手写 v7 历史 schema（被测对象是迁移逻辑本身），升级走生产 onUpgrade 本尊。
      // sessions 表 v1 就存在，v12 迁移步会 ALTER 它
      final dir = await databaseFactory.getDatabasesPath();
      final dbPath = '$dir/v7_to_v8_test.db';
      await databaseFactory.deleteDatabase(dbPath);
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 7),
      );
      await old.execute('''
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          effort TEXT NOT NULL DEFAULT 'max',
          agent_id TEXT,
          skill_id TEXT,
          provider_id TEXT,
          model TEXT
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
          created_at INTEGER NOT NULL
        )
      ''');
      // v7 库已有 memories 表（v7 引入），迁移链 v9 步会 ALTER 它
      await old.execute('''
        CREATE TABLE memories (
          id TEXT PRIMARY KEY,
          content TEXT NOT NULL,
          tag TEXT,
          source_skill TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
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
          version: 8,
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

    test('v8 老库迁移到 v9：memories 补 pinned 列，老数据保留', () async {
      // 手写 v8 历史 schema（v8 时 memories 表还没有 pinned 列）。
      // messages 表 v1 就存在（v8 已带 token 列），v11 迁移步会 ALTER 它；
      // sessions 表 v1 就存在，v12 迁移步会 ALTER 它
      final dir = await databaseFactory.getDatabasesPath();
      final dbPath = '$dir/v8_to_v9_test.db';
      await databaseFactory.deleteDatabase(dbPath);
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 8),
      );
      await old.execute('''
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          effort TEXT NOT NULL DEFAULT 'max',
          agent_id TEXT,
          skill_id TEXT,
          provider_id TEXT,
          model TEXT
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

      // 老数据保留，pinned 为 NULL（fromMap 容错为 false）
      final rows = await upgraded.query('memories');
      expect(rows.length, 1);
      expect(rows.first['content'], '老记忆');
      expect(rows.first['pinned'], isNull);
      expect(Memory.fromMap(rows.first).pinned, isFalse);

      // 新列可写可读
      await upgraded.update(
        'memories',
        {'pinned': 1},
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      final updated = (await upgraded.query('memories')).first;
      expect(Memory.fromMap(updated).pinned, isTrue);

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('v10 老库迁移到 v11：context_summaries 表建立，老数据不受影响', () async {
      // 手写 v10 历史 schema（被测对象是迁移逻辑本身），升级走生产 onUpgrade 本尊。
      // messages 表 v1 就存在（v8 时已带 token 列），v11 迁移步会 ALTER 它；
      // sessions 表 v1 就存在，v12 迁移步会 ALTER 它
      final dir = await databaseFactory.getDatabasesPath();
      final dbPath = '$dir/v10_to_v11_test.db';
      await databaseFactory.deleteDatabase(dbPath);
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 10),
      );
      await old.execute('''
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          effort TEXT NOT NULL DEFAULT 'max',
          agent_id TEXT,
          skill_id TEXT,
          provider_id TEXT,
          model TEXT
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

      // context_summaries 表已建且可写入
      await upgraded.insert('context_summaries', {
        'id': 'c1',
        'session_id': 's1',
        'summary': '迁移后摘要',
        'first_kept_id': 'm1',
        'first_kept_at': 1,
        'created_at': 1,
      });
      final rows = await upgraded.query('context_summaries');
      expect(rows.single['summary'], '迁移后摘要');

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('v11 老库迁移到 v12：sessions 补 pinned 列，老数据保留', () async {
      // 手写 v11 历史 schema（被测对象是迁移逻辑本身），升级走生产 onUpgrade 本尊。
      // messages 表 v1 就存在（v8 时已带 token 列），v11 迁移步会 ALTER 它
      final dir = await databaseFactory.getDatabasesPath();
      final dbPath = '$dir/v11_to_v12_test.db';
      await databaseFactory.deleteDatabase(dbPath);
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 11),
      );
      await old.execute('''
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          effort TEXT NOT NULL DEFAULT 'max',
          agent_id TEXT,
          skill_id TEXT,
          provider_id TEXT,
          model TEXT
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
          pinned INTEGER NOT NULL DEFAULT 0,
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
      await old.insert('sessions', {
        'id': 's1',
        'title': '老会话',
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

      // 老数据保留，pinned 由 ALTER DEFAULT 0 回填
      final rows = await upgraded.query('sessions');
      expect(rows.single['title'], '老会话');
      expect(rows.single['pinned'], 0);
      expect(ChatSession.fromMap(rows.single).pinned, isFalse);

      // 新列可写可读
      await upgraded.update(
        'sessions',
        {'pinned': 1},
        where: 'id = ?',
        whereArgs: ['s1'],
      );
      final updated = (await upgraded.query('sessions')).first;
      expect(ChatSession.fromMap(updated).pinned, isTrue);

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('v14 老库迁移到 v15：messages 补 interrupted 列，老数据保留', () async {
      // 手写 v14 历史 schema（被测对象是迁移逻辑本身），升级走生产
      // onUpgrade 本尊。sessions/memories 表 v1/v7 就存在，后续迁移步
      // 会 ALTER 它们（v12 sessions pinned / v9 memories pinned）
      final dir = await databaseFactory.getDatabasesPath();
      final dbPath = '$dir/v14_to_v15_test.db';
      await databaseFactory.deleteDatabase(dbPath);
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 14),
      );
      await old.execute('''
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          effort TEXT NOT NULL DEFAULT 'max',
          agent_id TEXT,
          skill_id TEXT,
          provider_id TEXT,
          model TEXT,
          pinned INTEGER NOT NULL DEFAULT 0
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
          thinking_seconds INTEGER,
          generation_seconds INTEGER,
          pinned INTEGER NOT NULL DEFAULT 0,
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

      // 老数据保留，interrupted 由 ALTER DEFAULT 0 回填（老消息 = 正常收尾）
      final rows = await upgraded.query('messages');
      expect(rows.single['content'], '老消息');
      expect(rows.single['interrupted'], 0);
      expect(ChatMessage.fromMap(rows.single).interrupted, isFalse);

      // 新列可写可读
      await upgraded.update(
        'messages',
        {'interrupted': 1},
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      final updated = (await upgraded.query('messages')).first;
      expect(ChatMessage.fromMap(updated).interrupted, isTrue);

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('v15 老库迁移到 v16：新建 session_summaries 表（M4）', () async {
      // 手写 v15 历史 schema（messages 含 interrupted 列），升级走生产
      // onUpgrade 本尊。sessions/memories 表 v1/v7 就存在，后续迁移步
      // 会 ALTER 它们（v12 sessions pinned / v9 memories pinned）
      final dir = await databaseFactory.getDatabasesPath();
      final dbPath = '$dir/v15_to_v16_test.db';
      await databaseFactory.deleteDatabase(dbPath);
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 15),
      );
      await old.execute('''
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          effort TEXT NOT NULL DEFAULT 'max',
          agent_id TEXT,
          skill_id TEXT,
          provider_id TEXT,
          model TEXT,
          pinned INTEGER NOT NULL DEFAULT 0
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
          thinking_seconds INTEGER,
          generation_seconds INTEGER,
          interrupted INTEGER NOT NULL DEFAULT 0,
          pinned INTEGER NOT NULL DEFAULT 0,
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

      // session_summaries 表已建，可写可读（M4 摘要行）
      await upgraded.insert('session_summaries', {
        'id': 'ep_s1',
        'session_id': 's1',
        'title': '报销流程',
        'summary': '确认了发票要求',
        'keywords': '报销,发票',
        'created_at': 1,
      });
      final rows = await upgraded.query('session_summaries');
      expect(rows.single['title'], '报销流程');
      expect(rows.single['keywords'], '报销,发票');

      // 老消息数据无损
      final msgs = await upgraded.query('messages');
      expect(msgs.single['content'], '老消息');

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });
  });
}
