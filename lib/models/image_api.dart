import 'dart:convert';

/// 生图 API 配置（Image Forge）：用户在设置页配置的文生图服务
///
/// 仅支持 OpenAI 兼容格式（POST {baseUrl}/images/generations，
/// 返回 data[0].url 或 data[0].b64_json）——智谱 CogView/硅基流动/
/// OpenAI/多数聚合网关均为此格式。
/// 纯本地 SQLite 存储（image_apis 表，DB v23）。
class ImageApi {
  final String id;

  /// 显示名（如「智谱 CogView」）
  String name;

  /// API 基础地址（如 https://open.bigmodel.cn/api/paas/v4，
  /// 工具调用时拼 /images/generations）
  String baseUrl;

  /// API Key（Bearer 认证）
  String apiKey;

  /// 模型名（如 cogview-4、flux-schnell）
  String model;

  /// 默认尺寸（如 1024x1024；模型可按需覆盖）
  String size;

  /// 启用开关（禁用后不进工具目录）
  bool enabled;

  final int createdAt;
  int updatedAt;

  ImageApi({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.size = '1024x1024',
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'base_url': baseUrl,
        'api_key': apiKey,
        'model': model,
        'size': size,
        'enabled': enabled ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory ImageApi.fromMap(Map<String, dynamic> map) => ImageApi(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? '',
        baseUrl: (map['base_url'] as String?) ?? '',
        apiKey: (map['api_key'] as String?) ?? '',
        model: (map['model'] as String?) ?? '',
        size: (map['size'] as String?) ?? '1024x1024',
        enabled: ((map['enabled'] as int?) ?? 1) == 1,
        createdAt: (map['created_at'] as int?) ?? 0,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );

  /// 请求体 JSON（OpenAI images/generations 格式）
  String requestBody(String prompt, {String? sizeOverride}) =>
      jsonEncode({
        'model': model,
        'prompt': prompt,
        'size': sizeOverride ?? size,
      });
}
