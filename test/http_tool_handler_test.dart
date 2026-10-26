import 'dart:typed_data';

import 'package:ai_chat_app/models/http_tool.dart';
import 'package:ai_chat_app/services/tools/http_tool_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可编程的 HttpClientAdapter：按 URL 脚本返回响应，记录收到的请求
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  /// 返回 [status, body]；抛异常 = 网络错误
  final (int, String) Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) = respond(options);
    return ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

HttpTool tool({
  String urlTemplate = 'https://api.example.com/weather?city={city}',
  String method = 'GET',
  String headersJson = '',
  String bodyTemplate = '',
  String parametersJson = '',
  String responsePath = '',
  int maxResponseChars = 4000,
}) =>
    HttpTool(
      id: 't1',
      name: 'query_weather',
      description: '查询天气',
      urlTemplate: urlTemplate,
      method: method,
      headersJson: headersJson,
      bodyTemplate: bodyTemplate,
      parametersJson: parametersJson,
      responsePath: responsePath,
      maxResponseChars: maxResponseChars,
      createdAt: 1,
      updatedAt: 1,
    );

void main() {
  late _FakeAdapter adapter;
  late Dio dio;

  setUp(() {
    adapter = _FakeAdapter((options) => (200, '{"temp": 25}'));
    dio = Dio()..httpClientAdapter = adapter;
  });

  group('HttpToolHandler', () {
    test('GET：URL 模板替换 + headers 透传 + 原文返回', () async {
      final handler = HttpToolHandler(
        tool(headersJson: '{"Authorization": "Bearer k"}'),
        dio: dio,
      );
      final out = await handler.execute({'city': '上海'});

      expect(out, '{"temp": 25}');
      final req = adapter.requests.single;
      expect(req.uri.toString(),
          'https://api.example.com/weather?city=%E4%B8%8A%E6%B5%B7');
      expect(req.method, 'GET');
      expect(req.headers['Authorization'], 'Bearer k');
    });

    test('POST：body 模板渲染', () async {
      final handler = HttpToolHandler(
        tool(
          method: 'POST',
          urlTemplate: 'https://api.example.com/search',
          bodyTemplate: '{"q": "{city}", "unit": "{unit}"}',
        ),
        dio: dio,
      );
      await handler.execute({'city': '北京', 'unit': 'c'});

      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.data, '{"q": "北京", "unit": "c"}');
    });

    test('GET 忽略 body 模板', () async {
      final handler = HttpToolHandler(
        tool(
          method: 'GET',
          urlTemplate: 'https://x.com/a',
          bodyTemplate: '{"q": "{city}"}',
        ),
        dio: dio,
      );
      await handler.execute({'city': 'x'});
      expect(adapter.requests.single.data, isNull);
    });

    test('缺失参数：占位符原样保留（模型可从结果看到漏传）', () async {
      final handler = HttpToolHandler(tool(), dio: dio);
      await handler.execute({});
      expect(adapter.requests.single.uri.toString(),
          contains('city=%7Bcity%7D')); // {city} 被 URL 编码
    });

    test('responsePath：点路径截取嵌套字段', () async {
      adapter = _FakeAdapter(
          (_) => (200, '{"data": {"items": [{"name": "服务器A"}, {"name": "B"}]}}'));
      dio.httpClientAdapter = adapter;

      final handler = HttpToolHandler(
        tool(responsePath: 'data.items.0.name'),
        dio: dio,
      );
      expect(await handler.execute({}), '服务器A');
    });

    test('responsePath：对象结果格式化输出', () async {
      final handler = HttpToolHandler(
        tool(responsePath: 'data'),
        dio: dio,
      );
      final out = await handler.execute({});
      expect(out, contains('"temp"'));
      expect(out, contains('25'));
    });

    test('responsePath 未命中：返回全文 + 提示', () async {
      final handler = HttpToolHandler(
        tool(responsePath: 'no.such.path'),
        dio: dio,
      );
      final out = await handler.execute({});
      expect(out, contains('{"temp": 25}'));
      expect(out, contains('未命中'));
    });

    test('非 JSON 响应：原文返回（responsePath 不炸）', () async {
      adapter = _FakeAdapter((_) => (200, 'plain text ok'));
      dio.httpClientAdapter = adapter;
      final handler = HttpToolHandler(
        tool(responsePath: 'data'),
        dio: dio,
      );
      expect(await handler.execute({}), 'plain text ok');
    });

    test('HTTP 500：返回状态码 + 响应体（不抛异常）', () async {
      adapter = _FakeAdapter((_) => (500, 'server exploded'));
      dio.httpClientAdapter = adapter;
      final handler = HttpToolHandler(tool(), dio: dio);
      final out = await handler.execute({});
      expect(out, contains('HTTP 500'));
      expect(out, contains('server exploded'));
    });

    test('网络异常：抛异常（ToolRegistry 转 isError）', () async {
      adapter = _FakeAdapter((options) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          ));
      dio.httpClientAdapter = adapter;
      final handler = HttpToolHandler(tool(), dio: dio);
      expect(() => handler.execute({}), throwsException);
    });

    test('URL 模板为空：抛异常', () async {
      final handler = HttpToolHandler(tool(urlTemplate: ''), dio: dio);
      expect(() => handler.execute({}), throwsArgumentError);
    });

    test('响应截断到 maxResponseChars', () async {
      final long = 'x' * 5000;
      adapter = _FakeAdapter((_) => (200, long));
      dio.httpClientAdapter = adapter;
      final handler = HttpToolHandler(
        tool(maxResponseChars: 100),
        dio: dio,
      );
      final out = await handler.execute({});
      expect(out.length, 100 + '…（已截断）'.length);
      expect(out, endsWith('…（已截断）'));
    });

    test('ToolHandler 接口：name/description/schema 透传', () {
      final handler = HttpToolHandler(
        tool(parametersJson: '{"city": {"type": "string"}}'),
        dio: dio,
      );
      expect(handler.name, 'query_weather');
      expect(handler.description, '查询天气');
      expect(handler.parametersSchema['type'], 'object');
      expect(
        (handler.parametersSchema['properties'] as Map)['city'],
        isNotNull,
      );
    });

    test('空描述：默认描述兜底', () {
      final handler = HttpToolHandler(
        tool()..description = '',
        dio: dio,
      );
      expect(handler.description, '调用 query_weather 接口');
    });
  });
}
