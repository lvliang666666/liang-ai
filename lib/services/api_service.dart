import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/provider_profile.dart';
import 'sse_parser.dart';

/// API 调用异常（带用户可读信息）
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// OpenAI 兼容聊天 API 服务（SSE 流式）
///
/// 请求组装与响应解析由 [ProviderProfile] 驱动：
/// - 方言参数（推理档位）仅在 profile.dialect.effortParam 声明时发送
/// - 思考流字段按 profile.dialect.reasoningField 解析
class ApiService {
  ApiService({required String baseUrl, required String apiKey})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 5),
          headers: {'Authorization': 'Bearer $apiKey'},
        ));

  final Dio _dio;

  /// 发起流式对话请求
  ///
  /// [messages] 为 OpenAI 格式消息列表（content 可为字符串或多模态数组）；
  /// [effort] 为推理档位 max/high/low（仅方言声明 effortParam 时发送）；
  /// [tools] 为 OpenAI function calling 工具定义（null/空 = 不发送）。
  /// 返回 SSE 事件流；通过取消返回的 Stream 订阅或 [cancelToken] 可中断。
  Stream<SseEvent> chatStream({
    required ProviderProfile profile,
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required CancelToken cancelToken,
    double temperature = 0.7,
    List<Map<String, Object?>>? tools,
  }) async* {
    final parser = SseParser(reasoningField: profile.dialect.reasoningField);
    try {
      final response = await _dio.post<ResponseBody>(
        '/chat/completions',
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
        data: _buildBody(
          profile: profile,
          messages: messages,
          model: model,
          effort: effort,
          temperature: temperature,
          tools: tools,
        ),
      );

      final stream = response.data!.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stream) {
        for (final event in parser.addChunk('$line\n')) {
          yield event;
          if (event is SseDone || event is SseError) return;
        }
      }
      // 流结束但没收到 [DONE]：flush 残留行
      for (final event in parser.flush()) {
        yield event;
        if (event is SseDone || event is SseError) return;
      }
      if (!parser.isDone) yield const SseDone();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow; // 停止生成，由上层处理
      throw ApiException(_mapError(e, profile), statusCode: e.response?.statusCode);
    }
  }

  /// 请求体组装：方言参数按 profile 声明注入
  static Map<String, Object?> _buildBody({
    required ProviderProfile profile,
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required double temperature,
    List<Map<String, Object?>>? tools,
  }) {
    final body = <String, Object?>{
      'model': model,
      'messages': messages,
      'stream': true,
      'temperature': temperature,
    };
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }
    // glm 方言：chat_template_kwargs.reasoning_effort
    final effortParam = profile.dialect.effortParam;
    if (effortParam != null && effortParam.isNotEmpty) {
      body['chat_template_kwargs'] = {effortParam: effort};
    }
    return body;
  }

  /// 测试入口：暴露请求体组装逻辑
  static Map<String, Object?> buildBodyForTest({
    required ProviderProfile profile,
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required double temperature,
    List<Map<String, Object?>>? tools,
  }) =>
      _buildBody(
        profile: profile,
        messages: messages,
        model: model,
        effort: effort,
        temperature: temperature,
        tools: tools,
      );

  /// 错误映射为用户可读文案（供应商专属提示按 profile 定制）
  static String _mapError(DioException e, ProviderProfile profile) {
    final code = e.response?.statusCode;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '请求超时，请检查网络后重试';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查网络';
      default:
        switch (code) {
          case 401:
            return 'API Key 无效或已过期，请在设置中检查';
          case 403:
            return profile.isBuiltin
                ? '访问被拒绝（域名白名单限制），请使用设置中的预设域名'
                : '访问被拒绝（HTTP 403），请检查 Base URL 与 Key';
          case 429:
            return '请求过于频繁，请稍后重试';
          default:
            final data = e.response?.data;
            if (data is Map && data['error']?['message'] != null) {
              return '服务错误：${data['error']['message']}';
            }
            return '请求失败${code != null ? '（HTTP $code）' : ''}';
        }
    }
  }

  void dispose() => _dio.close();
}
