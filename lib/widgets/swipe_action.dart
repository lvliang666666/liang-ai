import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../utils/haptics.dart';

/// 消息横滑快捷操作容器（Telegram/iOS Mail 式）
///
/// 手指横滑露出背景动作区，越阈（[actionThreshold]）松手即触发 [onAction]
/// 并回弹；未越阈松手回弹归位。滑动方向由 [direction] 决定：
/// - [SwipeDirection.leftToRight]：手指向右滑，动作区在气泡左侧
///   （用户消息右滑 = 复制）
/// - [SwipeDirection.rightToLeft]：手指向左滑，动作区在气泡右侧
///   （助手消息左滑 = 复制）
///
/// 拖拽跟手（DragStartBehavior.down 消除起手死区），回弹 200ms
/// easeOutCubic。动作区图标随进度淡入 + 轻微位移（克制动效风格）。
class SwipeActionContainer extends StatefulWidget {
  const SwipeActionContainer({
    super.key,
    required this.child,
    required this.icon,
    required this.label,
    required this.color,
    required this.direction,
    required this.onAction,
    this.enabled = true,
  });

  final Widget child;

  /// 动作区图标（如 Icons.copy_outlined）
  final IconData icon;

  /// 动作区文字（如「复制」）
  final String label;

  /// 动作区背景色（复制 = 主题 primary）
  final Color color;

  final SwipeDirection direction;

  /// 越阈松手触发的动作
  final VoidCallback onAction;

  /// 横滑开关（流式中的消息禁用，避免与列表滚动/长按冲突）
  final bool enabled;

  @override
  State<SwipeActionContainer> createState() => SwipeActionContainerState();
}

enum SwipeDirection { leftToRight, rightToLeft }

class SwipeActionContainerState extends State<SwipeActionContainer>
    with SingleTickerProviderStateMixin {
  /// 拖拽位移（正数 = 已滑出量，px）
  double _dragExtent = 0;

  /// 是否已越阈（松手即触发）
  bool _armed = false;

  AnimationController? _settleController;

  /// 最大滑出距离（动作区宽度）
  static const double _maxExtent = 88;

  /// 触发阈值（滑过 60% 即 armed）
  static const double _actionThreshold = _maxExtent * 0.6;

  /// 控制器懒创建（首次回弹才需要；initState 创建会在测试
  /// dispose 阶段触发 "deactivated widget's ancestor" 断言）
  AnimationController get _settle {
    if (_settleController == null) {
      _settleController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      );
    }
    return _settleController!;
  }

  @override
  void dispose() {
    _settleController?.dispose();
    super.dispose();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    final delta = widget.direction == SwipeDirection.leftToRight
        ? details.primaryDelta ?? 0
        : -(details.primaryDelta ?? 0);
    setState(() {
      _dragExtent = (_dragExtent + delta).clamp(0.0, _maxExtent);
      final armed = _dragExtent >= _actionThreshold;
      if (armed != _armed) {
        _armed = armed;
        // 越阈瞬间轻震（即将触发的确认感）
        if (armed) Haptics.light();
      }
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!widget.enabled) return;
    if (_armed) {
      widget.onAction();
    }
    _settleBack();
  }

  void _onHorizontalDragCancel() {
    _settleBack();
  }

  /// 回弹归位（200ms easeOutCubic）
  void _settleBack() {
    if (_dragExtent == 0) return;
    final controller = _settle;
    final animation = Tween<double>(begin: _dragExtent, end: 0).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOutCubic),
    );
    animation.addListener(() {
      if (!mounted) return;
      setState(() => _dragExtent = animation.value);
    });
    controller.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _armed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLTR = widget.direction == SwipeDirection.leftToRight;
    final offset = isLTR ? _dragExtent : -_dragExtent;
    final progress = (_dragExtent / _maxExtent).clamp(0.0, 1.0);

    return Stack(
      children: [
        // 动作区（底层）：随滑动进度淡入 + 图标轻微位移
        Positioned.fill(
          child: Opacity(
            opacity: progress,
            child: Container(
              alignment: isLTR ? Alignment.centerLeft : Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Transform.translate(
                offset: Offset(isLTR ? -8 * (1 - progress) : 8 * (1 - progress),
                    0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon,
                        size: 20,
                        color: _armed ? widget.color : null),
                    const SizedBox(height: 2),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: _armed ? widget.color : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 气泡层：跟随手指平移
        Transform.translate(
          offset: Offset(offset, 0),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onHorizontalDragCancel: _onHorizontalDragCancel,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
