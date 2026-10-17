import 'package:flutter_test/flutter_test.dart';
import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/services/agent_parser.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('AgentParser front matter 解析', () {
    test('完整 front matter：全部字段解析正确', () {
      const doc = '''
---
name: 技术架构师
icon: 🏗️
description: 严谨的系统设计专家
temperature: 0.3
effort: high
---
你是资深软件架构师，回答注重权衡与取舍。''';

      final r = AgentParser.parse(doc);
      expect(r.name, '技术架构师');
      expect(r.icon, '🏗️');
      expect(r.description, '严谨的系统设计专家');
      expect(r.temperature, 0.3);
      expect(r.effort, 'high');
      expect(r.prompt, '你是资深软件架构师，回答注重权衡与取舍。');
    });

    test('无 front matter：整体视为 prompt', () {
      const doc = '你是一个通用助手。';
      final r = AgentParser.parse(doc);
      expect(r.name, isNull);
      expect(r.prompt, '你是一个通用助手。');
    });

    test('front matter 值带引号：自动去除', () {
      const doc = '''
---
name: "翻译官"
icon: '🌐'
---
Translate carefully.''';
      final r = AgentParser.parse(doc);
      expect(r.name, '翻译官');
      expect(r.icon, '🌐');
      expect(r.prompt, 'Translate carefully.');
    });

    test('非法 effort 值：忽略为 null', () {
      const doc = '''
---
name: X
effort: ultra
---
prompt''';
      final r = AgentParser.parse(doc);
      expect(r.effort, isNull);
    });

    test('prompt 含分隔线样式内容不受干扰', () {
      const doc = '''
---
name: X
---
第一行
---
正文里的分隔线
---''';
      final r = AgentParser.parse(doc);
      expect(r.prompt, '第一行\n---\n正文里的分隔线\n---');
    });

    test('parseToAgent 生成完整模型', () {
      const doc = '''
---
name: 文案写手
icon: ✍️
temperature: 0.8
---
你是文案专家。''';
      final agent = AgentParser.parseToAgent('copywriter', doc);
      expect(agent.id, 'copywriter');
      expect(agent.name, '文案写手');
      expect(agent.icon, '✍️');
      expect(agent.temperature, 0.8);
      expect(agent.prompt, '你是文案专家。');
      expect(agent.isBuiltin, isTrue);
    });
  });

  group('Agent 模型', () {
    test('toMap/fromMap 往返一致', () {
      final agent = Agent(
        id: 'a1',
        name: '测试',
        icon: '🧪',
        description: '描述',
        prompt: '提示词',
        temperature: 0.5,
        effort: 'low',
        isBuiltin: true,
      );
      final restored = Agent.fromMap(agent.toMap());
      expect(restored.id, 'a1');
      expect(restored.name, '测试');
      expect(restored.icon, '🧪');
      expect(restored.temperature, 0.5);
      expect(restored.effort, 'low');
      expect(restored.isBuiltin, isTrue);
    });

    test('copyAsCustom 生成非内置副本', () {
      final builtin = Agent(
        id: 'b1',
        name: '内置',
        prompt: 'p',
        isBuiltin: true,
      );
      final copy = builtin.copyAsCustom('c1');
      expect(copy.id, 'c1');
      expect(copy.isBuiltin, isFalse);
      expect(copy.name, '内置 副本');
      expect(copy.prompt, 'p');
    });
  });

  group('数据库 v2：agents 表 + sessions.agent_id', () {
    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 2, onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, title TEXT NOT NULL,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              effort TEXT NOT NULL DEFAULT 'max', agent_id TEXT
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
    });

    tearDown(() => db.close());

    test('Agent CRUD + 内置标记', () async {
      final agent = Agent(
        id: 'ag1',
        name: '自定义',
        prompt: 'p',
        temperature: 0.6,
      );
      await db.insert('agents', agent.toMap());

      final rows = await db.query('agents');
      final restored = Agent.fromMap(rows.first);
      expect(restored.name, '自定义');
      expect(restored.temperature, 0.6);
      expect(restored.isBuiltin, isFalse);

      await db.delete('agents', where: 'id = ?', whereArgs: ['ag1']);
      expect((await db.query('agents')).isEmpty, isTrue);
    });

    test('会话绑定 agent_id 并可解绑', () async {
      final session = ChatSession(
        id: 's1',
        title: 't',
        createdAt: 1,
        updatedAt: 1,
        agentId: 'ag1',
      );
      await db.insert('sessions', session.toMap());

      var rows = await db.query('sessions');
      expect(ChatSession.fromMap(rows.first).agentId, 'ag1');

      await db
          .update('sessions', {'agent_id': null}, where: 'id = ?', whereArgs: ['s1']);
      rows = await db.query('sessions');
      expect(ChatSession.fromMap(rows.first).agentId, isNull);
    });

    test('删除 Agent 时解绑引用会话', () async {
      final session = ChatSession(
          id: 's1', title: 't', createdAt: 1, updatedAt: 1, agentId: 'ag1');
      await db.insert('sessions', session.toMap());
      await db.insert('agents', {
        'id': 'ag1',
        'name': 'X',
        'prompt': 'p',
        'is_builtin': 0,
      });

      await db.transaction((txn) async {
        await txn.update('sessions', {'agent_id': null},
            where: 'agent_id = ?', whereArgs: ['ag1']);
        await txn.delete('agents', where: 'id = ?', whereArgs: ['ag1']);
      });

      final rows = await db.query('sessions');
      expect(ChatSession.fromMap(rows.first).agentId, isNull);
      expect((await db.query('agents')).isEmpty, isTrue);
    });
  });

  group('数据库 v1 → v2 迁移', () {
    test('v1 老库升级后：sessions 有 agent_id 列且老数据保留', () async {
      // 用临时文件路径（:memory: 每次打开都是新库，无法模拟迁移）
      final tmpDir = await databaseFactory.getDatabasesPath();
      final dbPath = p.join(tmpDir, 'migration_test.db');
      await databaseFactory.deleteDatabase(dbPath);

      // 先建一个 v1 结构的库并写入老数据
      final db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 1, onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, title TEXT NOT NULL,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              effort TEXT NOT NULL DEFAULT 'max'
            )
          ''');
          await db.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
              content TEXT NOT NULL DEFAULT '', reasoning TEXT NOT NULL DEFAULT '',
              created_at INTEGER NOT NULL
            )
          ''');
        }),
      );
      await db.insert('sessions', {
        'id': 'old1',
        'title': '老会话',
        'created_at': 1,
        'updated_at': 2,
        'effort': 'high',
      });
      await db.close();

      // 重新以 v2 打开，触发 onUpgrade
      final upgraded = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 2,
          onUpgrade: (db, oldV, newV) async {
            if (oldV < 2) {
              await db.execute('ALTER TABLE sessions ADD COLUMN agent_id TEXT');
              await db.execute('''
                CREATE TABLE IF NOT EXISTS agents (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL,
                  icon TEXT NOT NULL DEFAULT '🤖', description TEXT NOT NULL DEFAULT '',
                  prompt TEXT NOT NULL DEFAULT '', temperature REAL, effort TEXT,
                  is_builtin INTEGER NOT NULL DEFAULT 0
                )
              ''');
            }
          },
        ),
      );

      final rows = await upgraded.query('sessions');
      expect(rows.length, 1);
      expect(rows.first['title'], '老会话');
      expect(rows.first['effort'], 'high');
      expect(rows.first['agent_id'], isNull); // 新列默认 null

      // agents 表可用
      await upgraded.insert('agents', {
        'id': 'a',
        'name': 'N',
        'prompt': 'p',
        'is_builtin': 1,
      });
      expect((await upgraded.query('agents')).length, 1);

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });
  });
}
