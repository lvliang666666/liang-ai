import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_session.dart';
import '../services/morning_briefing_service.dart';

/// P2 桌面小组件数据：推送给原生 HomeWidgetProvider 的载荷
///
/// JSON 结构（与 HomeWidgetProvider.kt 解析约定一致）：
/// `{"briefing": "当天简报一行", "sessions": [{"id": "...", "title": "..."}]}`
class WidgetData {
  const WidgetData({this.briefing, required this.sessions});

  /// 当天简报一行（null/空 = widget 不显示简报行）
  final String? briefing;

  /// 最近会话（最多 3 条，原生侧也截断）
  final List<ChatSession> sessions;

  Map<String, dynamic> toJson() => {
        if (briefing != null && briefing!.isNotEmpty) 'briefing': briefing,
        'sessions': [
          for (final s in sessions.take(3))
            {'id': s.id, 'title': s.title},
        ],
      };

  String encode() => jsonEncode(toJson());
}

/// P2 桌面小组件数据桥（Flutter → 原生）
///
/// 数据流（零新插件，复用 F9 的 MethodChannel `ai_chat_app/share`）：
/// - 推送：[push] 把 JSON 写进原生 SharedPreferences（flutter. 前缀键，
///   进程死亡后 HomeWidgetProvider.onUpdate 仍可读）并触发 widget 重渲染
/// - 冷启动兜底：[fetchCurrent] 读回当前持久化 JSON（调试/恢复用）
///
/// 简报行数据源：P1 晨间简报的持久化缓存（SettingsService.lastBriefingDate
/// 同天的 greeting 段）；无缓存或跨天 = 不显示简报行。
/// 会话行数据源：SessionsProvider 的最近会话（置顶在前 + 更新时间倒序）。
class WidgetDataService {
  WidgetDataService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('ai_chat_app/share');

  final MethodChannel _channel;
  bool _available = true;

  /// 组装当前应推送的 widget 数据
  ///
  /// [sessions] 会话列表（已按置顶+更新时间排序）；[prefs] 读简报缓存。
  static WidgetData buildData({
    required List<ChatSession> sessions,
    required SharedPreferences prefs,
  }) {
    // 简报行：当天简报的 greeting 段（P1 生成后经 widgetBriefing* 键缓存）
    final today = _dateKey(DateTime.now());
    String? briefing;
    if (prefs.getString('widgetBriefingDate') == today) {
      final text = prefs.getString('widgetBriefingText');
      if (text != null && text.isNotEmpty) briefing = text;
    }
    // 会话行：过滤「新对话」默认标题（无信息量，占位不如多留位置给有标题的）
    final named = sessions.where((s) => s.title.trim().isNotEmpty).toList();
    return WidgetData(briefing: briefing, sessions: named);
  }

  static String _dateKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// 推送数据到原生并触发 widget 重渲染。
  /// 平台不可用（测试/旧 APK 混装）静默降级——widget 是增强不是门槛。
  Future<void> push(WidgetData data) async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<bool>(
          'updateWidgetData', {'json': data.encode()});
    } on PlatformException {
      _available = false;
    } on MissingPluginException {
      _available = false;
    }
  }

  /// 读回当前持久化的 widget JSON（冷启动兜底/调试用）
  Future<String?> fetchCurrent() async {
    try {
      return await _channel.invokeMethod<String>('getWidgetData');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// P2 简报行缓存助手：晨间简报生成完成后调用，把 greeting 段
/// 写进 widget 可读的键（与 WidgetDataService.buildData 约定一致）
Future<void> cacheBriefingForWidget(
  SharedPreferences prefs,
  MorningBriefing briefing,
) async {
  await prefs.setString('widgetBriefingDate', briefing.dateKey);
  await prefs.setString('widgetBriefingText', briefing.greeting);
}

/// P2 会话监听器：SessionsProvider 变化 → 防抖推送 widget 数据
///
/// 防抖 500ms：连续操作（重命名/置顶/删除/新建）只推最后一次，
/// 避免高频 notifyListeners 打爆 MethodChannel。
class WidgetDataPusher {
  WidgetDataPusher({
    required this.service,
    required this.prefs,
    this.debounce = const Duration(milliseconds: 500),
  });

  final WidgetDataService service;
  final SharedPreferences prefs;
  final Duration debounce;

  Timer? _timer;
  List<ChatSession> _latest = const [];

  /// 会话列表变化入口（SessionsProvider listener 调用）
  void onSessionsChanged(List<ChatSession> sessions) {
    _latest = sessions;
    _timer?.cancel();
    _timer = Timer(debounce, _push);
  }

  Future<void> _push() async {
    final data = WidgetDataService.buildData(sessions: _latest, prefs: prefs);
    await service.push(data);
  }

  /// 立即推送（App 启动时首推一次，不等防抖）
  Future<void> pushNow() async {
    _timer?.cancel();
    await _push();
  }

  @visibleForTesting
  void debugFlushTimer() => _timer?.cancel();

  void dispose() {
    _timer?.cancel();
  }
}
