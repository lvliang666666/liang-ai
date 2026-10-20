import '../models/memory.dart';
import 'database_service.dart';

/// 记忆服务：AI 长期记忆的存取门面
///
/// - 全局共享记忆池（所有 Skill 共用，像同一个助理）
/// - 内容去重：同 content 已存在则视为同一条，更新时间戳
/// - 容量上限：超过 [maxMemories] 条时删最旧（防无限膨胀）
class MemoryService {
  MemoryService({required DatabaseService database}) : _db = database;

  final DatabaseService _db;

  /// 容量上限（超过删最旧）
  static const maxMemories = 200;

  /// 注入 system prompt 的最大条数
  static const injectLimit = 20;

  /// 存一条记忆（内容去重：同 content 更新时间戳而非新增）
  ///
  /// 返回实际落库的记忆（新建或被更新的那条）。
  Future<Memory> save(String content, {String? tag, String? sourceSkill}) =>
      saveAt(
        content,
        tag: tag,
        sourceSkill: sourceSkill,
        now: DateTime.now().millisecondsSinceEpoch,
      );

  /// save 的可测内核（时间注入）：[now] 为毫秒时间戳
  Future<Memory> saveAt(
    String content, {
    String? tag,
    String? sourceSkill,
    required int now,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('记忆内容不能为空');
    }

    // 去重：同 content 已存在 → 更新时间戳（tag/sourceSkill 以新值为准）
    final existing = await _findByContent(trimmed);
    if (existing != null) {
      final updated = existing.copyWith(
        tag: tag,
        sourceSkill: sourceSkill,
        updatedAt: now,
      );
      await _db.updateMemory(updated);
      await _enforceCapacity(now: now);
      return updated;
    }

    final memory = Memory(
      id: _genId(now),
      content: trimmed,
      tag: tag,
      sourceSkill: sourceSkill,
      createdAt: now,
      updatedAt: now,
    );
    await _db.insertMemory(memory);
    await _enforceCapacity(now: now);
    return memory;
  }

  /// 全部记忆（按更新时间倒序）
  Future<List<Memory>> getAll() => _db.getAllMemories();

  /// 关键词检索
  Future<List<Memory>> search(String keyword) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return Future.value(const []);
    return _db.searchMemories(trimmed);
  }

  /// 按 id 删除
  Future<void> delete(String id) => _db.deleteMemory(id);

  /// 按关键词删除（content LIKE 匹配），返回删除条数
  Future<int> deleteByKeyword(String keyword) async {
    final matched = await search(keyword);
    for (final m in matched) {
      await _db.deleteMemory(m.id);
    }
    return matched.length;
  }

  /// 清空全部
  Future<void> deleteAll() => _db.deleteAllMemories();

  /// 条数
  Future<int> count() => _db.memoryCount();

  /// 拼接注入 system prompt 的记忆文本（最近 [injectLimit] 条）
  ///
  /// 无记忆返回空字符串（调用方据此跳过注入段）。
  Future<String> recentText({int limit = injectLimit}) async {
    final all = await _db.getAllMemories();
    if (all.isEmpty) return '';
    final picked = all.take(limit).toList();
    return [
      '【用户记忆】（长期有效，跨会话）',
      for (final m in picked) '- ${m.content}',
    ].join('\n');
  }

  /// 按 content 精确匹配查找（去重判断用）
  Future<Memory?> _findByContent(String content) async {
    final all = await _db.getAllMemories();
    for (final m in all) {
      if (m.content == content) return m;
    }
    return null;
  }

  /// 容量上限：超过 maxMemories 删最旧（按 updated_at 升序）
  Future<void> _enforceCapacity({required int now}) async {
    final all = await _db.getAllMemories(); // 已按 updated_at 倒序
    if (all.length <= maxMemories) return;
    final outdated = all.skip(maxMemories).toList(); // 尾部 = 最旧
    for (final m in outdated) {
      await _db.deleteMemory(m.id);
    }
  }

  /// id 生成：时间戳 36 进制 + 随机后缀（同毫秒多条防碰撞）
  static String _genId(int now) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = DateTime.now().microsecondsSinceEpoch;
    final suffix = [
      for (var i = 0; i < 4; i++) chars[(rng >> (i * 5)) % chars.length],
    ].join();
    return '${now.toRadixString(36)}_$suffix';
  }
}
