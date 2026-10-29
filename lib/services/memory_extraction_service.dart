import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/chat_message.dart';
import '../models/memory.dart';
import '../models/provider_profile.dart';
import 'api_service.dart';
import 'memory_service.dart';
import 'sse_parser.dart';

/// M2 自动记忆沉淀：会话结束后台提取记忆并静默入库
///
/// 流程：取会话消息 → 强约束 JSON 提取 prompt（low 档低温）→ 收集流式
/// 输出 → 解析候选（剥 markdown 围栏 + 容错截取）→ 解析失败回喂重试
/// 一次（roadmap 暗坑对策）→ 逐条交 [MemoryService.save] 入库——
/// 归一化去重/包含合并/否定守卫全部复用既有管线，重复提取无副作用。
///
/// 静默语义：网络失败/解析失败/无可提取内容一律安静返回 0，不抛异常
/// 不弹提示——后台任务不打扰用户。
class MemoryExtractionService {
  MemoryExtractionService({
    required ApiService api,
    required MemoryService memory,
  })  : _api = api,
        _memory = memory;

  final ApiService _api;
  final MemoryService _memory;

  /// 提取请求推理档位（轻任务走 low，快且省 token）
  static const effort = 'low';

  /// 提取请求温度（低温保证 JSON 输出稳定）
  static const temperature = 0.2;

  /// 参与提取的最大消息条数（超长会话取最近段，防请求膨胀）
  static const maxMessages = 40;

  /// 单条记忆长度上限（超出截断；prompt 已约束一句话事实）
  static const maxMemoryLength = 200;

  /// 强约束提取 system prompt：只输出 JSON
  ///
  /// M3 冲突消解：prompt 附带现有记忆样本（最多 10 条），要求模型在
  /// 新信息与旧记忆矛盾时输出 replaces（旧记忆原文）——旧条归档不删除。
  static const _systemPrompt = '''
你是记忆提取器。分析对话记录，提取值得长期记住的用户信息。

【提取】用户的偏好、重要事实、长期背景、习惯（如喜欢的回答风格、所在城市、职业、技术栈、称呼）。
【不提取】闲聊寒暄、一次性任务、助手的回答内容、没有明确依据的推测。
【格式】每条记忆是一句话事实（50 字以内），以「用户」开头（如「用户喜欢简洁回答」）。
【分层】layer 字段给每条记忆分类：profile=稳定身份（城市/职业/技术栈）、preference=偏好（喜欢的风格/习惯）、event=带时间性的事件（最近在做什么）。不确定用 event。
【冲突】若新信息与「现有记忆」矛盾（如搬家了/换工作了），在新条目加 replaces 字段，值为被取代的旧记忆原文（一字不差）。没有矛盾就不加该字段。
【输出】只输出 JSON，禁止输出任何其他文字：
{"memories": [{"content": "一句话事实", "tag": "偏好", "layer": "preference", "replaces": "被取代的旧记忆原文"}]}
tag 只能取：偏好/背景/习惯/其他，可省略；layer 只能取 profile/preference/event，可省略；replaces 可省略。没有值得记住的信息时输出 {"memories": []}''';

  /// 解析失败后的回喂重试指令（只重试一次，防死循环）
  static const _retryPrompt = '''
上面的输出不是合法 JSON。重新输出：只输出 JSON（格式：
{"memories": [{"content": "一句话事实", "tag": "偏好", "layer": "preference", "replaces": "被取代的旧记忆原文"}]}），
没有可提取的信息输出 {"memories": []}，禁止输出任何其他文字。''';

  /// 会话是否值得提取：至少一条非空 user 消息 + 一条非空 assistant 回复
  ///
  /// 工具结果消息（role='tool'）与空内容不参与判断。
  static bool shouldExtract(List<ChatMessage> messages) {
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

  /// 会话文本（提取请求的 user 消息）：角色前缀逐行拼接
  ///
  /// 跳过工具结果与空内容；超长会话只取最近 [maxMessages] 条；
  /// 会话标题作首行上下文（提取器据此理解话题背景）。
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

  /// 解析模型输出为记忆候选
  ///
  /// 返回 null = 无法解析（触发回喂重试）；空列表 = 合法输出但无可提取。
  /// 容错：剥 markdown 围栏、截取首个 `{` 到最后一个 `}`（模型爱在
  /// JSON 外加说明文字）。
  static List<MemoryCandidate>? parseCandidates(String raw) {
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
    final list = decoded['memories'];
    if (list is! List) return null;
    return [
      for (final item in list)
        if (item is Map<String, dynamic> &&
            item['content'] is String &&
            (item['content'] as String).trim().isNotEmpty)
          MemoryCandidate(
            content: (item['content'] as String).trim(),
            tag: item['tag'] is String && (item['tag'] as String).trim().isNotEmpty
                ? (item['tag'] as String).trim()
                : null,
            layer: item['layer'] is String &&
                    Memory.validLayers.contains(item['layer'] as String)
                ? item['layer'] as String
                : null,
            replaces: item['replaces'] is String &&
                    (item['replaces'] as String).trim().isNotEmpty
                ? (item['replaces'] as String).trim()
                : null,
          ),
    ];
  }

  /// 提取并入库，返回处理条数（含去重合并的更新；任何失败返回 0）
  ///
  /// 提取请求走会话同款供应商与模型（low 档低温）；解析失败回喂重试
  /// 一次；入库走 [MemoryService.save]（去重/合并/容量压缩内置）。
  /// M3：prompt 附带现有记忆样本供冲突消解；候选带 replaces 时旧条归档。
  Future<int> extractAndSave({
    required List<ChatMessage> messages,
    required ProviderProfile profile,
    required String model,
    String? sourceAgent,
    String? sessionTitle,
  }) async {
    if (!shouldExtract(messages)) return 0;
    final conversation =
        buildConversationText(messages, sessionTitle: sessionTitle);
    final existingSample = await _existingMemoriesSample();

    final systemWithSample = existingSample.isEmpty
        ? _systemPrompt
        : '$_systemPrompt\n\n【现有记忆】（供冲突判断；replaces 值必须取自这里）\n$existingSample';

    final first = await _requestJson(profile, model, [
      {'role': 'system', 'content': systemWithSample},
      {'role': 'user', 'content': conversation},
    ]);
    if (first == null) return 0; // 网络失败：静默放弃
    var candidates = parseCandidates(first);
    if (candidates == null) {
      // 解析失败：回喂重试一次（把坏输出喂回去要求纠正）
      final second = await _requestJson(profile, model, [
        {'role': 'system', 'content': systemWithSample},
        {'role': 'user', 'content': conversation},
        {'role': 'assistant', 'content': first},
        {'role': 'user', 'content': _retryPrompt},
      ]);
      if (second == null) return 0;
      candidates = parseCandidates(second);
      if (candidates == null) return 0;
    }

    var saved = 0;
    for (final c in candidates) {
      var content = c.content;
      if (content.length > maxMemoryLength) {
        content = content.substring(0, maxMemoryLength);
      }
      // 冲突消解：replaces 原文 → 归一化匹配现有记忆 id（找不到静默跳过）
      final replacesId = c.replaces == null
          ? null
          : await _resolveReplacesId(c.replaces!);
      await _memory.save(
        content,
        tag: c.tag,
        sourceAgent: sourceAgent,
        layer: c.layer,
        replaces: replacesId,
      );
      saved++;
    }
    return saved;
  }

  /// 现有记忆样本（注入 prompt 供冲突判断）：活跃记忆前 10 条原文
  Future<String> _existingMemoriesSample() async {
    final all = await _memory.getAll();
    final active = all.where((m) => !m.isArchived).take(10).toList();
    if (active.isEmpty) return '';
    return [
      for (final m in active) '- ${m.content}',
    ].join('\n');
  }

  /// replaces 原文 → 现有记忆 id（归一化精确匹配；找不到返回 null 静默跳过）
  Future<String?> _resolveReplacesId(String original) async {
    final norm = MemoryService.normalize(original);
    if (norm.isEmpty) return null;
    final all = await _memory.getAll();
    for (final m in all) {
      if (m.isArchived) continue;
      if (MemoryService.normalize(m.content) == norm) return m.id;
    }
    return null;
  }

  /// 发起一次提取请求并收集完整输出；失败（网络/服务端错误）返回 null
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

/// 提取出的单条记忆候选
class MemoryCandidate {
  const MemoryCandidate({
    required this.content,
    this.tag,
    this.layer,
    this.replaces,
  });

  final String content;
  final String? tag;

  /// M3 分层（profile/preference/event；null = MemoryService 自动分类）
  final String? layer;

  /// M3 冲突消解：被本条取代的旧记忆原文（null = 无冲突）
  final String? replaces;
}
