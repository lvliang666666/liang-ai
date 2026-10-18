import 'dart:convert';

/// 消息附件类型
enum AttachmentType { image, file }

/// 消息附件：图片（存 base64）或文件（存提取文本 + 原文件路径）
class MessageAttachment {
  final AttachmentType type;

  /// 显示名（图片为文件名，文件为原始文件名）
  final String name;

  /// 图片附件：JPEG base64（不带 data: 前缀，组装请求时再加）
  final String? base64Data;

  /// 文件附件：提取出的纯文本内容
  final String? extractedText;

  /// 文件附件：原文件在应用沙箱内的保存路径（用于点开）
  final String? filePath;

  const MessageAttachment({
    required this.type,
    required this.name,
    this.base64Data,
    this.extractedText,
    this.filePath,
  });

  bool get isImage => type == AttachmentType.image;
  bool get isFile => type == AttachmentType.file;

  /// 原文件是否已保存（可点开）
  bool get hasFile => filePath != null && filePath!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'type': type == AttachmentType.image ? 'image' : 'file',
        'name': name,
        if (base64Data != null) 'base64': base64Data,
        if (extractedText != null) 'text': extractedText,
        if (filePath != null) 'path': filePath,
      };

  factory MessageAttachment.fromJson(Map<String, dynamic> json) =>
      MessageAttachment(
        type: json['type'] == 'image'
            ? AttachmentType.image
            : AttachmentType.file,
        name: json['name'] as String? ?? '',
        base64Data: json['base64'] as String?,
        extractedText: json['text'] as String?,
        filePath: json['path'] as String?,
      );

  /// 列表序列化/反序列化（DB 存 JSON 字符串）
  static String encodeList(List<MessageAttachment> list) =>
      jsonEncode([for (final a in list) a.toJson()]);

  static List<MessageAttachment> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          MessageAttachment.fromJson(item as Map<String, dynamic>)
      ];
    } catch (_) {
      return const []; // 脏数据容错：解析失败当无附件
    }
  }
}
