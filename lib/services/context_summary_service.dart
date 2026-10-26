import 'package:dio/dio.dart';

import '../models/chat_message.dart';
import '../models/context_summary.dart';
import '../models/provider_profile.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'sse_parser.dart';

/// F2 分层上下文压缩：水位判断 + 按轮分组 + 摘要生成 + 落库
///
/// 会话 token 超水位线后，把早期历史压缩成四段式「前情摘要」（关键事实/
/// 用户偏好/已做结论/未决事项，low 档低温生成），只保留最近 N 轮原文。
///
/// **压缩单元按「轮」不按「条」**（roadmap 暗坑）：assistant 的 tool_calls
/// 与 tool 结果消息必须成对保留或成对压缩，拆散会被 API 拒绝。轮的划分：
/// user 消息开新轮，其后连续的 assistant/tool 消息归属同轮。
///
/// 钉住消息永不压缩：轮内任一消息被钉住则整轮豁免（谓词由调用方注入，
/// F2.1 阶段默认无钉住）。
class ContextSummaryService {
  ContextSummaryService({required ApiService api, required DatabaseService database})
      : _api = api,
        _db = database;

  final ApiService _api;
  final DatabaseService _db;

  /// 摘要请求推理档位（轻任务走 low，快且省 token）
  static const effort = 'low';

  /// 摘要请求温度（低温保证结构化输出稳定）
  static const temperature = 0.2;

  /// 水位线：最近一轮 prompt token 达到名义上限的 75% 触发压缩
  ///
  /// 名义上限 32k（与 Token 水位仪表盘同源）；75% 留出本轮回复与
  /// 工具轮膨胀的余量。
  static const watermarkTokens = 24000;

  /// 名义上下文上限（水位线分母；与 token_usage_sheet 的名义值同源）
  static const nominalContextLimit = 32000;

  /// 压缩后保留的最近轮数（原文窗口）
  static const keepRounds = 6;

  /// 至少积累这么多可压缩轮才值得发起一次摘要请求（防频繁触发）
  static const minCompressibleRounds = 4;

  /// 四段式摘要 system prompt
  static const _systemPrompt = '''
你是会话摘要器。把早期对话历史压缩成「前情摘要」，供后续对话作为上下文使用。

【输出格式】固定四段，每段以标题行开头，无内容写「无」：
【关键事实】对话中确立的重要事实（数据、名称、约定、背景）
【用户偏好】用户表达过的偏好与要求（风格、格式、禁忌）
【已做结论】已经完成的讨论与得出的结论
【未决事项】提到但尚未解决的问题

【要求】只输出摘要本身，禁止输出任何其他文字；忠实原文，不推测不补充。''';

  /// 水位判断：是否应该压缩
  ///
  /// 条件：最近一轮 prompt token ≥ 水位线，且压缩计划可行（保留窗口之外
  /// 还有 ≥ [minCompressibleRounds] 个非钉住轮）。lastPromptTokens 为
  /// null（无记录）不触发。
  static bool shouldCompress(
    List<ChatMessage> messages, {
    int? lastPromptTokens,
    bool Function(ChatMessage message)? isPinned,
  }) {
    if (lastPromptTokens == null || lastPromptTokens < watermarkTokens) {
      return false;
    }
    return planRounds(messages, isPinned: isPinned) != null;
  }

  /// 按轮分组：user 消息开新轮，其后 assistant/tool 归属同轮
  ///
  /// 压缩单元按轮保证 tool_calls 与 tool 结果成对——拆散会被 API 拒绝。
  /// 开头无 user 的 assistant/tool 消息（异常数据）归入第 0 轮。
  static List<MessageRound> splitRounds(
    List<ChatMessage> messages, {
    bool Function(ChatMessage message)? isPinned,
  }) {
    final rounds = <MessageRound>[];
    for (final m in messages) {
      if (rounds.isEmpty || m.isUser) {
        rounds.add(MessageRound(messages: [m]));
      } else {
        rounds.last.messages.add(m);
      }
    }
    if (isPinned != null) {
      for (final r in rounds) {
        r.pinned = r.messages.any(isPinned);
      }
    }
    return rounds;
  }

  /// 计算压缩计划：返回 [待压缩轮次, 保留窗口轮次, 钉住轮次]
  ///
  /// 钉住轮不占保留名额、永不压缩（即使位于早期也保留在原文区）：
  /// 从轮序列中剔除钉住轮后，对剩余轮切出最近 [keepRounds] 轮为保留窗、
  /// 其余为压缩区。**边界锚定保留窗口首条**（钉住轮单独记录，不作为
  /// 边界——否则钉住轮会把整个压缩区拖回原文区）。压缩区不足
  /// [minCompressibleRounds] 轮时返回 null（不值得压缩）。
  static (List<MessageRound>, List<MessageRound>, List<MessageRound>)?
      planRounds(
    List<ChatMessage> messages, {
    bool Function(ChatMessage message)? isPinned,
  }) {
    final rounds = splitRounds(messages, isPinned: isPinned);
    final pinned = rounds.where((r) => r.pinned).toList();
    final normal = rounds.where((r) => !r.pinned).toList();
    if (normal.length <= keepRounds) return null;
    final compress = normal.sublist(0, normal.length - keepRounds);
    if (compress.length < minCompressibleRounds) return null;
    final kept = normal.sublist(normal.length - keepRounds);
    return (compress, kept, pinned);
  }

  /// 待压缩轮次的对话文本（摘要请求的 user 消息）
  static String buildConversationText(List<MessageRound> rounds) {
    final lines = <String>[];
    for (final r in rounds) {
      for (final m in r.messages) {
        if (m.content.trim().isEmpty) continue;
        final role = m.isUser
            ? '用户'
            : m.isToolResult
                ? '工具结果'
                : '助手';
        lines.add('$role：${m.content.trim()}');
      }
    }
    return lines.join('\n');
  }

  /// 执行压缩：生成摘要 → 落库（每会话仅保留最新一条）
  ///
  /// [existing] 非空时为滚动压缩：对全量消息重新规划（旧保留区中滑出
  /// 窗口的轮次自然进入新压缩区），旧摘要文本作为上下文一并喂给模型
  /// 合并成新摘要。任何失败（网络/解析/无可压缩内容）返回 null，静默
  /// 不抛——压缩失败不影响正常聊天，下轮再试。
  Future<ContextSummary?> compressIfNeeded({
    required List<ChatMessage> messages,
    required ProviderProfile profile,
    required String model,
    required String sessionId,
    ContextSummary? existing,
    bool Function(ChatMessage message)? isPinned,
  }) async {
    final plan = planRounds(messages, isPinned: isPinned);
    if (plan == null) return null;
    final (compress, kept, pinned) = plan;
    if (kept.isEmpty) return null;

    // 滚动压缩：只把「旧边界之后」的对话作为新增素材（旧边界之前的
    // 已在旧摘要里，避免重复喂给模型浪费 token）
    final newRounds = existing == null
        ? compress
        : [
            for (final r in compress)
              if (r.messages.first.id == existing.firstKeptId ||
                  _isAfter(r.messages.first, existing)) r,
          ];
    final conversation = buildConversationText(newRounds);
    if (conversation.isEmpty) return null;

    final prompt = existing == null
        ? conversation
        : '【上一版摘要】\n${existing.summary}\n\n【新增对话】\n$conversation\n\n'
            '请把上一版摘要与新增对话合并成一份新的前情摘要。';

    final text = await _requestSummary(profile, model, prompt);
    if (text == null || text.trim().isEmpty) return null;

    final firstKept = kept.first.messages.first;
    final summary = ContextSummary(
      id: 'ctx-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      sessionId: sessionId,
      summary: text.trim(),
      firstKeptId: firstKept.id,
      firstKeptAt: firstKept.createdAt,
      // 钉住轮消息 ID 清单：请求组装时按此捞回边界之前的原文
      pinnedIds: [for (final r in pinned) for (final m in r.messages) m.id],
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.saveContextSummary(summary);
    return summary;
  }

  /// 消息是否在旧摘要边界之后（created_at ≥ 边界时间）
  static bool _isAfter(ChatMessage m, ContextSummary existing) =>
      m.createdAt >= existing.firstKeptAt;

  /// 发起一次摘要请求并收集完整输出；失败返回 null
  Future<String?> _requestSummary(
    ProviderProfile profile,
    String model,
    String conversation,
  ) async {
    final buffer = StringBuffer();
    try {
      await for (final event in _api.chatStream(
        profile: profile,
        messages: [
          const {'role': 'system', 'content': _systemPrompt},
          {'role': 'user', 'content': conversation},
        ],
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

/// 一轮对话：user 消息 + 其后连续的 assistant/tool 消息
///
/// 压缩的最小单元——轮内消息要么全部保留原文，要么全部进摘要。
class MessageRound {
  MessageRound({required this.messages, this.pinned = false});

  final List<ChatMessage> messages;

  /// 轮内任一消息被钉住 = 整轮豁免压缩
  bool pinned;
}
