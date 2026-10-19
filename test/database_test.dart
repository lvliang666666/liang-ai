import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;

  setUp(() async {
    db = DatabaseService.instance;
    final inMemory = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (d, v) async {
        await d.execute('''
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
        await d.execute('''
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
        await d.execute(
          'CREATE INDEX idx_messages_session ON messages(session_id, created_at)',
        );
        await d.execute('''
          CREATE TABLE skills (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            icon TEXT NOT NULL DEFAULT '🤖',
            description TEXT NOT NULL DEFAULT '',
            prompt TEXT NOT NULL DEFAULT '',
            temperature REAL,
            effort TEXT,
            tools TEXT,
            is_builtin INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await d.execute('''
          CREATE TABLE providers (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            base_url TEXT NOT NULL DEFAULT '',
            api_key TEXT NOT NULL DEFAULT '',
            default_model TEXT NOT NULL DEFAULT '',
            capabilities TEXT NOT NULL DEFAULT '{}',
            dialect TEXT NOT NULL DEFAULT '{}',
            is_builtin INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
      ),
    );
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
}
