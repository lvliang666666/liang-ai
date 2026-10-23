import 'package:flutter/gestures.dart';

/// 横向拖拽方向：手指向右（正位移）或向左（负位移）
enum DragDirection { rightward, leftward }

/// 方向锁定的水平拖拽识别器
///
/// 默认 [HorizontalDragGestureRecognizer] 不分方向：横向一动就认领
/// 手势竞技场（赢了之后反方向只是不动），会把同区域其他水平手势
/// （如右滑开抽屉）整个吃掉。
///
/// 本识别器覆写 [hasSufficientGlobalDistanceToAccept]：只有当累计
/// 位移方向与 [direction] 一致时才允许认领；反方向位移返回 false，
/// 识别器保持"可能"态不认领——竞技场把胜利让给其他竞争者（抽屉），
/// 实现同一块气泡上"右滑开抽屉 + 左滑复制"共存。
///
/// 注意：认领后（拖拽已开始）方向不再翻转——一次手势只属于一个
/// 识别器，这是竞技场语义，无需额外处理。
class DirectionalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  DirectionalDragGestureRecognizer({
    required this.direction,
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
  });

  /// 允许认领的拖拽方向
  final DragDirection direction;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    final moved = globalDistanceMoved;
    // 反方向：永不认领（保持 possible 态，让位给其他识别器）
    if (direction == DragDirection.rightward ? moved < 0 : moved > 0) {
      return false;
    }
    // 同方向：按原 HorizontalDragGestureRecognizer 逻辑判定
    return moved.abs() >
        computeHitSlop(pointerDeviceKind, gestureSettings);
  }
}
