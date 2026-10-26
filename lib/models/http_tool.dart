import 'dart:convert';

/// 自定义 HTTP 工具（T1）：用户配置的任意 HTTP API，注册为 Agent 工具
///
/// 模型侧看到的是标准 function 定义（name/description/parameters），
/// 调用时 [HttpToolHandler] 把参数代入 URL/body 模板发请求。
/// 纯本地 SQLite 存储（http_tools 表，DB v10）。
class HttpTool {
  final String id;

  /// 工具名（OpenAI function name 规范：字母/数字/下划线/连字符）
  String name;

  /// 给模型看的功能描述（影响模型何时调用）
  String description;

  /// URL 模板，支持 {param} 占位符（路径参数或查询参数）
  String urlTemplate;

  /// HTTP 方法（GET/POST/PUT/DELETE/PATCH）
  String method;

  /// 请求头（JSON 对象字符串，如 {"Authorization": "Bearer xxx"}）
  String headersJson;

  /// 请求体模板（POST/PUT/PATCH 用），支持 {param} 占位符；GET 时忽略
  String bodyTemplate;

  /// 参数定义（JSON Schema 的 properties 段字符串，模型按此填参）
  String parametersJson;

  /// 响应截取路径（如 data.items 或 data.0.name；空 = 返回全文）
  String responsePath;

  /// 响应文本最大长度（超出截断，防撑爆上下文）
  int maxResponseChars;

  /// 启用开关（禁用后不进工具目录）
  bool enabled;

  final int createdAt;
  int updatedAt;

  HttpTool({
    required this.id,
    required this.name,
    this.description = '',
    required this.urlTemplate,
    this.method = 'GET',
    this.headersJson = '',
    this.bodyTemplate = '',
    this.parametersJson = '',
    this.responsePath = '',
    this.maxResponseChars = 4000,
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'url_template': urlTemplate,
        'method': method,
        'headers_json': headersJson,
        'body_template': bodyTemplate,
        'parameters_json': parametersJson,
        'response_path': responsePath,
        'max_response_chars': maxResponseChars,
        'enabled': enabled ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory HttpTool.fromMap(Map<String, dynamic> map) => HttpTool(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? '',
        description: (map['description'] as String?) ?? '',
        urlTemplate: (map['url_template'] as String?) ?? '',
        method: (map['method'] as String?) ?? 'GET',
        headersJson: (map['headers_json'] as String?) ?? '',
        bodyTemplate: (map['body_template'] as String?) ?? '',
        parametersJson: (map['parameters_json'] as String?) ?? '',
        responsePath: (map['response_path'] as String?) ?? '',
        maxResponseChars: (map['max_response_chars'] as int?) ?? 4000,
        enabled: ((map['enabled'] as int?) ?? 1) != 0,
        createdAt: (map['created_at'] as int?) ?? 0,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );

  HttpTool copyWith({
    String? name,
    String? description,
    String? urlTemplate,
    String? method,
    String? headersJson,
    String? bodyTemplate,
    String? parametersJson,
    String? responsePath,
    int? maxResponseChars,
    bool? enabled,
    int? updatedAt,
  }) =>
      HttpTool(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        urlTemplate: urlTemplate ?? this.urlTemplate,
        method: method ?? this.method,
        headersJson: headersJson ?? this.headersJson,
        bodyTemplate: bodyTemplate ?? this.bodyTemplate,
        parametersJson: parametersJson ?? this.parametersJson,
        responsePath: responsePath ?? this.responsePath,
        maxResponseChars: maxResponseChars ?? this.maxResponseChars,
        enabled: enabled ?? this.enabled,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 模板里的 {param} 占位符集合（去重保序）
  ///
  /// URL 与 body 模板合并提取；{name} 形式，`{{`/`}}` 转义不参与。
  static List<String> placeholdersIn(String template) {
    final result = <String>[];
    final seen = <String>{};
    final regex = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');
    for (final match in regex.allMatches(template)) {
      final name = match.group(1)!;
      if (seen.add(name)) result.add(name);
    }
    return result;
  }

  /// 全部占位符（URL + body 模板合并）
  List<String> get placeholders => [
        ...placeholdersIn(urlTemplate),
        ...placeholdersIn(bodyTemplate).where(
            (p) => !placeholdersIn(urlTemplate).contains(p)),
      ];

  /// 解析 headersJson 为 Map（坏 JSON/非对象返回空 Map）
  Map<String, String> get headers {
    if (headersJson.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(headersJson);
      if (decoded is! Map<String, dynamic>) return const {};
      return {
        for (final e in decoded.entries)
          if (e.value != null) e.key.toString(): e.value.toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  /// 解析 parametersJson 为 JSON Schema properties（坏 JSON 返回空）
  Map<String, dynamic> get parameters {
    if (parametersJson.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(parametersJson);
      if (decoded is Map<String, dynamic>) return decoded;
      return const {};
    } catch (_) {
      return const {};
    }
  }

  /// OpenAI function parameters schema（由用户配置的 properties 组装）
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': parameters,
      };

  /// 工具名是否合法（OpenAI function name 规范）
  static bool isValidName(String name) =>
      RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(name);
}
