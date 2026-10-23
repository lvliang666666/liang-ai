import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/memory.dart';
import 'database_service.dart';

/// 记忆服务：AI 长期记忆的存取门面
///
/// - 全局共享记忆池（所有 Skill 共用，像同一个助理）
/// - 内容去重：归一化后相同视为同一条，更新时间戳；包含关系合并（短边足够长）
/// - 容量上限：超过 [maxMemories] 条时滚动压缩——把最旧一批活跃记忆
///   合并为一条归档摘要行（tag=[Memory.archiveTag]），而非直接删除，
///   信息不丢失；归档行永不二次压缩
///
/// 变更通知：任何实例写库（save/delete/forget/clear）后触发静态
/// [changeSignal]，UI 层（MemoryProvider）订阅它即时刷新列表——
/// 解决「AI 工具存了记忆，记忆管理页要重启才看到」的问题。
class MemoryService {
  /// 记忆变更信号：任意实例写库后 +1（UI 层订阅自动重载）
  static final ValueNotifier<int> changeSignal = ValueNotifier(0);

  MemoryService({required DatabaseService database}) : _db = database;

  final DatabaseService _db;

  /// 容量上限（超过触发滚动压缩）
  static const maxMemories = 200;

  /// 滚动压缩批次：每次把最旧 [compressBatch] 条活跃记忆合并为一条归档摘要
  static const compressBatch = 40;

  /// 包含合并的最短边长度（短于此长度的包含关系不合并，防误伤）
  static const containMergeMinLength = 6;

  /// 注入 system prompt 的最大条数
  static const injectLimit = 20;

  /// 存一条记忆（归一化去重 + 包含合并）
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

    // 去重/合并：归一化相同 → 更新原条；包含关系（短边≥6字）→ 保留信息更全的长边
    // 归档行是系统内部产物（滚动压缩写入），跳过去重直接落库
    final all = await _db.getAllMemories();
    final existing =
        tag == Memory.archiveTag ? null : _findDuplicate(trimmed, all);
    if (existing != null) {
      final merged = _mergeContent(existing.content, trimmed);
      final updated = existing.copyWith(
        content: merged,
        tag: tag,
        sourceSkill: sourceSkill,
        updatedAt: now,
      );
      await _db.updateMemory(updated);
      await _enforceCapacity(now: now);
      _notifyChange();
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
    _notifyChange();
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
  Future<void> delete(String id) async {
    await _db.deleteMemory(id);
    _notifyChange();
  }

  /// 置顶/取消置顶（策展台手动操作）
  Future<void> setPinned(String id, bool pinned) async {
    final all = await _db.getAllMemories();
    final target = all.where((m) => m.id == id).firstOrNull;
    if (target == null) return;
    await _db.updateMemory(target.copyWith(pinned: pinned));
    _notifyChange();
  }

  /// 编辑记忆内容/标签（策展台手动改写；绕过去重——用户明确意图优先）
  Future<void> update(String id,
      {String? content, String? tag}) async {
    final all = await _db.getAllMemories();
    final target = all.where((m) => m.id == id).firstOrNull;
    if (target == null) return;
    final trimmed = content?.trim();
    await _db.updateMemory(target.copyWith(
      content:
          trimmed != null && trimmed.isNotEmpty ? trimmed : target.content,
      tag: tag,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    _notifyChange();
  }

  /// 按关键词删除（content LIKE 匹配），返回删除条数
  ///
  /// 归档摘要行是压缩产物（聚合了多条旧记忆），不随单条关键词删除——
  /// 否则「忘掉我喜欢简洁」可能连带删掉含该偏好的整段归档摘要。
  Future<int> deleteByKeyword(String keyword) async {
    final matched =
        (await search(keyword)).where((m) => !m.isArchived).toList();
    for (final m in matched) {
      await _db.deleteMemory(m.id);
    }
    if (matched.isNotEmpty) _notifyChange();
    return matched.length;
  }

  /// 清空全部
  Future<void> deleteAll() async {
    await _db.deleteAllMemories();
    _notifyChange();
  }

  /// 条数
  Future<int> count() => _db.memoryCount();

  /// 拼接注入 system prompt 的记忆文本（置顶条 + 最近 [injectLimit] 条活跃记忆）
  ///
  /// 置顶条（pinned）排最前且不占 [injectLimit] 名额（永久记忆语义）；
  /// 归档摘要行置尾单独成段（低优先级参考，不占活跃条数名额）。
  /// 无记忆返回空字符串（调用方据此跳过注入段）。
  Future<String> recentText({int limit = injectLimit}) async {
    final all = await _db.getAllMemories();
    if (all.isEmpty) return '';
    final active = all.where((m) => !m.isArchived).toList();
    final archived = all.where((m) => m.isArchived).toList();
    if (active.isEmpty && archived.isEmpty) return '';
    final pinned = active.where((m) => m.pinned).toList();
    final unpinned = active.where((m) => !m.pinned).toList();
    final picked = unpinned.take(limit).toList();
    if (pinned.isEmpty && picked.isEmpty && archived.isEmpty) return '';
    return [
      '【用户记忆】（长期有效，跨会话）',
      for (final m in pinned) '- ${m.content}（置顶）',
      for (final m in picked) '- ${m.content}',
      if (archived.isNotEmpty) ...[
        '【历史归档】（早期记忆的压缩摘要，仅供参考）',
        for (final m in archived) '- ${m.content}',
      ],
    ].join('\n');
  }

  /// 查找与 [content] 重复的既有记忆（归档行不参与去重）
  ///
  /// 规则：①归一化后完全相同 ②一方归一化后包含另一方且短边 ≥
  /// [containMergeMinLength] 字（防「喜欢咖啡」吞掉长句的误伤方向相反——
  /// 这里防的是短句被长句吞并后信息变模糊，以及超短句如「好的」误合并）。
  /// 否定句守卫：两串归一化后一个含否定词一个不含时不合并（「喜欢」≠「不喜欢」）。
  static Memory? _findDuplicate(String content, List<Memory> all) {
    final norm = normalize(content);
    for (final m in all) {
      if (m.isArchived) continue;
      final other = normalize(m.content);
      if (other == norm) return m;
      if (_hasNegationConflict(norm, other)) continue;
      if (norm.length >= containMergeMinLength &&
          other.length >= containMergeMinLength) {
        if (other.contains(norm) || norm.contains(other)) return m;
      }
    }
    return null;
  }

  /// 合并新旧内容：保留信息更全的一方（更长的），等长取新值
  static String _mergeContent(String oldContent, String newContent) {
    final oldNorm = normalize(oldContent);
    final newNorm = normalize(newContent);
    if (oldNorm == newNorm) return newContent.trim();
    return newNorm.length >= oldNorm.length ? newContent.trim() : oldContent;
  }

  /// 归一化：去所有空白 + 常见中英文标点 + 转小写（近似重复判定用）
  static String normalize(String s) {
    const punctuation =
        '，。！？、；：""\'\'（）《》【】「」『』…—–·,.!?;:()<>[]"\'`';
    final buffer = StringBuffer();
    for (final ch in s.toLowerCase().runes) {
      final c = String.fromCharCode(ch);
      if (c.trim().isEmpty || punctuation.contains(c)) continue;
      buffer.write(c);
    }
    return buffer.toString();
  }

  /// 两串归一化文本是否一个含否定词一个不含（含否定词的子串比较）
  static bool _hasNegationConflict(String a, String b) {
    const negations = ['不', '没', '别', '无', '非', '莫', '勿'];
    bool hasNeg(String s) => negations.any(s.contains);
    final aHas = hasNeg(a);
    final bHas = hasNeg(b);
    if (aHas == bHas) return false;
    final withNeg = aHas ? a : b;
    final without = aHas ? b : a;
    return withNeg.contains(without) || without.contains(withNeg);
  }

  /// 容量上限：超过 maxMemories 触发滚动压缩
  ///
  /// 把最旧 [compressBatch] 条活跃记忆（按 updated_at 升序取尾部）合并为
  /// 一条归档摘要行（tag=[Memory.archiveTag]，updatedAt=[now] 使其沉底），
  /// 原条目删除。归档行永不二次压缩——摘要失真不随轮次累积。
  /// 置顶条（pinned）不参与压缩淘汰（永久记忆语义）。
  Future<void> _enforceCapacity({required int now}) async {
    final all = await _db.getAllMemories(); // 已按 updated_at 倒序
    if (all.length <= maxMemories) return;
    final active = all.where((m) => !m.isArchived).toList();
    if (active.length <= maxMemories) return;
    // 可压缩池 = 非置顶活跃记忆；置顶条永不进摘要
    final compressible =
        active.where((m) => !m.pinned).toList();
    if (compressible.length <= maxMemories) return;
    // 尾部 = 最旧的 compressBatch 条可压缩记忆
    final oldest = compressible.length > compressBatch
        ? compressible.sublist(compressible.length - compressBatch)
        : List<Memory>.of(compressible);
    final summary = [
      '早期记忆摘要：',
      for (final m in oldest.reversed) '· ${m.content}',
    ].join('\n');
    final archived = Memory(
      id: _genId(now),
      content: summary,
      tag: Memory.archiveTag,
      sourceSkill: null,
      createdAt: now,
      updatedAt: now,
    );
    for (final m in oldest) {
      await _db.deleteMemory(m.id);
    }
    await _db.insertMemory(archived);
  }

  /// id 生成：时间戳 36 进制 + 随机后缀（同毫秒多条防碰撞）
  ///
  /// 后缀用 [Random] 而非时钟微秒——Windows 时钟粒度粗（~15ms），
  /// 批量写入时连续取到相同微秒值，4 位后缀全同 → id 碰撞 →
  /// ConflictAlgorithm.replace 静默覆盖丢数据（实测 210 条循环必现）。
  static String _genId(int now) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final suffix = [
      for (var i = 0; i < 6; i++) chars[_idRandom.nextInt(chars.length)],
    ].join();
    return '${now.toRadixString(36)}_$suffix';
  }

  /// id 随机源（static final：与实例生命周期解耦）
  static final Random _idRandom = Random();

  /// 触发变更信号（写库成功后调用）
  static void _notifyChange() => changeSignal.value++;
}
