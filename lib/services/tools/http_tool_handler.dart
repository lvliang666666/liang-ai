import 'dart:convert';

import 'package:dio/dio.dart';

import '../../models/http_tool.dart';
import '../tool_registry.dart';

/// 自定义 HTTP 工具执行器（T1）：把用户配置的 HTTP API 包装成 ToolHandler
///
/// 执行流程：模板替换（{param} → 实参）→ dio 请求（超时 15s）→
/// 响应截取（responsePath 点路径）→ 截断到 maxResponseChars。
/// 任何失败抛异常（ToolRegistry.execute 捕获后转 isError 结果，
/// loop 不中断——模型能看到错误文本自行调整）。
class HttpToolHandler extends ToolHandler {
  HttpToolHandler(this.tool, {Dio? dio}) : _dio = dio;

  final HttpTool tool;
  final Dio? _dio;

  @override
  String get name => tool.name;

  @override
  String get description => tool.description.isEmpty
      ? '调用 ${tool.name} 接口'
      : tool.description;

  @override
  Map<String, dynamic> get parametersSchema => tool.parametersSchema;

  /// 请求超时
  static const timeout = Duration(seconds: 15);

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final url = _render(tool.urlTemplate, arguments);
    if (url.isEmpty) {
      throw ArgumentError('URL 模板为空');
    }
    final hasBody = switch (tool.method.toUpperCase()) {
      'POST' || 'PUT' || 'PATCH' => true,
      _ => false,
    };
    final body = hasBody && tool.bodyTemplate.trim().isNotEmpty
        ? _render(tool.bodyTemplate, arguments)
        : null;

    final dio = _dio ??
        Dio(BaseOptions(
          connectTimeout: timeout,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          validateStatus: (_) => true, // 非 2xx 不抛，由下方统一转文本
        ));

    final Response<dynamic> response;
    try {
      response = await dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: tool.method.toUpperCase(),
          headers: tool.headers,
          responseType: ResponseType.plain,
          // 非 2xx 不抛（覆盖外部传入 dio 的默认校验），由下方统一转文本
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw Exception('请求失败：${e.message ?? e.type.name}');
    }

    final raw = response.data?.toString() ?? '';
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      return '请求返回 HTTP $status：${_truncate(raw, 500)}';
    }

    var text = _extract(raw, tool.responsePath);
    return _truncate(text, tool.maxResponseChars);
  }

  /// 模板渲染：{param} 占位符替换为实参（缺失的占位符原样保留——
  /// 让模型从结果里看到自己漏传了什么）
  static String _render(String template, Map<String, dynamic> arguments) {
    return template.replaceAllMapped(
      RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}'),
      (match) {
        final key = match.group(1)!;
        final value = arguments[key];
        return value == null ? match.group(0)! : value.toString();
      },
    );
  }

  /// 响应截取：responsePath 点路径（data.items / data.0.name），
  /// 空 = 返回原文；路径不存在返回原文（附提示）
  static String _extract(String raw, String path) {
    final p = path.trim();
    if (p.isEmpty) return raw;
    Object? current = raw;
    try {
      current = raw.isEmpty ? null : (jsonDecode(raw) as Object?);
    } catch (_) {
      return raw; // 非 JSON 响应：原文返回
    }
    for (final seg in p.split('.')) {
      if (current is Map<String, dynamic>) {
        current = current[seg];
      } else if (current is List) {
        final index = int.tryParse(seg);
        current = index != null && index >= 0 && index < current.length
            ? current[index]
            : null;
      } else {
        current = null;
      }
      if (current == null) break;
    }
    if (current == null) {
      return '$raw\n（提示：响应路径 "$p" 未命中，已返回全文）';
    }
    if (current is String) return current;
    try {
      return const JsonEncoder.withIndent('  ').convert(current);
    } catch (_) {
      return current.toString();
    }
  }

  static String _truncate(String text, int max) =>
      text.length > max ? '${text.substring(0, max)}…（已截断）' : text;
}
