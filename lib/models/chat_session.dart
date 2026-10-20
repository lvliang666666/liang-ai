/// 会话模型
class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.effort = 'max',
    this.skillId,
    this.providerId,
    this.model,
  });

  final String id;
  String title;
  final int createdAt;
  int updatedAt;

  /// 该会话的推理档位：max / high / low
  String effort;

  /// 绑定的 Skill id（null = 默认助手，无人格提示词 + 全部工具）
  String? skillId;

  /// 绑定的供应商 id（null = 用默认供应商）
  String? providerId;

  /// 该会话使用的模型名（null = 用供应商默认模型）
  String? model;

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'effort': effort,
        'skill_id': skillId,
        'provider_id': providerId,
        'model': model,
      };

  factory ChatSession.fromMap(Map<String, dynamic> map) => ChatSession(
        id: map['id'] as String,
        title: map['title'] as String,
        createdAt: map['created_at'] as int,
        updatedAt: map['updated_at'] as int,
        effort: (map['effort'] as String?) ?? 'max',
        skillId: map['skill_id'] as String?,
        providerId: map['provider_id'] as String?,
        model: map['model'] as String?,
      );
}
