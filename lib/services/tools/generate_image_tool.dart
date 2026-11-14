import 'dart:convert' show Base64Decoder;
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../tool_registry.dart';

/// 单个生图 API 配置的只读视图（工具层不依赖 provider/DB）
class ImageApiConfig {
  const ImageApiConfig({
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.size,
  });

  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String size;
}

/// 生图工具（Image Forge）：模型按需调用户配置的生图 API 出图
///
/// 仅 OpenAI 兼容格式（POST {baseUrl}/images/generations，返回
/// data[0].url 或 data[0].b64_json）——智谱 CogView/硅基流动/OpenAI/
/// 多数聚合网关均为此格式。
///
/// 配置由宿主注入（启用清单 + 缺省项），工具保持纯 Dart 可单测
/// （dio 可注入 mock）。图片落盘沙箱 attachments 目录，返回
/// [FILE:<path>] 标记——与 Document Forge 同链路（附件消息 + 缩略图）。
class GenerateImageTool extends ToolHandler {
  GenerateImageTool({
    required List<ImageApiConfig> enabledApis,
    this.outputDir,
    Dio? dio,
  })  : _enabledApis = enabledApis,
        _dio = dio ?? Dio();

  final List<ImageApiConfig> _enabledApis;
  final Directory? outputDir;
  final Dio _dio;

  /// 是否已注入可用配置（注册表重建时判断：已配置的实例保留）
  bool get hasApis => _enabledApis.isNotEmpty;

  @override
  String get name => 'generate_image';

  @override
  String get description =>
      '根据文字描述生成图片（AI 绘画），图片会作为会话附件显示。'
      'prompt 用一段话描述画面内容（主体/风格/氛围/构图，越具体越好）。'
      'api_name 可选：指定用哪个已配置的生图服务（省略用默认）。'
      'size 可选：图片尺寸如 1024x1024（省略用服务默认）。'
      '适合：用户要插画/配图/示意图/logo 等场景。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'prompt': {
            'type': 'string',
            'description': '画面描述（主体/风格/氛围/构图，一段话）',
          },
          'api_name': {
            'type': 'string',
            'description': '生图服务名（可选，省略用默认启用的服务）',
          },
          'size': {
            'type': 'string',
            'description': '图片尺寸（可选，如 1024x1024）',
          },
        },
        'required': ['prompt'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final prompt = arguments['prompt'];
    if (prompt is! String || prompt.trim().isEmpty) {
      throw ArgumentError('prompt 不能为空');
    }
    if (_enabledApis.isEmpty) {
      throw StateError('未配置生图 API：请在 设置 → 生图 API 中添加');
    }

    // 选配置：api_name 指定 > 第一个启用
    final apiName = arguments['api_name'];
    ImageApiConfig api;
    if (apiName is String && apiName.trim().isNotEmpty) {
      final found = _enabledApis.where(
          (a) => a.name == apiName.trim() || a.model == apiName.trim());
      if (found.isEmpty) {
        throw ArgumentError(
            '未找到生图服务「${apiName.trim()}」，可用：${_enabledApis.map((a) => a.name).join('、')}');
      }
      api = found.first;
    } else {
      api = _enabledApis.first;
    }

    final dir = outputDir;
    if (dir == null) {
      throw StateError('输出目录未注入（宿主配置缺失）');
    }
    final sizeArg = arguments['size'];
    final size =
        sizeArg is String && sizeArg.trim().isNotEmpty ? sizeArg.trim() : api.size;

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final fileName = 'img_${DateTime.now().millisecondsSinceEpoch}';
    final path = '${dir.path}${Platform.pathSeparator}$fileName.png';

    // 请求 OpenAI 兼容 images/generations
    final url = api.baseUrl.endsWith('/')
        ? '${api.baseUrl}images/generations'
        : '${api.baseUrl}/images/generations';
    final Response<Map<String, dynamic>> resp;
    try {
      resp = await _dio.post<Map<String, dynamic>>(
        url,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${api.apiKey}',
            'Content-Type': 'application/json',
          },
          // 生图慢（10-60s），给足超时
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 120),
        ),
        data: {
          'model': api.model,
          'prompt': prompt.trim(),
          'size': size,
        },
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data?.toString() ?? '';
      throw StateError(
          '生图请求失败${status != null ? '（HTTP $status）' : ''}：'
          '${body.isEmpty ? e.message : body.substring(0, body.length.clamp(0, 300))}');
    }

    final data = resp.data?['data'];
    if (data is! List || data.isEmpty) {
      throw StateError('生图响应缺少 data 数组：${resp.data?.keys.toList()}');
    }
    final first = data.first;
    if (first is! Map) {
      throw StateError('生图响应 data[0] 格式异常');
    }

    // 两种返回：url（平台侧托管）或 b64_json（内联）
    Uint8List bytes;
    final url0 = first['url'];
    final b64 = first['b64_json'];
    if (url0 is String && url0.isNotEmpty) {
      final dl = await _dio.get<List<int>>(
        url0,
        options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 120)),
      );
      bytes = Uint8List.fromList(dl.data ?? const []);
    } else if (b64 is String && b64.isNotEmpty) {
      bytes = base64ToBytes(b64);
    } else {
      throw StateError('生图响应既无 url 也无 b64_json');
    }
    if (bytes.isEmpty) {
      throw StateError('生图响应下载为空');
    }

    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return '图片已生成：${file.path}\n[FILE:${file.path}]';
  }

  /// base64 解码（容错 data URL 前缀）
  static Uint8List base64ToBytes(String b64) {
    var s = b64;
    final comma = s.indexOf(',');
    if (s.startsWith('data:') && comma > 0) {
      s = s.substring(comma + 1);
    }
    return Uint8List.fromList(const Base64Decoder().convert(s));
  }
}
