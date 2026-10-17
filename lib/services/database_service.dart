import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';

/// 本地数据库服务：sessions / messages 两表
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  static const _dbName = 'ai_chat.db';
  static const _dbVersion = 1;

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
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        effort TEXT NOT NULL DEFAULT 'max'
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        reasoning TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_session ON messages(session_id, created_at)',
    );
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

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
