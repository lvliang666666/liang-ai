import 'package:flutter/services.dart';

/// 全局触感反馈规范
///
/// 所有可交互元素（按钮、卡片、菜单、开关、滑块等）被点击/触发时，
/// 统一给出轻微震动，增强操作确认感。
///
/// 使用方式：在 onTap / onLongPress / onSelected 等回调第一行调用
/// ```dart
/// onTap: () { Haptics.light(); ... }
/// onLongPress: () { Haptics.medium(); ... }
/// ```
abstract final class Haptics {
  /// 轻微震动：普通点击（按钮、列表项、卡片、开关）
  static void light() =>
      HapticFeedback.lightImpact();

  /// 中等震动：长按操作（长按卡片弹菜单、长按复制）
  static void medium() =>
      HapticFeedback.mediumImpact();

  /// 选择切换震动：档位/主题等选择类操作（更轻，类似系统滚轮）
  static void selection() =>
      HapticFeedback.selectionClick();
}
