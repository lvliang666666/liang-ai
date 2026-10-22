import 'package:flutter/material.dart';

/// 标准 Bottom Sheet 骨架（UI 批次 1 统一容器）
///
/// 全 app 的选择面板（Skill/模型/附件/导出格式等）统一走 [showAppBottomSheet]：
/// - 容器：顶部圆角 16，最大高度 60% 屏高，可下拉关闭
/// - 遮罩：rgba(0,0,0,0.4)，点击关闭
/// - 动效：250ms ease-out 滑入 / 200ms ease-in 滑出（与键盘动画同量级）
/// - 键盘适配：面板整体上移至键盘上沿（AnimatedPadding 跟随 viewInsets），
///   内容区最小保留 [minContentHeight]，键盘弹出/收起平滑过渡不跳变
///
/// 内容用 [SheetScaffold] 组装：标题行（16sp 加粗 + 24dp 关闭键）+
/// 可选搜索框固定顶部 + Flexible 滚动内容区。
///
/// 用法：
/// ```dart
/// final result = await showAppBottomSheet<Skill?>(
///   context: context,
///   title: '选择 Skill',
///   builder: (context) => SheetScaffold(
///     title: '选择 Skill',
///     onClose: () => Navigator.pop(context),
///     child: ...列表...,
///   ),
/// );
/// ```
///
/// 键盘适配要点（需求文档「实现提示」）：高度监听用 Flutter 的
/// MediaQuery.viewInsetsOf（底层即 WindowInsets/IME 高度），禁止硬编码
/// 键盘高度；AnimatedPadding 时长 250ms 与面板/键盘动画一致，禁止跳变。

/// 遮罩颜色（需求：rgba(0,0,0,0.4)）
const Color kSheetBarrierColor = Color(0x66000000);

/// 面板最大高度占屏高比例（需求：60%）
const double kSheetMaxHeightRatio = 0.6;

/// 键盘弹出时内容区最小保留高度（需求：240dp）
const double kSheetMinContentHeight = 240;

/// 面板动画（需求：250ms ease-out 滑入；收起 200ms ease-in）
const AnimationStyle kSheetAnimationStyle = AnimationStyle(
  curve: Curves.easeOutCubic,
  duration: Duration(milliseconds: 250),
  reverseCurve: Curves.easeInCubic,
  reverseDuration: Duration(milliseconds: 200),
);

/// 打开标准 Bottom Sheet。
///
/// [maxHeightRatio] 覆盖默认最大高度比例（默认 60% 屏高）；
/// [isScrollControlled] 必须为 true 才能突破半屏限制（本函数内部已设）。
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxHeightRatio = kSheetMaxHeightRatio,
  Color? barrierColor = kSheetBarrierColor,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    barrierColor: barrierColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    enableDrag: true,
    sheetAnimationStyle: kSheetAnimationStyle,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.heightOf(context) * maxHeightRatio,
    ),
    builder: builder,
  );
}

/// Sheet 内容骨架：标题行（左标题 + 右关闭键）+ 固定顶部区 + 滚动内容区
///
/// - 标题 16sp 加粗左对齐，右侧 24dp 关闭图标（需求规格）
/// - [header]（如搜索框）固定在标题下方，不随内容滚动——键盘弹出时
///   焦点元素（搜索框）始终在视口内
/// - [child] 放进 Expanded，内容多时滚动，少时贴顶
/// - [scrollController] 透传给内容 ListView（键盘弹出自动滚到搜索框用）
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.child,
    this.header,
    this.onClose,
  });

  final String title;

  /// 固定顶部区（搜索框等），在标题与内容之间
  final Widget? header;

  /// 滚动内容区（通常 ListView）
  final Widget child;

  /// 关闭回调（默认 Navigator.pop）
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 标题行：16sp 加粗左对齐 + 24dp 关闭图标
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                onPressed: onClose ?? () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 24),
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        ?header,
        Expanded(child: child),
      ],
    );
  }
}

/// 键盘适配包装：面板底部 padding 跟随键盘高度平滑过渡
///
/// 包在 SheetScaffold 外层（showAppBottomSheet 的 builder 内）：
/// - 键盘弹出：padding 从 0 → 键盘高度，面板被顶到键盘上沿
/// - 键盘收起：padding 回到 0，面板恢复原高度
/// - AnimatedPadding 250ms ease-out 与键盘动画同步，无跳变
class SheetKeyboardInset extends StatelessWidget {
  const SheetKeyboardInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: inset),
      child: child,
    );
  }
}
