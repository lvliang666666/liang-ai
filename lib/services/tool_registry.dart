import 'dart:convert';

import '../models/tool_call.dart';

/// 工具处理器：一个可被模型调用的工具
abstract class ToolHandler {
  const ToolHandler();

  /// 工具名（OpenAI function name 规范：字母/数字/下划线/连字符）
  String get name;

  /// 给模型看的功能描述（影响模型何时调用）
  String get description;

  /// JSON Schema 格式的参数定义（OpenAI parameters 字段）
  Map<String, dynamic> get parametersSchema;

  /// 执行工具。[arguments] 为解析后的参数 Map。
  /// 抛异常视为执行失败（上层捕获后转为 isError 结果消息）。
  Future<String> execute(Map<String, dynamic> arguments);
}

/// 工具注册表：管理可用工具，生成 OpenAI tools 数组，执行调用
class ToolRegistry {
  final Map<String, ToolHandler> _handlers = {};

  /// 注册工具（同名覆盖）
  void register(ToolHandler handler) => _handlers[handler.name] = handler;

  /// 批量注册
  void registerAll(Iterable<ToolHandler> handlers) {
    for (final h in handlers) {
      register(h);
    }
  }

  bool get isEmpty => _handlers.isEmpty;
  bool get isNotEmpty => _handlers.isNotEmpty;
  int get length => _handlers.length;
  List<String> get names => _handlers.keys.toList();

  /// 生成 OpenAI 请求体的 tools 数组
  List<Map<String, dynamic>> toOpenAiTools() => [
        for (final h in _handlers.values)
          {
            'type': 'function',
            'function': {
              'name': h.name,
              'description': h.description,
              'parameters': h.parametersSchema,
            },
          }
      ];

  /// 执行一次工具调用。工具不存在/参数坏/执行抛异常都转为 isError 结果，
  /// 不抛异常（由上层决定如何呈现，loop 不中断）。
  Future<ToolCallResult> execute(ToolCall call) async {
    final handler = _handlers[call.name];
    if (handler == null) {
      return ToolCallResult(
        callId: call.id,
        content: '错误：未知工具 "${call.name}"',
        isError: true,
      );
    }
    try {
      final output = await handler.execute(call.arguments);
      return ToolCallResult(callId: call.id, content: output);
    } catch (e) {
      return ToolCallResult(
        callId: call.id,
        content: '工具执行失败：$e',
        isError: true,
      );
    }
  }

  /// 批量执行（按顺序），结果截断到 [maxChars] 防止撑爆上下文
  Future<List<ToolCallResult>> executeAll(
    List<ToolCall> calls, {
    int maxChars = 4000,
  }) async {
    final results = <ToolCallResult>[];
    for (final call in calls) {
      final r = await execute(call);
      results.add(
        r.content.length > maxChars
            ? ToolCallResult(
                callId: r.callId,
                content: '${r.content.substring(0, maxChars)}…（结果已截断）',
                isError: r.isError,
              )
            : r,
      );
    }
    return results;
  }
}

/// 工具结果消息转 OpenAI 格式（role='tool'）
Map<String, Object?> toolResultToApiMessage(ToolCallResult result) => {
      'role': 'tool',
      'tool_call_id': result.callId,
      'content': result.content,
    };

/// 解析工具参数 JSON（坏 JSON 返回空 Map）
Map<String, dynamic> parseToolArguments(String raw) {
  if (raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : const {};
  } catch (_) {
    return const {};
  }
}
