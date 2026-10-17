/// 消息模型
class ChatMessage {
  final String id;
  final String sessionId;

  /// user / assistant
  final String role;

  /// 正文内容
  String content;

  /// 思考过程内容（仅 assistant 消息）
  String reasoning;

  final int createdAt;

  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content = '',
    this.reasoning = '',
    required this.createdAt,
  });

  bool get isUser => role == 'user';

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'role': role,
        'content': content,
        'reasoning': reasoning,
        'created_at': createdAt,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
        id: map['id'] as String,
        sessionId: map['session_id'] as String,
        role: map['role'] as String,
        content: (map['content'] as String?) ?? '',
        reasoning: (map['reasoning'] as String?) ?? '',
        createdAt: map['created_at'] as int,
      );

  /// 转为 API 请求的 messages 格式
  Map<String, String> toApiMessage() => {'role': role, 'content': content};
}
