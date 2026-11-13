import 'dart:convert';

import 'http_tool.dart';

/// 待审批 HTTP 工具（自我迭代批次）：模型经 manage_http_tool 提交的
/// 工具定义，用户在审批卡片（聊天流/设置页 Tools tab）确认后才落
/// http_tools 表生效。
///
/// 存储哲学（与草稿存活同源）：审批是会话内瞬时态但可能跨进程——
/// 杀 app 重进后卡片还在、还能批，所以落 DB（pending_tools 表，v22）
/// 而非内存。不进备份（审批态是过程数据，备份恢复后让模型重新提交）；
/// 会话删除级联删（审批上下文随会话消失）。
class PendingTool {
  final String id;

  /// 提交来源会话（审批卡片定位 + 会话删除级联删）
  final String sessionId;

  /// 工具名（OpenAI function name 规范，落库前二次校验）
  final String name;

  /// 给模型看的功能描述
  final String description;

  /// URL 模板（{param} 占位符，同 HttpTool）
  final String urlTemplate;

  /// HTTP 方法（GET/POST/PUT/DELETE/PATCH）
  final String method;

  /// 请求头（JSON 对象字符串）
  final String headersJson;

  /// 请求体模板（POST/PUT/PATCH 用）
  final String bodyTemplate;

  /// 参数定义（JSON Schema properties 段字符串）
  final String parametersJson;

  /// 响应截取路径（点路径，空 = 全文）
  final String responsePath;

  final int createdAt;

  PendingTool({
    required this.id,
    required this.sessionId,
    required this.name,
    this.description = '',
    required this.urlTemplate,
    this.method = 'GET',
    this.headersJson = '',
    this.bodyTemplate = '',
    this.parametersJson = '',
    this.responsePath = '',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'name': name,
        'description': description,
        'url_template': urlTemplate,
        'method': method,
        'headers_json': headersJson,
        'body_template': bodyTemplate,
        'parameters_json': parametersJson,
        'response_path': responsePath,
        'created_at': createdAt,
      };

  factory PendingTool.fromMap(Map<String, dynamic> map) => PendingTool(
        id: map['id'] as String,
        sessionId: (map['session_id'] as String?) ?? '',
        name: (map['name'] as String?) ?? '',
        description: (map['description'] as String?) ?? '',
        urlTemplate: (map['url_template'] as String?) ?? '',
        method: (map['method'] as String?) ?? 'GET',
        headersJson: (map['headers_json'] as String?) ?? '',
        bodyTemplate: (map['body_template'] as String?) ?? '',
        parametersJson: (map['parameters_json'] as String?) ?? '',
        responsePath: (map['response_path'] as String?) ?? '',
        createdAt: (map['created_at'] as int?) ?? 0,
      );

  /// 转正式 HttpTool（审批通过时调用；id 沿用 pending id 保证可溯源）
  HttpTool toHttpTool() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return HttpTool(
      id: id,
      name: name,
      description: description,
      urlTemplate: urlTemplate,
      method: method,
      headersJson: headersJson,
      bodyTemplate: bodyTemplate,
      parametersJson: parametersJson,
      responsePath: responsePath,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 试运行用临时 HttpTool（不落库，id 随意——handler 只读字段）
  HttpTool toPreviewTool() => toHttpTool();

  /// 参数定义解析为 JSON Schema properties（坏 JSON 返回空，同 HttpTool）
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
}
