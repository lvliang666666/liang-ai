import 'dart:convert';

/// 工具调用：模型发起的一次工具请求（assistant 消息携带）
class ToolCall {
  /// OpenAI 返回的调用 ID（tool 结果消息通过 tool_call_id 关联）
  final String id;

  /// 工具名
  final String name;

  /// 参数 JSON 字符串（原样存储，执行时解析）
  final String argumentsJson;

  const ToolCall({
    required this.id,
    required this.name,
    this.argumentsJson = '',
  });

  /// 解析参数为 Map（坏 JSON 容错返回空 Map）
  Map<String, dynamic> get arguments {
    if (argumentsJson.isEmpty) return const {};
    try {
      final decoded = jsonDecode(argumentsJson);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 参数摘要（UI 卡片展示：最多 40 字符）
  String get argumentsPreview {
    if (argumentsJson.isEmpty) return '';
    final flat = argumentsJson.replaceAll('\n', ' ');
    return flat.length <= 40 ? flat : '${flat.substring(0, 40)}…';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'arguments': argumentsJson,
      };

  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        argumentsJson: json['arguments'] as String? ?? '',
      );

  /// 列表序列化/反序列化（DB 存 JSON 字符串，模式同 MessageAttachment）
  static String encodeList(List<ToolCall> list) =>
      jsonEncode([for (final c in list) c.toJson()]);

  static List<ToolCall> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          ToolCall.fromJson(item as Map<String, dynamic>)
      ];
    } catch (_) {
      return const []; // 脏数据容错
    }
  }
}

/// 工具执行结果（内存态：执行后立即写入 tool 结果消息，不单独落库）
class ToolCallResult {
  /// 对应的 ToolCall.id
  final String callId;

  /// 结果文本（失败时为错误描述）
  final String content;

  /// 工具执行是否失败（失败结果仍会发给模型自行处理，不中断 loop）
  final bool isError;

  const ToolCallResult({
    required this.callId,
    required this.content,
    this.isError = false,
  });
}
