import 'message_attachment.dart';

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

  /// 附件（仅 user 消息：图片/文件）
  List<MessageAttachment> attachments;

  final int createdAt;

  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content = '',
    this.reasoning = '',
    List<MessageAttachment>? attachments,
    required this.createdAt,
  }) : attachments = attachments ?? const [];

  bool get isUser => role == 'user';

  bool get hasAttachments => attachments.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'role': role,
        'content': content,
        'reasoning': reasoning,
        'attachments': MessageAttachment.encodeList(attachments),
        'created_at': createdAt,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
        id: map['id'] as String,
        sessionId: map['session_id'] as String,
        role: map['role'] as String,
        content: (map['content'] as String?) ?? '',
        reasoning: (map['reasoning'] as String?) ?? '',
        attachments:
            MessageAttachment.decodeList(map['attachments'] as String?),
        createdAt: map['created_at'] as int,
      );

  /// 转为 API 请求的 messages 格式（纯文本场景；多模态组装在 ApiService）
  Map<String, String> toApiMessage() => {'role': role, 'content': content};
}
