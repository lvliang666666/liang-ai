import 'message_attachment.dart';
import 'tool_call.dart';

/// 消息模型
class ChatMessage {
  final String id;
  final String sessionId;

  /// user / assistant / tool
  final String role;

  /// 正文内容
  String content;

  /// 思考过程内容（仅 assistant 消息）
  String reasoning;

  /// 附件（仅 user 消息：图片/文件）
  List<MessageAttachment> attachments;

  /// assistant 消息发起的工具调用（role='assistant' 且模型请求调用工具时非空）
  List<ToolCall> toolCalls;

  /// tool 结果消息关联的调用 ID（仅 role='tool'）
  String? toolCallId;

  /// 本轮输入 token（system+记忆+历史+本轮消息；usage 末帧或本地估算，
  /// null = 老数据/未统计）
  int? promptTokens;

  /// 本轮输出 token（reasoning+content；usage 末帧或本地估算）
  int? completionTokens;

  /// 思考耗时（秒；I10 生成状态可见性——完成态思考块「已深度思考
  /// （用时 N 秒）」的数据源。null = 老数据/流式中未收尾）
  int? thinkingSeconds;

  /// 生成总耗时（秒；思考+回答全程。null = 老数据/流式中未收尾）
  int? generationSeconds;

  /// 流式中断标记（E5：1 = 流式占位未收尾——App 被杀/断流留下的
  /// 半截消息，启动扫描后标「已中断」并提供重新生成入口）
  bool interrupted;

  /// 用户钉住（F2：钉住消息所在轮永不压缩进前情摘要）
  bool pinned;

  final int createdAt;

  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content = '',
    this.reasoning = '',
    List<MessageAttachment>? attachments,
    List<ToolCall>? toolCalls,
    this.toolCallId,
    this.promptTokens,
    this.completionTokens,
    this.thinkingSeconds,
    this.generationSeconds,
    this.interrupted = false,
    this.pinned = false,
    required this.createdAt,
  })  : attachments = attachments ?? const [],
        toolCalls = toolCalls ?? const [];

  bool get isUser => role == 'user';

  bool get isToolResult => role == 'tool';

  bool get hasAttachments => attachments.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'role': role,
        'content': content,
        'reasoning': reasoning,
        'attachments': MessageAttachment.encodeList(attachments),
        'tool_calls': ToolCall.encodeList(toolCalls),
        'tool_call_id': toolCallId,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'thinking_seconds': thinkingSeconds,
        'generation_seconds': generationSeconds,
        'interrupted': interrupted ? 1 : 0,
        'pinned': pinned ? 1 : 0,
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
        toolCalls: ToolCall.decodeList(map['tool_calls'] as String?),
        toolCallId: map['tool_call_id'] as String?,
        promptTokens: map['prompt_tokens'] as int?,
        completionTokens: map['completion_tokens'] as int?,
        thinkingSeconds: map['thinking_seconds'] as int?,
        generationSeconds: map['generation_seconds'] as int?,
        interrupted: ((map['interrupted'] as int?) ?? 0) != 0,
        pinned: ((map['pinned'] as int?) ?? 0) != 0,
        createdAt: map['created_at'] as int,
      );

  /// 转为 API 请求的 messages 格式
  ///
  /// role='tool'：输出 {role, tool_call_id, content}；
  /// assistant 带 tool_calls：输出 {role, content, tool_calls: [...]}；
  /// 无附件：content 为字符串；带图片附件：content 为 OpenAI 多模态数组
  /// （text + image_url，图片走 data URL）；带文件附件：提取文本以
  /// 【附件：name】块拼进正文。
  Map<String, Object?> toApiMessage() {
    // 工具结果消息：OpenAI tool 角色格式
    if (isToolResult) {
      return {
        'role': 'tool',
        'tool_call_id': toolCallId ?? '',
        'content': content,
      };
    }
    // assistant 消息携带工具调用：content + tool_calls 数组
    if (toolCalls.isNotEmpty) {
      return {
        'role': role,
        'content': content,
        'tool_calls': [
          for (final c in toolCalls)
            {
              'id': c.id,
              'type': 'function',
              'function': {'name': c.name, 'arguments': c.argumentsJson},
            },
        ],
      };
    }
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
