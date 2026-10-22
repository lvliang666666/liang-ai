import 'package:flutter/services.dart';

/// 全局触感反馈规范（三档词汇表）
///
/// 所有可交互元素（按钮、卡片、菜单、开关、滑块等）被点击/触发时，
/// 按操作分量给出对应档位震动，增强操作确认感。
///
/// 三档词汇表（按操作分量选档，不按控件类型）：
/// - [light]：普通点击——发送、按钮、列表项、卡片、开关
/// - [medium]：有分量的操作——长按弹菜单、复制完成、菜单弹出
/// - [heavy]：不可逆/破坏性操作确认——删除会话、删除消息、清空记忆
/// - [selection]：选择切换——档位/主题等选择类操作（更轻，类似系统滚轮）
///
/// 使用方式：在 onTap / onLongPress / onSelected 等回调第一行调用
/// ```dart
/// onTap: () { Haptics.light(); ... }
/// onLongPress: () { Haptics.medium(); ... }
/// onConfirmed: () { Haptics.heavy(); ... }  // 删除确认按钮
/// ```
abstract final class Haptics {
  /// 轻微震动：普通点击（发送、按钮、列表项、卡片、开关）
  static void light() =>
      HapticFeedback.lightImpact();

  /// 中等震动：有分量的操作（长按弹菜单、复制完成、菜单弹出）
  static void medium() =>
      HapticFeedback.mediumImpact();

  /// 重震动：不可逆/破坏性操作的确认瞬间（删除会话/消息、清空记忆）
  static void heavy() =>
      HapticFeedback.heavyImpact();

  /// 选择切换震动：档位/主题等选择类操作（更轻，类似系统滚轮）
  static void selection() =>
      HapticFeedback.selectionClick();
}
