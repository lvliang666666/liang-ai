import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/agent.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';

/// 本地数据库服务：sessions / messages / agents 三表
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  static const _dbName = 'ai_chat.db';
  static const _dbVersion = 3;

  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  /// 测试注入用
  Future<void> initForTest(Database db) async {
    _db = db;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, _dbName),
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        effort TEXT NOT NULL DEFAULT 'max',
        agent_id TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        reasoning TEXT NOT NULL DEFAULT '',
        attachments TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_session ON messages(session_id, created_at)',
    );
    await _createAgentsTable(db);
  }

  /// 版本迁移：老用户数据无损升级
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 → v2：sessions 加 agent_id 列 + 新建 agents 表
      await db.execute('ALTER TABLE sessions ADD COLUMN agent_id TEXT');
      await _createAgentsTable(db);
    }
    if (oldVersion < 3) {
      // v2 → v3：messages 加 attachments 列（JSON 数组，旧消息默认空）
      await db.execute(
          "ALTER TABLE messages ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'");
    }
  }

  Future<void> _createAgentsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS agents (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT NOT NULL DEFAULT '🤖',
        description TEXT NOT NULL DEFAULT '',
        prompt TEXT NOT NULL DEFAULT '',
        temperature REAL,
        effort TEXT,
        is_builtin INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  // ===== Sessions =====

  Future<void> insertSession(ChatSession session) async {
    final db = await database;
    await db.insert('sessions', session.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 按更新时间倒序的会话列表
  Future<List<ChatSession>> getAllSessions() async {
    final db = await database;
    final rows = await db.query('sessions', orderBy: 'updated_at DESC');
    return rows.map(ChatSession.fromMap).toList();
  }

  Future<ChatSession?> getSession(String id) async {
    final db = await database;
    final rows = await db
        .query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ChatSession.fromMap(rows.first);
  }

  Future<void> updateSessionTitle(String id, String title) async {
    final db = await database;
    await db.update(
      'sessions',
      {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateSessionEffort(String id, String effort) async {
    final db = await database;
    await db
        .update('sessions', {'effort': effort}, where: 'id = ?', whereArgs: [id]);
  }

  /// 更新会话绑定的 Agent（null = 解绑，回到默认助手）
  Future<void> updateSessionAgent(String id, String? agentId) async {
    final db = await database;
    await db.update(
      'sessions',
      {'agent_id': agentId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> touchSession(String id) async {
    final db = await database;
    await db.update(
      'sessions',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除会话及其全部消息
  Future<void> deleteSession(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('messages', where: 'session_id = ?', whereArgs: [id]);
      await txn.delete('sessions', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ===== Messages =====

  Future<void> insertMessage(ChatMessage message) async {
    final db = await database;
    await db.insert('messages', message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 按时间正序的会话消息
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<void> updateMessageContent(String id,
      {String? content, String? reasoning}) async {
    final db = await database;
    final map = <String, Object?>{};
    if (content != null) map['content'] = content;
    if (reasoning != null) map['reasoning'] = reasoning;
    if (map.isEmpty) return;
    await db.update('messages', map, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMessage(String id) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  // ===== Agents =====

  Future<void> insertAgent(Agent agent) async {
    final db = await database;
    await db.insert('agents', agent.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全部 Agent（内置在前，自定义在后，各按名称排序）
  Future<List<Agent>> getAllAgents() async {
    final db = await database;
    final rows = await db.query(
      'agents',
      orderBy: 'is_builtin DESC, name ASC',
    );
    return rows.map(Agent.fromMap).toList();
  }

  Future<Agent?> getAgent(String id) async {
    final db = await database;
    final rows =
        await db.query('agents', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Agent.fromMap(rows.first);
  }

  Future<void> updateAgent(Agent agent) async {
    final db = await database;
    await db.update('agents', agent.toMap(),
        where: 'id = ?', whereArgs: [agent.id]);
  }

  /// 删除自定义 Agent；同时解绑引用它的会话（避免悬挂引用）
  Future<void> deleteAgent(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn
          .update('sessions', {'agent_id': null}, where: 'agent_id = ?', whereArgs: [id]);
      await txn.delete('agents', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 内置 Agent 是否已入库（首次启动种子判断）
  Future<bool> hasBuiltinAgents() async {
    final db = await database;
    final rows = await db.query('agents',
        where: 'is_builtin = 1', limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
