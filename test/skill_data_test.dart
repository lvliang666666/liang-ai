import 'package:ai_chat_app/models/skill.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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
              id TEXT PRIMARY KEY, title TEXT NOT NULL,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              effort TEXT NOT NULL DEFAULT 'max', agent_id TEXT,
              skill_id TEXT, provider_id TEXT, model TEXT
            )
          ''');
          await d.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
              content TEXT NOT NULL DEFAULT '', reasoning TEXT NOT NULL DEFAULT '',
              attachments TEXT NOT NULL DEFAULT '[]',
              tool_calls TEXT NOT NULL DEFAULT '[]', tool_call_id TEXT,
              created_at INTEGER NOT NULL
            )
          ''');
          await d.execute(
            'CREATE INDEX idx_messages_session ON messages(session_id, created_at)',
          );
          await d.execute('''
            CREATE TABLE skills (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              icon TEXT NOT NULL DEFAULT '🤖', description TEXT NOT NULL DEFAULT '',
              prompt TEXT NOT NULL DEFAULT '', temperature REAL, effort TEXT,
              tools TEXT, is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await d.execute('''
            CREATE TABLE providers (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              base_url TEXT NOT NULL DEFAULT '', api_key TEXT NOT NULL DEFAULT '',
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

  group('Skill CRUD', () {
    test('插入并按 内置在前+名称 排序查询', () async {
      await db.insertSkill(Skill(
          id: 'c1', name: '自定义', prompt: 'p', isBuiltin: false));
      await db.insertSkill(Skill(
          id: 'b1', name: '内置', prompt: 'p', isBuiltin: true));
      await db.insertSkill(Skill(
          id: 'b2', name: '阿内置', prompt: 'p', isBuiltin: true));

      final list = await db.getAllSkills();
      // SQLite 按 Unicode 码点排序：'内'(U+5185) < '阿'(U+963F)
      expect(list.map((e) => e.id).toList(), ['b1', 'b2', 'c1']);
    });

    test('getSkill 不存在返回 null', () async {
      expect(await db.getSkill('nope'), isNull);
    });

    test('toolNames 三态往返：null / 空 / 子集', () async {
      await db.insertSkill(Skill(id: 's-all', name: '全部', prompt: 'p'));
      await db.insertSkill(Skill(
          id: 's-none', name: '无', prompt: 'p', toolNames: const []));
      await db.insertSkill(Skill(
          id: 's-sub',
          name: '子集',
          prompt: 'p',
          toolNames: const ['calculate', 'get_current_time']));

      expect((await db.getSkill('s-all'))!.toolNames, isNull);
      expect((await db.getSkill('s-none'))!.toolNames, isEmpty);
      expect((await db.getSkill('s-sub'))!.toolNames,
          ['calculate', 'get_current_time']);
    });

    test('updateSkill 更新字段', () async {
      await db.insertSkill(Skill(id: 's1', name: '旧名', prompt: 'p'));
      await db.updateSkill(Skill(
          id: 's1',
          name: '新名',
          prompt: '新提示词',
          temperature: 0.4,
          toolNames: const ['calculate']));
      final s = await db.getSkill('s1');
      expect(s!.name, '新名');
      expect(s.prompt, '新提示词');
      expect(s.temperature, 0.4);
      expect(s.toolNames, ['calculate']);
    });

    test('删除 Skill 时解绑引用会话', () async {
      await db.insertSkill(Skill(id: 's1', name: 'X', prompt: 'p'));
      final d = await db.database;
      await d.insert('sessions', {
        'id': 'sess1',
        'title': 't',
        'created_at': 1,
        'updated_at': 1,
        'skill_id': 's1',
      });

      await db.deleteSkill('s1');

      expect(await db.getSkill('s1'), isNull);
      final rows = await d.query('sessions', where: 'id = ?', whereArgs: ['sess1']);
      expect((rows.first['skill_id'] as String?), isNull);
    });

    test('hasBuiltinSkills 判断', () async {
      expect(await db.hasBuiltinSkills(), isFalse);
      await db.insertSkill(Skill(id: 'b', name: '内置', prompt: 'p', isBuiltin: true));
      expect(await db.hasBuiltinSkills(), isTrue);
    });

    test('updateSessionSkill 绑定与解绑', () async {
      final d = await db.database;
      await d.insert('sessions', {
        'id': 'sess1',
        'title': 't',
        'created_at': 1,
        'updated_at': 1,
      });

      await db.updateSessionSkill('sess1', 'sk1');
      var rows = await d.query('sessions', where: 'id = ?', whereArgs: ['sess1']);
      expect(rows.first['skill_id'], 'sk1');

      await db.updateSessionSkill('sess1', null);
      rows = await d.query('sessions', where: 'id = ?', whereArgs: ['sess1']);
      expect(rows.first['skill_id'], isNull);
    });
  });

  group('数据库 v5 → v6 迁移（Agent → Skill）', () {
    test('agents 数据平移到 skills、会话绑定平移、agents 表删除', () async {
      // 用临时文件路径（:memory: 每次打开都是新库，无法模拟迁移）
      final tmpDir = await databaseFactory.getDatabasesPath();
      final dbPath = p.join(tmpDir, 'skill_migration_test.db');
      await databaseFactory.deleteDatabase(dbPath);

      // 先建一个 v5 结构的库并写入老数据
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(version: 5, onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, title TEXT NOT NULL,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              effort TEXT NOT NULL DEFAULT 'max', agent_id TEXT,
              provider_id TEXT, model TEXT
            )
          ''');
          await d.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
              content TEXT NOT NULL DEFAULT '', reasoning TEXT NOT NULL DEFAULT '',
              attachments TEXT NOT NULL DEFAULT '[]',
              tool_calls TEXT NOT NULL DEFAULT '[]', tool_call_id TEXT,
              created_at INTEGER NOT NULL
            )
          ''');
          await d.execute('''
            CREATE TABLE agents (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              icon TEXT NOT NULL DEFAULT '🤖', description TEXT NOT NULL DEFAULT '',
              prompt TEXT NOT NULL DEFAULT '', temperature REAL, effort TEXT,
              is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await d.execute('''
            CREATE TABLE providers (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              base_url TEXT NOT NULL DEFAULT '', api_key TEXT NOT NULL DEFAULT '',
              default_model TEXT NOT NULL DEFAULT '',
              capabilities TEXT NOT NULL DEFAULT '{}',
              dialect TEXT NOT NULL DEFAULT '{}',
              is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
        }),
      );
      // 老数据：内置 Agent + 自定义 Agent + 绑定会话 + 未绑定会话
      await old.insert('agents', {
        'id': 'architect',
        'name': '技术架构师',
        'icon': '🏗️',
        'description': '系统设计专家',
        'prompt': '你是架构师',
        'temperature': 0.3,
        'effort': 'high',
        'is_builtin': 1,
      });
      await old.insert('agents', {
        'id': 'myagent',
        'name': '我的助手',
        'prompt': '自定义提示词',
        'is_builtin': 0,
      });
      await old.insert('sessions', {
        'id': 'bound',
        'title': '绑定了 Agent 的会话',
        'created_at': 1,
        'updated_at': 1,
        'agent_id': 'myagent',
      });
      await old.insert('sessions', {
        'id': 'unbound',
        'title': '默认会话',
        'created_at': 2,
        'updated_at': 2,
      });
      await old.close();

      // 重新以 v6 打开，触发 onUpgrade（与 DatabaseService._onUpgrade 一致）
      final upgraded = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 6,
          onUpgrade: (d, oldV, newV) async {
            if (oldV < 6) {
              await d.execute('ALTER TABLE sessions ADD COLUMN skill_id TEXT');
              await d.execute('''
                CREATE TABLE IF NOT EXISTS skills (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL,
                  icon TEXT NOT NULL DEFAULT '🤖', description TEXT NOT NULL DEFAULT '',
                  prompt TEXT NOT NULL DEFAULT '', temperature REAL, effort TEXT,
                  tools TEXT, is_builtin INTEGER NOT NULL DEFAULT 0
                )
              ''');
              await d.execute('''
                INSERT INTO skills (id, name, icon, description, prompt,
                                    temperature, effort, tools, is_builtin)
                SELECT id, name, icon, description, prompt,
                       temperature, effort, NULL, is_builtin
                FROM agents
              ''');
              await d.execute('UPDATE sessions SET skill_id = agent_id');
              await d.execute('DROP TABLE agents');
            }
          },
        ),
      );

      // 1. agents 数据平移到 skills，tools=NULL（全部工具，保持旧行为）
      final skills = await upgraded.query('skills');
      expect(skills.length, 2);
      final architect =
          skills.firstWhere((r) => r['id'] == 'architect');
      expect(architect['name'], '技术架构师');
      expect(architect['icon'], '🏗️');
      expect(architect['prompt'], '你是架构师');
      expect(architect['temperature'], 0.3);
      expect(architect['effort'], 'high');
      expect(architect['is_builtin'], 1);
      expect(architect['tools'], isNull); // NULL = 全部工具
      final custom = skills.firstWhere((r) => r['id'] == 'myagent');
      expect(custom['name'], '我的助手');
      expect(custom['is_builtin'], 0);

      // 2. 会话绑定平移：agent_id → skill_id
      final bound = await upgraded.query('sessions', where: 'id = ?',
          whereArgs: ['bound']);
      expect(bound.first['skill_id'], 'myagent');
      final unbound = await upgraded.query('sessions', where: 'id = ?',
          whereArgs: ['unbound']);
      expect(unbound.first['skill_id'], isNull);

      // 3. agents 表已删除
      var agentsGone = false;
      try {
        await upgraded.query('agents');
      } catch (_) {
        agentsGone = true;
      }
      expect(agentsGone, isTrue);

      // 4. Skill.fromMap 能正确读取迁移后的行
      final restored = Skill.fromMap(architect);
      expect(restored.toolNames, isNull);
      expect(restored.isBuiltin, isTrue);

      await upgraded.close();
      await databaseFactory.deleteDatabase(dbPath);
    });
  });
}
