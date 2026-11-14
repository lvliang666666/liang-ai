import 'dart:io';

import 'package:ai_chat_app/models/image_api.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/tools/generate_image_tool.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程 dio mock：拦截 post/get 返回脚本化响应
class MockDio implements Dio {
  Map<String, dynamic>? postResponse;
  Object? postError;
  List<int>? getBytes;
  int postCalls = 0;
  Map<String, Object?>? lastPostData;
  String? lastPostUrl;

  @override
  Future<Response<T>> post<T>(String path,
      {Object? data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken,
      void Function(int, int)? onSendProgress,
      void Function(int, int)? onReceiveProgress}) async {
    postCalls++;
    lastPostUrl = path;
    lastPostData = data as Map<String, Object?>?;
    if (postError != null) throw postError!;
    return Response<T>(
      data: postResponse as T?,
      requestOptions: RequestOptions(path: path),
    );
  }

  @override
  Future<Response<T>> get<T>(String path,
      {Object? data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken,
      void Function(int, int)? onReceiveProgress}) async {
    return Response<T>(
      data: getBytes as T?,
      requestOptions: RequestOptions(path: path),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('MockDio 未实现：${invocation.memberName}');
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('gen_img_test');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  const config = ImageApiConfig(
    name: '智谱',
    baseUrl: 'https://api.example.com/v4',
    apiKey: 'test-key',
    model: 'cogview-4',
    size: '1024x1024',
  );

  GenerateImageTool tool(MockDio dio, {List<ImageApiConfig>? apis}) =>
      GenerateImageTool(
          enabledApis: apis ?? const [config],
          outputDir: tmpDir,
          dio: dio);

  group('参数校验', () {
    test('空 prompt 抛 ArgumentError', () {
      expect(() => tool(MockDio()).execute({'prompt': '  '}),
          throwsArgumentError);
    });

    test('未配置 API 抛 StateError（引导去设置页）', () {
      expect(
        () => GenerateImageTool(
                enabledApis: const [], outputDir: tmpDir)
            .execute({'prompt': 'x'}),
        throwsStateError,
      );
    });

    test('未注入输出目录抛 StateError', () {
      expect(
        () => GenerateImageTool(enabledApis: const [config])
            .execute({'prompt': 'x'}),
        throwsStateError,
      );
    });

    test('api_name 指定不存在的服务报可用清单', () {
      expect(
        () => tool(MockDio())
            .execute({'prompt': 'x', 'api_name': '不存在'}),
        throwsArgumentError,
      );
    });
  });

  group('请求与响应', () {
    test('POST 到 {baseUrl}/images/generations，body 含 model/prompt/size',
        () async {
      final dio = MockDio()
        ..postResponse = {
          'data': [
            {'b64_json': 'aGVsbG8='} // "hello" 的 base64
          ]
        };
      final out = await tool(dio)
          .execute({'prompt': '一只橘猫', 'size': '512x512'});
      expect(dio.postCalls, 1);
      expect(dio.lastPostUrl, 'https://api.example.com/v4/images/generations');
      expect(dio.lastPostData?['model'], 'cogview-4');
      expect(dio.lastPostData?['prompt'], '一只橘猫');
      expect(dio.lastPostData?['size'], '512x512');
      expect(out, contains('[FILE:'));
    });

    test('b64_json 返回：解码落盘', () async {
      final dio = MockDio()
        ..postResponse = {
          'data': [
            {'b64_json': 'aGVsbG8='}
          ]
        };
      final out = await tool(dio).execute({'prompt': 'x'});
      final path =
          RegExp(r'\[FILE:([^\]]+)\]').firstMatch(out)!.group(1)!;
      final f = File(path);
      expect(f.existsSync(), isTrue);
      expect(f.readAsBytesSync(), 'hello'.codeUnits);
    });

    test('url 返回：下载落盘', () async {
      final dio = MockDio()
        ..postResponse = {
          'data': [
            {'url': 'https://cdn.example.com/img.png'}
          ]
        }
        ..getBytes = [1, 2, 3, 4];
      final out = await tool(dio).execute({'prompt': 'x'});
      final path =
          RegExp(r'\[FILE:([^\]]+)\]').firstMatch(out)!.group(1)!;
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('data URL 前缀的 b64_json 容错', () async {
      final dio = MockDio()
        ..postResponse = {
          'data': [
            {'b64_json': 'data:image/png;base64,aGVsbG8='}
          ]
        };
      final out = await tool(dio).execute({'prompt': 'x'});
      final path =
          RegExp(r'\[FILE:([^\]]+)\]').firstMatch(out)!.group(1)!;
      expect(File(path).readAsBytesSync(), 'hello'.codeUnits);
    });

    test('HTTP 错误透传状态码与响应体', () async {
      final dio = MockDio()
        ..postError = DioException(
          requestOptions: RequestOptions(path: '/x'),
          response: Response(
            requestOptions: RequestOptions(path: '/x'),
            statusCode: 401,
            data: 'invalid api key',
          ),
        );
      await expectLater(
        tool(dio).execute({'prompt': 'x'}),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('401'))),
      );
    });

    test('响应缺 data 数组报格式异常', () async {
      final dio = MockDio()..postResponse = {'error': 'bad'};
      await expectLater(
        tool(dio).execute({'prompt': 'x'}),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('data'))),
      );
    });
  });

  group('DB v23 迁移', () {
    test('image_apis 表 CRUD 往返', () async {
      final inMemory = await openTestDb();
      final db = DatabaseService.instance;
      await db.initForTest(inMemory);

      final api = ImageApi(
        id: 'a1',
        name: '智谱',
        baseUrl: 'https://api.example.com/v4',
        apiKey: 'k1',
        model: 'cogview-4',
        size: '1024x1024',
        createdAt: 1000,
        updatedAt: 1000,
      );
      await db.insertImageApi(api);
      final all = await db.getAllImageApis();
      expect(all.length, 1);
      expect(all.single.name, '智谱');
      expect(all.single.enabled, isTrue);

      await db.updateImageApi(ImageApi(
        id: 'a1',
        name: '智谱改',
        baseUrl: api.baseUrl,
        apiKey: api.apiKey,
        model: api.model,
        enabled: false,
        createdAt: 1000,
        updatedAt: 2000,
      ));
      final updated = await db.getAllImageApis();
      expect(updated.single.name, '智谱改');
      expect(updated.single.enabled, isFalse);

      await db.deleteImageApi('a1');
      expect(await db.getAllImageApis(), isEmpty);
      await db.close();
    });
  });
}
