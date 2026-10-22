import 'dart:async';

import 'package:flutter/material.dart';

/// 全局 Toast 兜底（UI 批次 1 规范）
///
/// 用途：删除成功/网络异常等**非按钮内反馈**场景的统一提示。
/// 复制操作不走这里——复制反馈在按钮内状态切换（见 code_block_widget）。
///
/// 规格（需求文档）：
/// - 位置：底部输入栏上方 8dp，水平居中，禁止覆盖输入栏
/// - 形态：深色胶囊 rgba(0,0,0,0.75)，高 36dp，内边距 10×16dp，
///   全圆角，左右边距 ≥16dp
/// - 文案：14sp 白色，单行截断
/// - 动效：淡入 200ms ease-out，停留 2000ms，淡出 150ms ease-in
/// - 行为：无遮罩、不阻断底层点击；同时仅存在一个，新替旧
///
/// 用 Overlay 而非 SnackBar：SnackBar 依赖 Scaffold、全宽深色长条、
/// 会顶起/遮挡输入栏且阻断输入——三项都不符合规格。

/// 当前在屏 Toast 的入场 key（单例新替旧：新 Toast 先移除旧的再入）
OverlayEntry? _currentToast;

/// 显示全局 Toast（2.35s 后自动消失；重复调用新替旧）
void showAppToast(BuildContext context, String message) {
  // 单例：先撤旧的（立即，无淡出——新替旧不叠加）
  _currentToast?.remove();
  _currentToast = null;

  final overlay = Overlay.of(context, rootOverlay: true);
  final entry = OverlayEntry(
    builder: (context) => const _AppToastHost(),
  );
  _currentToast = entry;
  overlay.insert(entry);
  // 首帧后触发显示（host State 已挂载，静态通知可达）
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _AppToastHostState.showMessage(message);
  });
}

class _AppToastHost extends StatefulWidget {
  const _AppToastHost();

  @override
  State<_AppToastHost> createState() => _AppToastHostState();
}

class _AppToastHostState extends State<_AppToastHost> {
  static _AppToastHostState? _instance;
  static final ValueNotifier<String> _message = ValueNotifier('');
  static final ValueNotifier<int> _generation = ValueNotifier(0);
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _instance = this;
  }

  @override
  void dispose() {
    if (_instance == this) _instance = null;
    _hideTimer?.cancel();
    super.dispose();
  }

  static void showMessage(String message) {
    _message.value = message;
    _generation.value++;
    _instance?._restartTimer();
  }

  void _restartTimer() {
    _hideTimer?.cancel();
    // 总时长 = 淡入 200ms + 停留 2000ms + 淡出 150ms 的停留段起点后 2s
    _hideTimer = Timer(const Duration(milliseconds: 2200), () {
      _message.value = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _generation,
      builder: (context, _, _) => ValueListenableBuilder<String>(
        valueListenable: _message,
        builder: (context, message, _) {
          if (message.isEmpty) {
            // 淡出完成后移除浮层（动画结束后再 remove，避免打断）
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_message.value.isEmpty && _currentToast != null) {
                _currentToast?.remove();
                _currentToast = null;
              }
            });
            return const SizedBox.shrink();
          }
          return Positioned(
            left: 16,
            right: 16,
            bottom: 0,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _ToastBubble(message: message),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Toast 胶囊本体：淡入 200ms ease-out / 淡出 150ms ease-in
class _ToastBubble extends StatefulWidget {
  const _ToastBubble({required this.message});

  final String message;

  @override
  State<_ToastBubble> createState() => _ToastBubbleState();
}

class _ToastBubbleState extends State<_ToastBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200), // 淡入
    reverseDuration: const Duration(milliseconds: 150), // 淡出
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didUpdateWidget(_ToastBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新替旧：文案变化时重新淡入（不闪烁——同一浮层原地刷新）
    if (oldWidget.message != widget.message && !_controller.isCompleted) {
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
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8 + 76), // 输入栏上方 8dp（输入栏高约 76dp）
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xBF000000), // rgba(0,0,0,0.75)
          borderRadius: BorderRadius.circular(18), // 全圆角（高 36 → 半径 18）
        ),
        child: Text(
          widget.message,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
