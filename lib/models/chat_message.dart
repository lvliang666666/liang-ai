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

  /// 转为 API 请求的 messages 格式
  ///
  /// 无附件：content 为字符串；带图片附件：content 为 OpenAI 多模态数组
  /// （text + image_url，图片走 data URL）；带文件附件：提取文本以
  /// 【附件：name】块拼进正文。
  Map<String, Object?> toApiMessage() {
    if (!hasAttachments) return {'role': role, 'content': content};

    // 文件附件：文本注入正文
    final fileBlocks = [
      for (final a in attachments.where((a) => a.isFile))
        '【附件：${a.name}】\n${a.extractedText ?? ''}',
    ];
    final textContent =
        fileBlocks.isEmpty ? content : '${fileBlocks.join('\n\n')}\n\n$content';

    // 图片附件：OpenAI 多模态数组
    final images = attachments.where((a) => a.isImage).toList();
    if (images.isEmpty) return {'role': role, 'content': textContent};

    return {
      'role': role,
      'content': [
        {'type': 'text', 'text': textContent},
        for (final img in images)
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,${img.base64Data}'},
          },
      ],
    };
  }
}
