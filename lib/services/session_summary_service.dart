import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/chat_message.dart';
import '../models/provider_profile.dart';
import '../models/session_summary.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'sse_parser.dart';

/// M4 情景记忆层：会话结束后台生成「标题+摘要+关键词」并静默入库
///
/// 流程：取会话消息 → 强约束 JSON 生成 prompt（low 档低温）→ 收集流式
/// 输出 → 解析（剥 markdown 围栏 + 容错截取，复用 M2 模式）→ 解析失败
/// 回喂重试一次 → [DatabaseService.insertSessionSummary] 入库（每会话
/// 一条，重写覆盖）。
///
/// 静默语义：网络失败/解析失败/无 user+assistant 交换一律安静返回
/// false，不抛异常不弹提示——后台任务不打扰用户。
class SessionSummaryService {
  SessionSummaryService({
    required ApiService api,
    required DatabaseService database,
  })  : _api = api,
        _db = database;

  final ApiService _api;
  final DatabaseService _db;

  /// 生成请求推理档位（轻任务走 low，快且省 token）
  static const effort = 'low';

  /// 生成请求温度（低温保证 JSON 输出稳定）
  static const temperature = 0.2;

  /// 参与生成的最大消息条数（超长会话取最近段，防请求膨胀）
  static const maxMessages = 40;

  /// 摘要长度上限（超出截断；prompt 已约束 150 字以内）
  static const maxSummaryLength = 300;

  /// 关键词数量上限（prompt 已约束 3~6 个）
  static const maxKeywords = 6;

  /// 强约束生成 system prompt：只输出 JSON
  static const _systemPrompt = '''
你是会话摘要器。分析对话记录，生成结构化摘要供日后检索。

【输出】只输出 JSON，禁止输出任何其他文字：
{"title": "会话标题（10字以内）", "summary": "对话内容摘要（150字以内，涵盖讨论主题、关键结论、用户意图）", "keywords": ["关键词1", "关键词2", "关键词3"]}
keywords 取 3~6 个（讨论主题/涉及技术/产品名/人名等检索用词）。''';

  /// 解析失败后的回喂重试指令（只重试一次，防死循环）
  static const _retryPrompt = '''
上面的输出不是合法 JSON。重新输出：只输出 JSON（格式：
{"title": "标题", "summary": "摘要", "keywords": ["关键词"]}），
禁止输出任何其他文字。''';

  /// 会话是否值得生成摘要：至少一条非空 user 消息 + 一条非空 assistant
  /// 回复（工具结果消息与空内容不参与判断；与 M2 shouldExtract 同规则）
  static bool shouldSummarize(List<ChatMessage> messages) {
    var hasUser = false;
    var hasAssistant = false;
    for (final m in messages) {
      if (m.isToolResult || m.content.trim().isEmpty) continue;
      if (m.isUser) {
        hasUser = true;
      } else {
        hasAssistant = true;
      }
    }
    return hasUser && hasAssistant;
  }

  /// 会话文本（生成请求的 user 消息）：角色前缀逐行拼接
  ///
  /// 跳过工具结果与空内容；超长会话只取最近 [maxMessages] 条；
  /// 会话标题作首行上下文。
  static String buildConversationText(
    List<ChatMessage> messages, {
    String? sessionTitle,
  }) {
    final recent = messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    final lines = <String>[
      if (sessionTitle != null && sessionTitle.trim().isNotEmpty)
        '会话主题：${sessionTitle.trim()}',
      for (final m in recent)
        if (!m.isToolResult && m.content.trim().isNotEmpty)
          '${m.isUser ? '用户' : '助手'}：${m.content.trim()}',
    ];
    return lines.join('\n');
  }

  /// 解析模型输出为摘要候选
  ///
  /// 返回 null = 无法解析（触发回喂重试）。容错：剥 markdown 围栏、
  /// 截取首个 `{` 到最后一个 `}`（模型爱在 JSON 外加说明文字）。
  static SessionCandidate? parseCandidate(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    // markdown 围栏：```json ... ``` / ``` ... ```
    if (text.startsWith('```')) {
      final nl = text.indexOf('\n');
      if (nl < 0) return null;
      text = text.substring(nl + 1);
      final fenceEnd = text.lastIndexOf('```');
      if (fenceEnd >= 0) text = text.substring(0, fenceEnd);
      text = text.trim();
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final title = decoded['title'];
    final summary = decoded['summary'];
    if (title is! String || summary is! String) return null;
    if (title.trim().isEmpty || summary.trim().isEmpty) return null;
    final keywordsRaw = decoded['keywords'];
    final keywords = <String>[
      if (keywordsRaw is List)
        for (final k in keywordsRaw)
          if (k is String && k.trim().isNotEmpty) k.trim(),
    ];
    return SessionCandidate(
      title: title.trim(),
      summary: summary.trim(),
      keywords: keywords,
    );
  }

  /// 生成摘要并入库，返回是否成功（任何失败返回 false 静默）
  ///
  /// 生成请求走会话同款供应商与模型（low 档低温）；解析失败回喂重试
  /// 一次；入库按 sessionId 派生 id（`ep_<sessionId>`）replace 覆盖。
  Future<bool> summarizeAndSave({
    required String sessionId,
    required List<ChatMessage> messages,
    required ProviderProfile profile,
    required String model,
    String? sessionTitle,
  }) async {
    if (!shouldSummarize(messages)) return false;
    final conversation =
        buildConversationText(messages, sessionTitle: sessionTitle);

    final first = await _requestJson(profile, model, [
      {'role': 'system', 'content': _systemPrompt},
      {'role': 'user', 'content': conversation},
    ]);
    if (first == null) return false; // 网络失败：静默放弃
    var candidate = parseCandidate(first);
    if (candidate == null) {
      // 解析失败：回喂重试一次（把坏输出喂回去要求纠正）
      final second = await _requestJson(profile, model, [
        {'role': 'system', 'content': _systemPrompt},
        {'role': 'user', 'content': conversation},
        {'role': 'assistant', 'content': first},
        {'role': 'user', 'content': _retryPrompt},
      ]);
      if (second == null) return false;
      candidate = parseCandidate(second);
      if (candidate == null) return false;
    }

    var summary = candidate.summary;
    if (summary.length > maxSummaryLength) {
      summary = summary.substring(0, maxSummaryLength);
    }
    await _db.insertSessionSummary(SessionSummary(
      id: SessionSummary.idFor(sessionId),
      sessionId: sessionId,
      title: candidate.title,
      summary: summary,
      keywords: candidate.keywords.take(maxKeywords).toList(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    return true;
  }

  /// 发起一次生成请求并收集完整输出；失败（网络/服务端错误）返回 null
  Future<String?> _requestJson(
    ProviderProfile profile,
    String model,
    List<Map<String, Object?>> messages,
  ) async {
    final buffer = StringBuffer();
    try {
      await for (final event in _api.chatStream(
        profile: profile,
        messages: messages,
        model: model,
        effort: effort,
        cancelToken: CancelToken(),
        temperature: temperature,
      )) {
        switch (event) {
          case SseDeltaContent(:final text):
            buffer.write(text);
          case SseError():
            return null;
          default:
            break;
        }
      }
    } catch (_) {
      return null; // 后台任务：网络失败静默
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? null : text;
  }
}

/// 生成的会话摘要候选
class SessionCandidate {
  const SessionCandidate({
    required this.title,
    required this.summary,
    required this.keywords,
  });

  final String title;
  final String summary;
  final List<String> keywords;
}
