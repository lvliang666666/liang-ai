import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

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
  /// [effort] 为推理档位 max/high/low。
  /// 返回 SSE 事件流；通过取消返回的 Stream 订阅或 [cancelToken] 可中断。
  Stream<SseEvent> chatStream({
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required CancelToken cancelToken,
    double temperature = 0.7,
  }) async* {
    final parser = SseParser();
    try {
      final response = await _dio.post<ResponseBody>(
        '/chat/completions',
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
        data: {
          'model': model,
          'messages': messages,
          'stream': true,
          'temperature': temperature,
          'chat_template_kwargs': {'reasoning_effort': effort},
        },
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
      throw ApiException(_mapError(e), statusCode: e.response?.statusCode);
    }
  }

  /// 错误映射为用户可读文案
  static String _mapError(DioException e) {
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
            return '访问被拒绝（域名白名单限制），请使用设置中的预设域名';
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
