/// 会话模型
class ChatSession {
  final String id;
  String title;
  final int createdAt;
  int updatedAt;

  /// 该会话的推理档位：max / high / low
  String effort;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.effort = 'max',
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'effort': effort,
      };

  factory ChatSession.fromMap(Map<String, dynamic> map) => ChatSession(
        id: map['id'] as String,
        title: map['title'] as String,
        createdAt: map['created_at'] as int,
        updatedAt: map['updated_at'] as int,
        effort: (map['effort'] as String?) ?? 'max',
      );
}
