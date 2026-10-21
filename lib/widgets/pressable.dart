import 'package:flutter/material.dart';

/// 按压缩放反馈包装：按下缩到 [pressedScale]，松开回弹
///
/// 用于会话卡片等列表项——InkWell 只有涟漪没有形变，
/// 包一层后按压有物理质感（豆包/DeepSeek 式）。
/// [child] 需自带点击行为（InkWell/GestureDetector），本组件只管形变。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.pressedScale = 0.98,
  });

  final Widget child;

  /// 按下时的缩放（默认 0.98，轻微收缩）
  final double pressedScale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 180),
    value: 1.0,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: widget.pressedScale,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _press(bool down) {
    down ? _controller.reverse() : _controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.scale(
        scale: _scale.value,
        child: child,
      ),
      child: Listener(
        onPointerDown: (_) => _press(true),
        onPointerUp: (_) => _press(false),
        onPointerCancel: (_) => _press(false),
        child: widget.child,
      ),
    );
  }
}
