import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/context_summary.dart';
import '../models/http_tool.dart';
import '../models/memory.dart';
import '../models/provider_profile.dart';
import '../models/skill.dart';
import 'secure_key_store.dart';

/// 本地数据库服务：sessions / messages / skills / providers / memories /
/// http_tools / context_summaries 七表
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  static const _dbName = 'ai_chat.db';

  /// 当前数据库版本号（公开给测试 fixture：测试库与生产同版本同源）
  static const int dbVersion = 12;

  /// E6 API Key 加固桥（null = 未启用，行为与 v2.3.7 完全一致）。
  /// 生产在 main 启动时注入 [SecureKeyStore]；测试不注入或注入 fake。
  static SecureKeyBridge? keyBridge;

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
      version: dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 建表入口（公开给测试 fixture：测试库直接跑生产建表逻辑，
  /// schema 与生产同源，杜绝手写 CREATE TABLE 漂移）
  static Future<void> onCreate(Database db, int version) => _onCreate(db, version);

  /// 迁移入口（公开给测试 fixture：迁移测试直接跑生产迁移链）
  static Future<void> onUpgrade(Database db, int oldVersion, int newVersion) =>
      _onUpgrade(db, oldVersion, newVersion);

  static Future<void> _onCreate(Database db, int version) async {
    // 注意：这里建的是「当前版本」的完整 schema。老版本升级路径由
    // _onUpgrade 覆盖（v1 老库 → 逐版本迁移上来），两条路径都必须维护。
    await db.execute('''
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
    await db.execute('''
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
    await db.execute(
      'CREATE INDEX idx_messages_session ON messages(session_id, created_at)',
    );
    await _createSkillsTable(db);
    await _createProvidersTable(db);
    await _createMemoriesTable(db);
    await _createHttpToolsTable(db);
    await _createContextSummariesTable(db);
  }

  /// 版本迁移：老用户数据无损升级
  ///
  /// 每步双条件：`oldVersion < N`（库还没到过第 N 版）且
  /// `newVersion >= N`（本次目标版本包含第 N 版）——测试会用中间
  /// 版本号打开老库（如 v2→v5），不设上界会把后续步骤也跑一遍，
  /// 在「老库缺新表」的测试 schema 上炸 duplicate/no such column。
  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2 && newVersion >= 2) {
      // v1 → v2：sessions 加 agent_id 列 + 新建 agents 表
      await db.execute('ALTER TABLE sessions ADD COLUMN agent_id TEXT');
      await _createAgentsTable(db);
    }
    if (oldVersion < 3 && newVersion >= 3) {
      // v2 → v3：messages 加 attachments 列（JSON 数组，旧消息默认空）
      await db.execute(
          "ALTER TABLE messages ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'");
    }
    if (oldVersion < 4 && newVersion >= 4) {
      // v3 → v4：多供应商——sessions 加 provider_id/model 列 + 新建 providers 表
      await db.execute('ALTER TABLE sessions ADD COLUMN provider_id TEXT');
      await db.execute('ALTER TABLE sessions ADD COLUMN model TEXT');
      await _createProvidersTable(db);
    }
    if (oldVersion < 5 && newVersion >= 5) {
      // v4 → v5：工具调用——messages 加 tool_calls（JSON 数组）与
      // tool_call_id（tool 结果消息关联）列
      await db.execute(
          "ALTER TABLE messages ADD COLUMN tool_calls TEXT NOT NULL DEFAULT '[]'");
      await db.execute('ALTER TABLE messages ADD COLUMN tool_call_id TEXT');
    }
    if (oldVersion < 6 && newVersion >= 6) {
      // v5 → v6：Skill 取代 Agent——agents 数据平移到 skills 表
      //（tools=NULL=全部工具，保持 v1.6.0 行为），会话绑定 agent_id → skill_id，
      // agent_id 列保留不删但不再使用
      await db.execute('ALTER TABLE sessions ADD COLUMN skill_id TEXT');
      await _createSkillsTable(db);
      await db.execute('''
        INSERT INTO skills (id, name, icon, description, prompt,
                            temperature, effort, tools, is_builtin)
        SELECT id, name, icon, description, prompt,
               temperature, effort, NULL, is_builtin
        FROM agents
      ''');
      await db.execute('UPDATE sessions SET skill_id = agent_id');
      await db.execute('DROP TABLE agents');
    }
    if (oldVersion < 7 && newVersion >= 7) {
      // v6 → v7：记忆系统——新建 memories 表（全局共享记忆池）
      await _createMemoriesTable(db);
    }
    if (oldVersion < 8 && newVersion >= 8) {
      // v7 → v8：Token 水位仪表盘（F3）——messages 加 prompt/completion
      // token 列（usage 末帧或本地估算；NULL = 老数据/未统计）
      await db.execute('ALTER TABLE messages ADD COLUMN prompt_tokens INTEGER');
      await db.execute(
          'ALTER TABLE messages ADD COLUMN completion_tokens INTEGER');
    }
    if (oldVersion < 9 && newVersion >= 9) {
      // v8 → v9：记忆策展台（M1）——memories 加 pinned 列
      //（用户置顶 = 永久记忆：注入排最前、不占名额、不参与滚动压缩）
      // 跨多版本直升（如 v2→v9）时 memories 表由 v7 步新建、已含 pinned，
      // ALTER 会 duplicate column——先查列存在性再补
      final cols = await db.rawQuery('PRAGMA table_info(memories)');
      final hasPinned = cols.any((c) => c['name'] == 'pinned');
      if (!hasPinned) {
        await db.execute('ALTER TABLE memories ADD COLUMN pinned INTEGER');
      }
    }
    if (oldVersion < 10 && newVersion >= 10) {
      // v9 → v10：自定义 HTTP 工具（T1）——新建 http_tools 表
      await _createHttpToolsTable(db);
    }
    if (oldVersion < 11 && newVersion >= 11) {
      // v10 → v11：分层上下文压缩（F2）——新建 context_summaries 表
      //（每会话一条前情摘要；派生数据，不进备份）+ messages 加 pinned 列
      //（钉住消息所在轮永不压缩）
      await _createContextSummariesTable(db);
      await db.execute(
          'ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 12 && newVersion >= 12) {
      // v11 → v12：会话置顶（I7）——sessions 加 pinned 列
      //（置顶会话在抽屉置顶组恒置顶，不随时间分组沉底）
      await db.execute(
          'ALTER TABLE sessions ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
    }
  }

  static Future<void> _createAgentsTable(Database db) async {
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

  static Future<void> _createSkillsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS skills (
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
  }

  static Future<void> _createProvidersTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS providers (
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
  }

  static Future<void> _createMemoriesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memories (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        tag TEXT,
        source_skill TEXT,
        pinned INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createHttpToolsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS http_tools (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        url_template TEXT NOT NULL DEFAULT '',
        method TEXT NOT NULL DEFAULT 'GET',
        headers_json TEXT NOT NULL DEFAULT '',
        body_template TEXT NOT NULL DEFAULT '',
        parameters_json TEXT NOT NULL DEFAULT '',
        response_path TEXT NOT NULL DEFAULT '',
        max_response_chars INTEGER NOT NULL DEFAULT 4000,
        enabled INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createContextSummariesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS context_summaries (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        summary TEXT NOT NULL,
        first_kept_id TEXT NOT NULL,
        first_kept_at INTEGER NOT NULL,
        pinned_ids TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_context_summaries_session '
      'ON context_summaries(session_id, created_at)',
    );
  }

  // ===== Sessions =====

  Future<void> insertSession(ChatSession session) async {
    final db = await database;
    await db.insert('sessions', session.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 会话列表：置顶在前（组内按更新时间倒序），其余按更新时间倒序（I7）
  Future<List<ChatSession>> getAllSessions() async {
    final db = await database;
    final rows = await db
        .query('sessions', orderBy: 'pinned DESC, updated_at DESC');
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

  /// 设置会话置顶状态（I7：置顶会话在抽屉置顶组恒置顶）
  Future<void> setSessionPinned(String id, bool pinned) async {
    final db = await database;
    await db.update(
      'sessions',
      {'pinned': pinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新会话绑定的 Skill（null = 解绑，回到默认助手）
  Future<void> updateSessionSkill(String id, String? skillId) async {
    final db = await database;
    await db.update(
      'sessions',
      {'skill_id': skillId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新会话绑定的供应商与模型（null = 回退默认供应商/默认模型）
  Future<void> updateSessionProvider(
      String id, String? providerId, String? model) async {
    final db = await database;
    await db.update(
      'sessions',
      {'provider_id': providerId, 'model': model},
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
      await txn.delete('context_summaries',
          where: 'session_id = ?', whereArgs: [id]);
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

  /// 截断删除：删除 [messageId] 及其后全部消息（I4 编辑重发）
  ///
  /// 按 created_at 比较，同毫秒消息用 id 兜底（>= 含自身）。
  /// 编辑重发 = 删掉原 user 消息及其后所有回复，再以新文本重新发送。
  Future<void> deleteMessagesFrom(String messageId, int createdAt) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'session_id = (SELECT session_id FROM messages WHERE id = ?) '
          'AND (created_at > ? OR (created_at = ? AND id >= ?))',
      whereArgs: [messageId, createdAt, createdAt, messageId],
    );
  }

  /// 设置消息钉住状态（F2：钉住消息所在轮永不压缩）
  Future<void> setMessagePinned(String id, bool pinned) async {
    final db = await database;
    await db.update(
      'messages',
      {'pinned': pinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ===== Skills =====

  Future<void> insertSkill(Skill skill) async {
    final db = await database;
    await db.insert('skills', skill.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全部 Skill（内置在前，自定义在后，各按名称排序）
  Future<List<Skill>> getAllSkills() async {
    final db = await database;
    final rows = await db.query(
      'skills',
      orderBy: 'is_builtin DESC, name ASC',
    );
    return rows.map(Skill.fromMap).toList();
  }

  Future<Skill?> getSkill(String id) async {
    final db = await database;
    final rows =
        await db.query('skills', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Skill.fromMap(rows.first);
  }

  Future<void> updateSkill(Skill skill) async {
    final db = await database;
    await db.update('skills', skill.toMap(),
        where: 'id = ?', whereArgs: [skill.id]);
  }

  /// 删除自定义 Skill；同时解绑引用它的会话（避免悬挂引用）
  Future<void> deleteSkill(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update('sessions', {'skill_id': null},
          where: 'skill_id = ?', whereArgs: [id]);
      await txn.delete('skills', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 内置 Skill 是否已入库（首次启动种子判断）
  Future<bool> hasBuiltinSkills() async {
    final db = await database;
    final rows = await db.query('skills',
        where: 'is_builtin = 1', limit: 1);
    return rows.isNotEmpty;
  }

  // ===== Providers =====

  /// 写入供应商行；bridge 在场时 DB 只存空串，Key 进安全存储（E6）
  Future<void> insertProvider(ProviderProfile profile) async {
    final db = await database;
    final bridge = keyBridge;
    if (bridge != null && profile.apiKey.isNotEmpty) {
      await bridge.store(profile.id, profile.apiKey);
    }
    await db.insert(
        'providers', _providerRow(profile, redactKey: bridge != null),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全部供应商（内置在前，自定义在后，各按名称排序）
  Future<List<ProviderProfile>> getAllProviders() async {
    final db = await database;
    final rows = await db.query(
      'providers',
      orderBy: 'is_builtin DESC, name ASC',
    );
    return [for (final row in rows) await _profileFromRowAsync(row)];
  }

  Future<ProviderProfile?> getProvider(String id) async {
    final db = await database;
    final rows =
        await db.query('providers', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : await _profileFromRowAsync(rows.first);
  }

  Future<void> updateProvider(ProviderProfile profile) async {
    final db = await database;
    final bridge = keyBridge;
    if (bridge != null && profile.apiKey.isNotEmpty) {
      await bridge.store(profile.id, profile.apiKey);
    }
    await db.update(
        'providers', _providerRow(profile, redactKey: bridge != null),
        where: 'id = ?', whereArgs: [profile.id]);
  }

  /// 删除自定义供应商；同时把引用它的会话解绑（回退默认供应商）；
  /// bridge 在场时同步清掉安全存储里的 Key
  Future<void> deleteProvider(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update('sessions', {'provider_id': null, 'model': null},
          where: 'provider_id = ?', whereArgs: [id]);
      await txn.delete('providers', where: 'id = ?', whereArgs: [id]);
    });
    await keyBridge?.remove(id);
  }

  /// 内置供应商是否已入库（首次启动种子判断）
  Future<bool> hasBuiltinProviders() async {
    final db = await database;
    final rows = await db
        .query('providers', where: 'is_builtin = 1', limit: 1);
    return rows.isNotEmpty;
  }

  // ===== Memories =====

  Future<void> insertMemory(Memory memory) async {
    final db = await database;
    await db.insert('memories', memory.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全部记忆（按更新时间倒序）
  Future<List<Memory>> getAllMemories() async {
    final db = await database;
    final rows = await db.query('memories', orderBy: 'updated_at DESC');
    return rows.map(Memory.fromMap).toList();
  }

  /// 关键词检索（content LIKE 匹配，按更新时间倒序）
  Future<List<Memory>> searchMemories(String keyword) async {
    final db = await database;
    final rows = await db.query(
      'memories',
      where: 'content LIKE ?',
      whereArgs: ['%$keyword%'],
      orderBy: 'updated_at DESC',
    );
    return rows.map(Memory.fromMap).toList();
  }

  Future<void> updateMemory(Memory memory) async {
    final db = await database;
    await db.update('memories', memory.toMap(),
        where: 'id = ?', whereArgs: [memory.id]);
  }

  Future<void> deleteMemory(String id) async {
    final db = await database;
    await db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空全部记忆
  Future<void> deleteAllMemories() async {
    final db = await database;
    await db.delete('memories');
  }

  /// 记忆条数（容量上限判断用）
  Future<int> memoryCount() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM memories');
    return (rows.first['c'] as int?) ?? 0;
  }

  // ===== HttpTools（T1 自定义 HTTP 工具）=====

  Future<void> insertHttpTool(HttpTool tool) async {
    final db = await database;
    await db.insert('http_tools', tool.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全部 HTTP 工具（按创建时间正序，与配置顺序一致）
  Future<List<HttpTool>> getAllHttpTools() async {
    final db = await database;
    final rows = await db.query('http_tools', orderBy: 'created_at ASC');
    return rows.map(HttpTool.fromMap).toList();
  }

  Future<HttpTool?> getHttpTool(String id) async {
    final db = await database;
    final rows =
        await db.query('http_tools', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : HttpTool.fromMap(rows.first);
  }

  Future<void> updateHttpTool(HttpTool tool) async {
    final db = await database;
    await db.update('http_tools', tool.toMap(),
        where: 'id = ?', whereArgs: [tool.id]);
  }

  Future<void> deleteHttpTool(String id) async {
    final db = await database;
    await db.delete('http_tools', where: 'id = ?', whereArgs: [id]);
  }

  // ===== ContextSummaries（F2 分层上下文压缩）=====

  /// 保存会话前情摘要（每会话仅保留最新一条：先删旧再插新）
  Future<void> saveContextSummary(ContextSummary summary) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('context_summaries',
          where: 'session_id = ?', whereArgs: [summary.sessionId]);
      await txn.insert('context_summaries', {
        ...summary.toMap(),
        // List 字段序列化为 JSON 文本（sqflite 无原生数组列）
        'pinned_ids': const JsonEncoder().convert(summary.pinnedIds),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// 会话当前前情摘要（无则 null）
  Future<ContextSummary?> getContextSummary(String sessionId) async {
    final db = await database;
    final rows = await db.query('context_summaries',
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'created_at DESC',
        limit: 1);
    if (rows.isEmpty) return null;
    final row = Map<String, dynamic>.from(rows.first);
    // pinned_ids 存的是 JSON 文本，反序列化后交给 fromMap
    final raw = row.remove('pinned_ids') as String?;
    final pinnedIds = raw == null || raw.isEmpty
        ? const <String>[]
        : (jsonDecode(raw) as List<Object?>).whereType<String>().toList();
    return ContextSummary.fromMap({...row, 'pinned_ids': pinnedIds});
  }

  /// 删除会话前情摘要（会话删除/消息重置时调用）
  Future<void> deleteContextSummary(String sessionId) async {
    final db = await database;
    await db.delete('context_summaries',
        where: 'session_id = ?', whereArgs: [sessionId]);
  }

  /// 内置供应商能力升级（幂等，随版本演进）
  ///
  /// 老版本种子的 capabilities JSON 缺少后加的能力位（如 v1.6.0 的
  /// toolCalls），DB 里的旧数据不会随代码更新——启动时检测并补写。
  /// 只补内置 profile，用户自定义供应商不受影响。
  Future<void> upgradeBuiltinProviderCapabilities() async {
    final db = await database;
    final rows = await db.query('providers', where: 'is_builtin = 1');
    for (final row in rows) {
      final profile = _profileFromRow(row);
      // 按内置 id 找到对应的能力声明模板，缺什么补什么
      final template = _builtinCapabilityTemplates[profile.id];
      if (template == null) continue;
      var updated = profile;
      if (!profile.capabilities.vision && template.vision) {
        updated = updated.copyWith(
            capabilities: updated.capabilities.copyWith(vision: true));
      }
      if (!profile.capabilities.reasoning && template.reasoning) {
        updated = updated.copyWith(
            capabilities: updated.capabilities.copyWith(reasoning: true));
      }
      if (!profile.capabilities.toolCalls && template.toolCalls) {
        updated = updated.copyWith(
            capabilities: updated.capabilities.copyWith(toolCalls: true));
      }
      if (updated.capabilities != profile.capabilities) {
        // 能力升级不改 Key：bridge 在场时继续置空（Key 在安全存储）
        await db.update(
            'providers',
            _providerRow(updated,
                redactKey: keyBridge != null && profile.apiKey.isEmpty),
            where: 'id = ?',
            whereArgs: [profile.id]);
      }
    }
  }

  /// 内置供应商应具备的能力模板（按 id 索引，随版本演进维护）
  static const Map<String, ProviderCapabilities> _builtinCapabilityTemplates =
      {
    ProviderProfile.builtinCompanyId: ProviderCapabilities(
      vision: true,
      reasoning: true,
      toolCalls: true,
    ),
  };

  /// 供应商行组装；[redactKey] = bridge 在场，DB 只存空串（E6）
  Map<String, Object?> _providerRow(ProviderProfile profile,
          {bool redactKey = false}) =>
      providerRow(profile, redactKey: redactKey);

  /// 供应商 DB 行格式（公开给备份服务：capabilities/dialect 存 JSON 串，
  /// 与 toMap 的嵌套 Map 结构不同——直接 insert 会报 Invalid argument）
  static Map<String, Object?> providerRow(ProviderProfile profile,
          {bool redactKey = false}) =>
      {
        'id': profile.id,
        'name': profile.name,
        'base_url': profile.baseUrl,
        'api_key': redactKey ? '' : profile.apiKey,
        'default_model': profile.defaultModel,
        'capabilities': jsonEncode(profile.capabilities.toMap()),
        'dialect': jsonEncode(profile.dialect.toMap()),
        'is_builtin': profile.isBuiltin ? 1 : 0,
      };

  /// 行 → profile；bridge 在场且 DB 值为空时从安全存储注水（E6）
  Future<ProviderProfile> _profileFromRowAsync(
      Map<String, dynamic> row) async {
    final profile = _profileFromRow(row);
    if (profile.apiKey.isEmpty) {
      final resolved = await keyBridge?.resolve(profile.id);
      if (resolved != null && resolved.isNotEmpty) {
        return profile.copyWith(apiKey: resolved);
      }
    }
    return profile;
  }

  ProviderProfile _profileFromRow(Map<String, dynamic> row) {
    Map<String, dynamic> decodeJson(Object? raw) {
      if (raw is String && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {}
      }
      return const {};
    }

    return ProviderProfile(
      id: row['id'] as String,
      name: (row['name'] as String?) ?? '',
      baseUrl: (row['base_url'] as String?) ?? '',
      apiKey: (row['api_key'] as String?) ?? '',
      defaultModel: (row['default_model'] as String?) ?? '',
      capabilities: ProviderCapabilities.fromMap(
          decodeJson(row['capabilities'])),
      dialect: ProviderDialect.fromMap(decodeJson(row['dialect'])),
      isBuiltin: (row['is_builtin'] as int?) == 1,
    );
  }

  /// E6 一次性迁移：DB 明文 Key → 安全存储 → DB 置空（幂等）
  ///
  /// 顺序保证「先写安全存储成功，再清 DB 明文」——最坏情况（中途崩溃）
  /// 是两边都有值，下次启动重跑迁移收敛；绝不出现两边都空。
  Future<int> migrateKeysToBridge() async {
    final bridge = keyBridge;
    if (bridge == null) return 0;
    final db = await database;
    final rows = await db.query('providers');
    var migrated = 0;
    for (final row in rows) {
      final key = (row['api_key'] as String?) ?? '';
      if (key.isEmpty) continue; // 已迁移 / 无 Key
      final id = row['id'] as String;
      await bridge.store(id, key);
      await db.update('providers', {'api_key': ''},
          where: 'id = ?', whereArgs: [id]);
      migrated++;
    }
    return migrated;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
