import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../utils/haptics.dart';
import 'directional_drag_recognizer.dart';

/// 消息横滑快捷操作容器（Telegram/iOS Mail 式）
///
/// 手指横滑露出背景动作区，越阈（[actionThreshold]）松手即触发 [onAction]
/// 并回弹；未越阈松手回弹归位。滑动方向由 [direction] 决定：
/// - [SwipeDirection.leftToRight]：手指向右滑，动作区在气泡左侧
/// - [SwipeDirection.rightToLeft]：手指向左滑，动作区在气泡右侧
///
/// 方向约定（v2.5.3 方向锁定版）：**双向左滑复制**（v2.5.2 定版不变），
/// 右滑让位给"右滑出会话列表"抽屉。共存靠 [DirectionalDragGestureRecognizer]
/// 方向锁：识别器只认领与复制方向一致（向左）的横滑，反方向（右滑）
/// 弃权让手势落回抽屉——同一块气泡上"右滑开抽屉 + 左滑复制"各归其主。
///
/// 拖拽跟手（DragStartBehavior.down 消除起手死区），回弹 200ms
/// easeOutCubic。动作区图标随进度淡入 + 轻微位移（克制动效风格）。
///
/// 手势参数：识别器显式注入 [MediaQuery.maybeGestureSettingsOf] 的设备
/// touchSlop（RawGestureDetector 不像 GestureDetector 那样自动注入），
/// 保证与抽屉等系统手势同 slop 公平竞争；[enabled] 为 false 时干脆
/// 不注册识别器，横滑完全让位（选择文字模式依赖这一点）。
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
    // 设备手势参数（touchSlop）必须显式注入识别器：RawGestureDetector
    // 不像 GestureDetector 那样自动读 MediaQuery.gestureSettings，缺省
    // 会退回 kTouchSlop=18px，而抽屉的 GestureDetector 用真机设备
    // slop（约 8px）——slop 不对等时抽屉永远先认领，横滑复制在真机
    // 上失效（模拟器/测试两者同为 18px，测不出来）。注入后双方 slop
    // 一致，命中派发子先于父，气泡识别器先越 slop 认领，复制恢复。
    final gestureSettings = MediaQuery.maybeGestureSettingsOf(context);

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
        // 气泡层：跟随手指平移。RawGestureDetector 注入方向锁识别器：
        // 只认领与 [direction] 一致的横滑，反方向弃权（让位抽屉手势）。
        // 禁用态不注册识别器（而非注册后空转）：识别器在场会赢下竞技场
        // 吞掉横滑——选择文字模式下要整体让位给 SelectionArea 的拖拽选字
        Transform.translate(
          offset: Offset(offset, 0),
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: {
              if (widget.enabled)
                DirectionalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        DirectionalDragGestureRecognizer>(
                  () => DirectionalDragGestureRecognizer(
                    direction: isLTR
                        ? DragDirection.rightward
                        : DragDirection.leftward,
                    debugOwner: this,
                  ),
                  (instance) {
                    instance
                      ..dragStartBehavior = DragStartBehavior.down
                      ..gestureSettings = gestureSettings
                      ..onUpdate = _onHorizontalDragUpdate
                      ..onEnd = _onHorizontalDragEnd
                      ..onCancel = _onHorizontalDragCancel;
                  },
                ),
            },
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
