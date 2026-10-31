import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/chat_message.dart';
import '../models/commitment.dart';
import '../models/provider_profile.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'sse_parser.dart';

/// P3 承诺跟进：从对话提取承诺 + 到期扫描 + 跟进语生成
///
/// 「打开补算式」规避 Android 后台限制（与 P1 晨间简报同策略）：
/// - 提取：会话结束后台跑（复用 M2 提取时机），LLM 强约束 JSON 输出
///   承诺清单（content/dueDate），解析失败回喂重试一次
/// - 扫描：跨天首开时查 pending 且 due_date ≤ 今天的承诺
/// - 跟进语：到期承诺生成一句追问（LLM 优先，本地模板兜底）；
///   同一天不重复生成（follow_up_date 去重，防打扰生命线）
///
/// 静默语义：网络失败/解析失败/无可提取内容一律安静返回，不抛异常
/// 不弹提示——后台任务不打扰用户。
class CommitmentService {
  /// [api] 可选：scanDue 纯 DB 查询不需要网络；generateFollowUps 在
  /// api 为 null 时全走本地模板（与 profile == null 同语义）。
  /// dio 5.11.1 起构造时即校验 baseUrl，禁止再用占位 URL 凑数。
  CommitmentService({ApiService? api, required DatabaseService db})
      : _api = api,
        _db = db;

  final ApiService? _api;
  final DatabaseService _db;

  /// 提取/生成请求推理档位（轻任务走 low，快且省 token）
  static const effort = 'low';

  /// 提取/生成请求温度（低温保证 JSON 输出稳定）
  static const temperature = 0.2;

  /// 参与提取的最大消息条数（超长会话取最近段，防请求膨胀）
  static const maxMessages = 40;

  /// 单条承诺长度上限（超出截断）
  static const maxContentLength = 100;

  /// 单次提取的承诺条数上限（防请求膨胀与低质量刷屏）
  static const maxPerExtraction = 3;

  /// 日期键（yyyy-MM-dd）
  static String dateKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// 强约束提取 system prompt：只输出 JSON
  static const _extractPrompt = '''
你是承诺提取器。分析对话记录，找出用户明确说要做的事（承诺/待办）。

【提取】用户明确承诺要做的事，且能推断出大致期限（如「周五前发周报」「明天把简历改完」「下周约牙医」）。
【不提取】助手承诺的事、闲聊提及、已经完成的事、无法推断期限的模糊愿望（如「以后想学英语」）。
【格式】每条承诺一句话（30 字以内，以动词开头），dueDate 是推断的到期日（yyyy-MM-dd 格式，以对话中最后一条消息的日期为「今天」推算）。
【输出】只输出 JSON，禁止输出任何其他文字：
{"commitments": [{"content": "发周报给组长", "dueDate": "2026-10-31"}]}
没有值得提取的承诺时输出 {"commitments": []}''';

  /// 解析失败后的回喂重试指令（只重试一次，防死循环）
  static const _retryPrompt = '''
上面的输出不是合法 JSON。重新输出：只输出 JSON（格式：
{"commitments": [{"content": "承诺内容", "dueDate": "yyyy-MM-dd"}]}），
没有承诺输出 {"commitments": []}，禁止输出任何其他文字。''';

  /// 跟进语生成 system prompt：只输出纯文本一句话
  static const _followUpPrompt = '''
你是跟进提醒助手。用户之前在对话里承诺过一件事，现在到期了。根据承诺内容和当时的会话主题，写一句自然的跟进语（30 字以内）。

【要求】像朋友随口一问，不指责不施压；点明事项即可，可带一句关心。
【输出】只输出跟进语本身，禁止任何前缀、引号或解释。''';

  /// 本地兜底跟进语模板（LLM 失败时用；简单但可用）
  static String localFollowUp(Commitment c) => '之前说的「${c.content}」到日子了，进展如何？';

  /// 从会话消息提取承诺并入库，返回新增条数（任何失败返回 0）
  ///
  /// 提取请求走会话同款供应商与模型（low 档低温）；解析失败回喂重试
  /// 一次；[today] 是对话发生的日期（期限推算基准，测试可注入）。
  Future<int> extractAndSave({
    required List<ChatMessage> messages,
    required ProviderProfile profile,
    required String model,
    String? sessionId,
    DateTime? today,
  }) async {
    final conversation = _conversationText(messages);
    if (conversation == null) return 0;
    final base = today ?? DateTime.now();

    final first = await _requestJson(profile, model, [
      {'role': 'system', 'content': _extractPrompt},
      {'role': 'user', 'content': '今天日期：${dateKey(base)}\n\n$conversation'},
    ]);
    if (first == null) return 0; // 网络失败：静默放弃
    var candidates = _parseCandidates(first);
    if (candidates == null) {
      // 解析失败：回喂重试一次
      final second = await _requestJson(profile, model, [
        {'role': 'system', 'content': _extractPrompt},
        {'role': 'user', 'content': '今天日期：${dateKey(base)}\n\n$conversation'},
        {'role': 'assistant', 'content': first},
        {'role': 'user', 'content': _retryPrompt},
      ]);
      if (second == null) return 0;
      candidates = _parseCandidates(second);
      if (candidates == null) return 0;
    }
    if (candidates.isEmpty) return 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    var saved = 0;
    for (final c in candidates.take(maxPerExtraction)) {
      var content = c.content;
      if (content.length > maxContentLength) {
        content = content.substring(0, maxContentLength);
      }
      await _db.insertCommitment(Commitment(
        id: 'cm_${now}_$saved',
        sessionId: sessionId,
        content: content,
        dueDate: c.dueDate,
        createdAt: now,
        updatedAt: now,
      ));
      saved++;
    }
    return saved;
  }

  /// 会话文本（提取请求的 user 消息）；无有效对话返回 null
  ///
  /// 复用 M2 的筛选规则：跳过工具结果与空内容，取最近 [maxMessages] 条。
  String? _conversationText(List<ChatMessage> messages) {
    final recent = messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    final lines = <String>[
      for (final m in recent)
        if (!m.isToolResult && m.content.trim().isNotEmpty)
          '${m.isUser ? '用户' : '助手'}：${m.content.trim()}',
    ];
    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  /// 解析模型输出为承诺候选；null = 无法解析（触发回喂重试）
  ///
  /// 容错：剥 markdown 围栏、截取首个 `{` 到最后一个 `}`；dueDate
  /// 格式校验（yyyy-MM-dd 正则），非法置 null（无期限不参与扫描）。
  static List<({String content, String? dueDate})>? _parseCandidates(
      String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
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
    final list = decoded['commitments'];
    if (list is! List) return null;
    final dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    return [
      for (final item in list)
        if (item is Map<String, dynamic> &&
            item['content'] is String &&
            (item['content'] as String).trim().isNotEmpty)
          (
            content: (item['content'] as String).trim(),
            dueDate: item['dueDate'] is String &&
                    dateRe.hasMatch(item['dueDate'] as String)
                ? item['dueDate'] as String
                : null,
          ),
    ];
  }

  /// 到期扫描：pending 且 due_date ≤ 今天的承诺（跨天首开时调用）
  Future<List<Commitment>> scanDue({DateTime? now}) async {
    final today = dateKey(now ?? DateTime.now());
    return _db.getDueCommitments(today);
  }

  /// 为到期承诺生成跟进语并落库（同一天不重复生成），返回待提醒清单
  ///
  /// LLM 生成优先（低温一句话），失败本地模板兜底；follow_up_date =
  /// 今天的跳过（已生成过，防打扰）。[profile] 为 null 时全部走本地模板。
  Future<List<Commitment>> generateFollowUps(
    List<Commitment> due, {
    ProviderProfile? profile,
    String? model,
    String? sessionTopic,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final today = dateKey(at);
    final result = <Commitment>[];
    for (final c in due) {
      if (c.followUpDate == today) {
        result.add(c); // 今天已生成过：直接进提醒清单（不重复生成）
        continue;
      }
      String followUp;
      if (profile != null && _api != null) {
        final text = await _requestText(profile, model ?? profile.defaultModel, [
          {'role': 'system', 'content': _followUpPrompt},
          {
            'role': 'user',
            'content': [
              if (sessionTopic != null && sessionTopic.isNotEmpty)
                '会话主题：$sessionTopic',
              '承诺内容：${c.content}',
              '到期日：${c.dueDate ?? today}',
            ].join('\n'),
          },
        ]);
        followUp = (text != null && text.isNotEmpty)
            ? text
            : localFollowUp(c);
      } else {
        followUp = localFollowUp(c);
      }
      if (followUp.length > maxContentLength * 2) {
        followUp = followUp.substring(0, maxContentLength * 2);
      }
      final updated = c.copyWith(
        followUp: followUp,
        followUpDate: today,
        updatedAt: at.millisecondsSinceEpoch,
      );
      await _db.updateCommitment(updated);
      result.add(updated);
    }
    return result;
  }

  /// 发起一次请求并收集完整输出；失败返回 null（后台任务静默）
  Future<String?> _requestJson(
    ProviderProfile profile,
    String model,
    List<Map<String, Object?>> messages,
  ) =>
      _requestText(profile, model, messages);

  Future<String?> _requestText(
    ProviderProfile profile,
    String model,
    List<Map<String, Object?>> messages,
  ) async {
    final api = _api;
    if (api == null) return null; // 无 api：调用方走本地模板兜底
    final buffer = StringBuffer();
    try {
      await for (final event in api.chatStream(
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
    // 跟进语容错：剥掉模型爱加的引号包裹
    if (text.length >= 2 &&
        ((text.startsWith('「') && text.endsWith('」')) ||
            (text.startsWith('"') && text.endsWith('"')))) {
      return text.substring(1, text.length - 1).trim();
    }
    return text.isEmpty ? null : text;
  }
}
