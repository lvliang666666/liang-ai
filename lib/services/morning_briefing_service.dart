import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/provider_profile.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'sse_parser.dart';
import 'tools/mystic/divination_tools.dart';

/// P1 晨间简报：每天首次打开 App 生成个性化「今日简报」
///
/// 「打开补算式」规避 Android 后台限制——不做定时任务，跨天后首次
/// 打开 App 时补算当天简报（是否跨天由调用方查 SettingsService
/// lastBriefingDate 判断，本服务只负责生成）。
///
/// 数据源（全部本地，零权限零凭据）：
/// - 黄历宜忌：[HuangLiTool]（建除十二神推算，确定性）
/// - 观音灵签：[GuanYinTool]（每日一签，随机）
/// - 用户记忆：活跃记忆（非归档、事件层未衰减）
/// - 上周今天：updated_at 落在 7 天前 ±1 天窗口的会话 + 其摘要
///
/// 生成走 LLM（low 档低温强约束 JSON）；网络/解析失败回退**本地
/// 拼装**（黄历+灵签原文 + 记忆列表 + 上周会话标题）——离线也有
/// 简报可看，只是没有「个性化点评」段。
class MorningBriefingService {
  MorningBriefingService({
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

  /// 「上周今天」窗口：7 天前 ±1 天内的会话参与生成
  static const lastWeekWindowDays = 1;

  /// 参与生成的会话数上限（防请求膨胀）
  static const maxLastWeekSessions = 5;

  /// 单会话参与生成的消息条数上限
  static const maxMessagesPerSession = 10;

  /// 参与生成的记忆条数上限
  static const maxMemories = 10;

  /// 简报各段长度上限（超出截断；prompt 已约束）
  static const maxSectionLength = 300;

  /// 强约束生成 system prompt：只输出 JSON
  static const _systemPrompt = '''
你是晨间简报编辑。根据用户提供的素材，生成一份简短温暖的今日简报。

【素材】黄历宜忌、今日灵签、用户长期记忆、上周今天的会话记录。
【输出】只输出 JSON，禁止输出任何其他文字：
{"greeting": "一句问候（20字以内，可结合星期/时段/记忆）", "almanac": "黄历宜忌一句话点评（40字以内）", "fortune": "灵签一句话解读（40字以内，注明仅供娱乐）", "memory": "结合记忆的一句贴心提醒（50字以内，没有相关记忆则空串）", "flashback": "上周今天聊了什么的回顾（60字以内，没有则空串）"}
语气自然口语化，像朋友发来的早安消息；不堆砌素材原文，做提炼。''';

  /// 解析失败后的回喂重试指令（只重试一次，防死循环）
  static const _retryPrompt = '''
上面的输出不是合法 JSON。重新输出：只输出 JSON（格式：
{"greeting": "问候", "almanac": "黄历点评", "fortune": "灵签解读", "memory": "记忆提醒", "flashback": "上周回顾"}），
禁止输出任何其他文字。''';

  /// 生成今日简报（LLM 优先，失败本地回退）
  ///
  /// [now] 可注入时钟（测试用）；[skipFortune] 跳过灵签（部分用户
  /// 不喜欢玄学内容时由设置层控制）。
  Future<MorningBriefing> generate({
    required ProviderProfile profile,
    required String model,
    DateTime? now,
    bool skipFortune = false,
  }) async {
    final today = now ?? DateTime.now();
    final dateKey = _dateKey(today);

    // 并行收集素材：黄历（确定性）+ 灵签（随机）+ 记忆 + 上周今天
    final huangli = await _safeTool(
        () => const HuangLiTool().execute({'date': dateKey}));
    final fortune = skipFortune
        ? null
        : await _safeTool(() => const GuanYinTool().execute({}));
    final memories = await _activeMemoriesText(today);
    final lastWeek = await _lastWeekText(today);

    final material = _buildMaterial(
      dateKey: dateKey,
      weekday: _weekdayLabel(today),
      huangli: huangli,
      fortune: fortune,
      memories: memories,
      lastWeek: lastWeek,
    );

    // LLM 生成：解析失败回喂重试一次
    final first = await _requestJson(profile, model, [
      {'role': 'system', 'content': _systemPrompt},
      {'role': 'user', 'content': material},
    ]);
    BriefingDraft? draft;
    if (first != null) {
      draft = parseDraft(first);
      if (draft == null) {
        final second = await _requestJson(profile, model, [
          {'role': 'system', 'content': _systemPrompt},
          {'role': 'user', 'content': material},
          {'role': 'assistant', 'content': first},
          {'role': 'user', 'content': _retryPrompt},
        ]);
        draft = second == null ? null : parseDraft(second);
      }
    }

    if (draft != null) {
      return MorningBriefing(
        dateKey: dateKey,
        greeting: _clip(draft.greeting, 60) ?? '你好，新的一天',
        almanac: _clip(draft.almanac, maxSectionLength) ?? '',
        fortune: _clip(draft.fortune, maxSectionLength) ?? '',
        memory: _clip(draft.memory, maxSectionLength) ?? '',
        flashback: _clip(draft.flashback, maxSectionLength) ?? '',
        huangliRaw: huangli ?? '',
        fortuneRaw: fortune ?? '',
        fromLlm: true,
      );
    }

    // 本地回退：素材原文直接拼装（离线/解析失败也有简报可看）
    return _localFallback(
      dateKey: dateKey,
      weekday: _weekdayLabel(today),
      huangli: huangli,
      fortune: fortune,
      memories: memories,
      lastWeek: lastWeek,
    );
  }

  // ===== 素材收集 =====

  /// 工具执行兜底：玄学工具理论上不抛（除非法日期），仍兜一层
  static Future<String?> _safeTool(Future<String> Function() run) async {
    try {
      final text = await run();
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// 活跃记忆文本（非归档；事件层按 30 天衰减过滤）
  Future<String> _activeMemoriesText(DateTime now) async {
    final all = await _db.getAllMemories();
    final nowMs = now.millisecondsSinceEpoch;
    final active = all
        .where((m) => !m.isArchived && !m.isDecayed(nowMs))
        .take(10)
        .toList();
    if (active.isEmpty) return '';
    return active.map((m) => '- ${m.content}').join('\n');
  }

  /// 「上周今天」文本：7 天前 ±1 天窗口内更新的会话，取标题 + 最近消息
  Future<String> _lastWeekText(DateTime now) async {
    final sessions = await _db.getAllSessions();
    final anchor = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 7));
    final picked = <_LastWeekSession>[];
    for (final s in sessions) {
      final updated = DateTime.fromMillisecondsSinceEpoch(s.updatedAt);
      // 按自然日比较：Duration.inDays 向零截断（-38h → -1 天），
      // 带时刻的差值会把窗外会话误判进窗口
      final updatedDay = DateTime(updated.year, updated.month, updated.day);
      final diff = updatedDay.difference(anchor).inDays;
      if (diff.abs() > lastWeekWindowDays) continue;
      final messages = await _db.getMessages(s.id);
      final lines = <String>[];
      for (final m in messages.reversed) {
        if (m.isToolResult || m.content.trim().isEmpty) continue;
        lines.insert(0, '${m.isUser ? '用户' : '助手'}：${m.content.trim()}');
        if (lines.length >= maxMessagesPerSession) break;
      }
      picked.add(_LastWeekSession(
        title: s.title,
        updated: updated,
        preview: lines.join('\n'),
      ));
      if (picked.length >= maxLastWeekSessions) break;
    }
    if (picked.isEmpty) return '';
    return [
      for (final s in picked)
        '会话「${s.title}」（${_dateKey(s.updated)}）：'
            '${s.preview.isEmpty ? '（无文字消息）' : s.preview}',
    ].join('\n');
  }

  /// 组装生成请求的素材文本
  static String _buildMaterial({
    required String dateKey,
    required String weekday,
    required String? huangli,
    required String? fortune,
    required String memories,
    required String lastWeek,
  }) {
    return [
      '今天是 $dateKey（$weekday）。',
      if (huangli != null) '【黄历】\n$huangli',
      if (fortune != null) '【今日灵签】\n$fortune',
      if (memories.isNotEmpty) '【用户长期记忆】\n$memories',
      if (lastWeek.isNotEmpty) '【上周今天的会话】\n$lastWeek',
    ].join('\n\n');
  }

  /// 本地回退简报：素材原文拼装，无 LLM 点评段
  MorningBriefing _localFallback({
    required String dateKey,
    required String weekday,
    required String? huangli,
    required String? fortune,
    required String memories,
    required String lastWeek,
  }) {
    // 黄历原文提取宜忌两行（「宜：」「忌：」开头）
    var yiJi = '';
    if (huangli != null) {
      final lines = huangli
          .split('\n')
          .where((l) => l.startsWith('宜：') || l.startsWith('忌：'))
          .toList();
      yiJi = lines.join('；');
    }
    // 灵签原文提取签号行（「第 NN 签」）
    var fortuneLine = '';
    if (fortune != null) {
      final m = RegExp(r'第 \d+ 签 · \S+').firstMatch(fortune);
      if (m != null) fortuneLine = m.group(0)!;
    }
    // 上周会话标题列表
    final titles = <String>[
      for (final l in lastWeek.split('\n'))
        if (l.startsWith('会话「') && l.contains('」'))
          l.substring(3, l.indexOf('」')),
    ].take(3).toList();

    return MorningBriefing(
      dateKey: dateKey,
      greeting: '早上好，新的一天',
      almanac: yiJi,
      fortune: fortuneLine,
      memory: memories.isEmpty
          ? ''
          : '记得这些：\n${memories.split('\n').take(3).join('\n')}',
      flashback: titles.isEmpty
          ? ''
          : '上周今天聊过：${titles.join('、')}',
      huangliRaw: huangli ?? '',
      fortuneRaw: fortune ?? '',
      fromLlm: false,
    );
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

  // ===== 解析 =====

  /// 解析模型输出为简报草稿（null = 无法解析）
  ///
  /// 容错：剥 markdown 围栏、截取首个 `{` 到最后一个 `}`（复用 M2 模式）。
  static BriefingDraft? parseDraft(String raw) {
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
    final map = decoded;
    String? field(String key) {
      final Object? v = map[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final greeting = field('greeting');
    final almanac = field('almanac');
    final fortune = field('fortune');
    final memory = field('memory');
    final flashback = field('flashback');
    // 至少要有问候才算有效输出（全空 = 模型没理解任务）
    if (greeting == null && almanac == null && fortune == null) return null;
    return BriefingDraft(
      greeting: greeting,
      almanac: almanac,
      fortune: fortune,
      memory: memory,
      flashback: flashback,
    );
  }

  // ===== 工具 =====

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _weekdayLabel(DateTime d) => const [
        '周一', '周二', '周三', '周四', '周五', '周六', '周日',
      ][d.weekday - 1];

  static String? _clip(String? text, int max) {
    if (text == null) return null;
    final t = text.trim();
    if (t.isEmpty) return null;
    return t.length > max ? t.substring(0, max) : t;
  }
}

/// 「上周今天」窗口内的会话（内部收集用）
class _LastWeekSession {
  const _LastWeekSession({
    required this.title,
    required this.updated,
    required this.preview,
  });

  final String title;
  final DateTime updated;
  final String preview;
}

/// 生成的简报草稿（LLM 输出解析结果；各段可空）
class BriefingDraft {
  const BriefingDraft({
    this.greeting,
    this.almanac,
    this.fortune,
    this.memory,
    this.flashback,
  });

  final String? greeting;
  final String? almanac;
  final String? fortune;
  final String? memory;
  final String? flashback;
}

/// 晨间简报（UI 渲染数据；与生成来源解耦）
class MorningBriefing {
  const MorningBriefing({
    required this.dateKey,
    required this.greeting,
    required this.almanac,
    required this.fortune,
    required this.memory,
    required this.flashback,
    required this.huangliRaw,
    required this.fortuneRaw,
    required this.fromLlm,
  });

  /// 日期键（yyyy-MM-dd，去重与展示用）
  final String dateKey;

  /// 问候语
  final String greeting;

  /// 黄历点评（LLM）或宜忌原文（回退）
  final String almanac;

  /// 灵签解读（LLM）或签号行（回退）
  final String fortune;

  /// 记忆提醒（无相关记忆为空串）
  final String memory;

  /// 上周今天回顾（无会话为空串）
  final String flashback;

  /// 黄历工具原文（UI「查看详情」展开用）
  final String huangliRaw;

  /// 灵签工具原文（UI「查看详情」展开用）
  final String fortuneRaw;

  /// 是否 LLM 生成（false = 本地回退，UI 可标注「离线简报」）
  final bool fromLlm;
}
