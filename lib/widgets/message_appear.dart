import 'package:flutter/material.dart';

/// 消息入场动画包装：首次出现时淡入 + 轻微上滑
///
/// 只在组件首次进入元素树时播放一次（新消息出现/会话切换后首帧），
/// 流式重建（同一条消息每帧 setState）不重播——State 随元素树保留。
/// 历史消息批量加载时同样会播，但整屏统一淡入观感自然，不区分处理。
///
/// [enabled] = false 时直接透传 child（不建动画控制器）：会话切换
/// 批量加载历史消息时关闭入场动画——每条消息一个控制器 + 整列表
/// 逐帧重绘是切换掉帧元凶之一；新消息（单条）仍播动画。
class MessageAppear extends StatefulWidget {
  const MessageAppear({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<MessageAppear> createState() => _MessageAppearState();
}

class _MessageAppearState extends State<MessageAppear>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  /// 淡入 + 上滑（8px）复合曲线：先快后慢收尾
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.04),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _controller.forward();
  }

  @override
  void didUpdateWidget(MessageAppear oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 关闭态挂载后又被打开（罕见）：补播动画
    if (widget.enabled && !oldWidget.enabled && !_controller.isCompleted) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: widget.child,
      ),
    );
  }
}
