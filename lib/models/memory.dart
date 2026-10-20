/// 记忆模型：AI 长期记住的用户偏好/事实（全局共享记忆池，跨会话跨 Skill）
///
/// 纯本地 SQLite 存储（memories 表，DB v7），零隐私外泄。
class Memory {
  final String id;

  /// 记忆内容（一句话事实，如「用户喜欢简洁回答」）
  String content;

  /// 分类标签（模型存时自定：偏好/背景/习惯/其他，可空）
  String? tag;

  /// 记录来源 Skill 名（溯源用，可空）
  String? sourceSkill;

  final int createdAt;
  int updatedAt;

  Memory({
    required this.id,
    required this.content,
    this.tag,
    this.sourceSkill,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'content': content,
        'tag': tag,
        'source_skill': sourceSkill,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Memory.fromMap(Map<String, dynamic> map) => Memory(
        id: map['id'] as String,
        content: (map['content'] as String?) ?? '',
        tag: map['tag'] as String?,
        sourceSkill: map['source_skill'] as String?,
        createdAt: (map['created_at'] as int?) ?? 0,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );

  Memory copyWith({
    String? content,
    String? tag,
    String? sourceSkill,
    int? updatedAt,
  }) =>
      Memory(
        id: id,
        content: content ?? this.content,
        tag: tag ?? this.tag,
        sourceSkill: sourceSkill ?? this.sourceSkill,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
