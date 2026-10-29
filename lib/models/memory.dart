/// 记忆模型：AI 长期记住的用户偏好/事实（全局共享记忆池，跨会话跨 Agent）
///
/// 纯本地 SQLite 存储（memories 表，DB v7；v17 加 layer 分层列）。
class Memory {
  /// 归档摘要行的固定标签（由 MemoryService 滚动压缩创建，永不二次压缩）
  static const archiveTag = '归档摘要';

  /// 冲突消解归档行的标签前缀（M3：被新记忆取代的旧条，原文保留可溯源）
  static const replacedTagPrefix = '已取代';

  /// 记忆层级（M3 分层）：核心画像 / 偏好 / 事件
  ///
  /// - [layerProfile]：稳定身份事实（城市/职业/技术栈），不衰减
  /// - [layerPreference]：回答风格与喜好（简洁/详细/代码多注释），不衰减
  /// - [layerEvent]：带时间性的事件（最近在准备考试/上周换了工作），
  ///   注入时按 [eventDecayDays] 衰减——过期不注入（不删除，用户可见）
  static const layerProfile = 'profile';
  static const layerPreference = 'preference';
  static const layerEvent = 'event';

  /// 事件层衰减天数：超过该天数的事件记忆不再注入 system prompt
  ///（保留在库中，用户可在记忆面板查看/删除）
  static const eventDecayDays = 30;

  /// 合法层级集合（解析模型输出/备份导入时校验，非法值回退 event）
  static const validLayers = {layerProfile, layerPreference, layerEvent};

  /// 层级中文名（UI 徽章用）
  static String layerLabel(String layer) => switch (layer) {
        layerProfile => '画像',
        layerPreference => '偏好',
        layerEvent => '事件',
        _ => '事件',
      };

  final String id;

  /// 记忆内容（一句话事实，如「用户喜欢简洁回答」）
  String content;

  /// 分类标签（模型存时自定：偏好/背景/习惯/其他，可空；
  /// [archiveTag] 为滚动压缩生成的归档摘要行）
  String? tag;

  /// 记录来源 Agent 名（溯源用，可空）
  String? sourceAgent;

  /// 用户置顶（永久记忆）：注入排最前、不占注入名额、不参与滚动压缩
  bool pinned;

  /// 记忆层级（M3）：[layerProfile]/[layerPreference]/[layerEvent]；
  /// 老数据（v17 前入库）DB 默认 'event'
  String layer;

  final int createdAt;
  int updatedAt;

  Memory({
    required this.id,
    required this.content,
    this.tag,
    this.sourceAgent,
    this.pinned = false,
    this.layer = layerEvent,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'content': content,
        'tag': tag,
        'source_skill': sourceAgent,
        'pinned': pinned ? 1 : 0,
        'layer': layer,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Memory.fromMap(Map<String, dynamic> map) => Memory(
        id: map['id'] as String,
        content: (map['content'] as String?) ?? '',
        tag: map['tag'] as String?,
        sourceAgent: map['source_skill'] as String?,
        pinned: ((map['pinned'] as int?) ?? 0) != 0,
        layer: _parseLayer(map['layer'] as String?),
        createdAt: (map['created_at'] as int?) ?? 0,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );

  /// 层级解析容错：非法/缺失值回退 event（备份导入/手改文件防御）
  static String _parseLayer(String? raw) =>
      validLayers.contains(raw) ? raw! : layerEvent;

  /// 是否为归档行（滚动压缩摘要 或 M3 冲突消解被取代的旧条）
  ///
  /// 两类归档行都不参与注入/去重/滚动压缩，面板可见可删：
  /// - 滚动压缩摘要：tag 精确等于 [archiveTag]
  /// - 被取代旧条：tag 以 [replacedTagPrefix] 开头（保留原标签可溯源）
  bool get isArchived =>
      tag == Memory.archiveTag || (tag?.startsWith(Memory.replacedTagPrefix) ?? false);

  /// 事件层是否已衰减（超过 [eventDecayDays] 天不再注入；不删除）
  bool isDecayed(int nowMs) {
    if (layer != layerEvent) return false;
    final ageMs = nowMs - updatedAt;
    return ageMs > eventDecayDays * 24 * 60 * 60 * 1000;
  }

  Memory copyWith({
    String? content,
    String? tag,
    String? sourceAgent,
    bool? pinned,
    String? layer,
    int? updatedAt,
  }) =>
      Memory(
        id: id,
        content: content ?? this.content,
        tag: tag ?? this.tag,
        sourceAgent: sourceAgent ?? this.sourceAgent,
        pinned: pinned ?? this.pinned,
        layer: layer ?? this.layer,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
