/// 记忆模型：AI 长期记住的用户偏好/事实（全局共享记忆池，跨会话跨 Agent）
///
/// 纯本地 SQLite 存储（memories 表，DB v7），零隐私外泄。
class Memory {
  /// 归档摘要行的固定标签（由 MemoryService 滚动压缩创建，永不二次压缩）
  static const archiveTag = '归档摘要';

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

  final int createdAt;
  int updatedAt;

  Memory({
    required this.id,
    required this.content,
    this.tag,
    this.sourceAgent,
    this.pinned = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'content': content,
        'tag': tag,
        'source_skill': sourceAgent,
        'pinned': pinned ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Memory.fromMap(Map<String, dynamic> map) => Memory(
        id: map['id'] as String,
        content: (map['content'] as String?) ?? '',
        tag: map['tag'] as String?,
        sourceAgent: map['source_skill'] as String?,
        pinned: ((map['pinned'] as int?) ?? 0) != 0,
        createdAt: (map['created_at'] as int?) ?? 0,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );

  /// 是否为归档摘要行（滚动压缩产物，永不二次压缩）
  bool get isArchived => tag == Memory.archiveTag;

  Memory copyWith({
    String? content,
    String? tag,
    String? sourceAgent,
    bool? pinned,
    int? updatedAt,
  }) =>
      Memory(
        id: id,
        content: content ?? this.content,
        tag: tag ?? this.tag,
        sourceAgent: sourceAgent ?? this.sourceAgent,
        pinned: pinned ?? this.pinned,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
