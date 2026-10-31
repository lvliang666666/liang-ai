import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 标准 Bottom Sheet 骨架（UI 批次 1 统一容器）
///
/// 全 app 的选择面板（Agent/模型/附件/导出格式等）统一走 [showAppBottomSheet]：
/// - 容器：顶部圆角 16，内容最大高度 60% 屏高，可下拉关闭
/// - 遮罩：rgba(0,0,0,0.4)，点击关闭
/// - 动效：250ms ease-out 滑入 / 200ms ease-in 滑出（与键盘动画同量级）
/// - 键盘适配：面板整体上移至键盘上沿（AnimatedPadding 跟随 viewInsets），
///   高度上限在键盘 padding 内层（见 [SheetKeyboardInset]），内容区
///   最小保留 [kSheetMinContentHeight]，键盘弹出/收起平滑过渡不跳变
///
/// 内容用 [SheetScaffold] 组装：标题行（16sp 加粗 + 24dp 关闭键）+
/// 可选搜索框固定顶部 + Flexible 滚动内容区。
///
/// 用法：
/// ```dart
/// final result = await showAppBottomSheet<Agent?>(
///   context: context,
///   title: '选择 Agent',
///   builder: (context) => SheetScaffold(
///     title: '选择 Agent',
///     onClose: () => Navigator.pop(context),
///     child: ...列表...,
///   ),
/// );
/// ```
///
/// 键盘适配要点（需求文档「实现提示」）：高度监听用 Flutter 的
/// MediaQuery.viewInsetsOf（底层即 WindowInsets/IME 高度），禁止硬编码
/// 键盘高度；AnimatedPadding 时长 250ms 与面板/键盘动画一致，禁止跳变；
/// 高度上限必须施加在键盘 padding 内层（见 [SheetKeyboardInset]）。

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
///
/// **键盘适配与高度上限在入口统一施加**（v2.30.3）：builder 返回的内容
/// 自动被 [SheetKeyboardInset] 包裹——60% 屏高上限 + 键盘跟随 + 状态栏
/// 保护一次到位，调用点**无需（也不应）再手动包裹**。此前由各调用点
/// 自行包裹，v2.30.2/v2.30.3 两轮共发现 6 处漏包（晨报/承诺跟进/
/// Token 用量/消息操作×2/引用来源），下沉到单一入口后结构性杜绝。
///
/// **useSafeArea: true（v2.30.3 全局安全区）**：showModalBottomSheet
/// 默认 useSafeArea=false 且内部 removePadding(removeTop:true)——
/// 弹层内 padding.top 与 viewPadding.top **双双清零**（removePadding
/// 的 viewPadding 计算 = max(0, viewPadding − padding)，真机两者相等
/// 相减为 0），SafeArea/paddingOf/viewPaddingOf 在弹层内全部失效，
/// 这是状态栏遮挡 bug 反复出现的框架级根因。useSafeArea=true 让
/// SDK 用 SafeArea(bottom:false) 包裹内容，状态栏保护由框架完成。
///
/// 注意：这里**不**给 showModalBottomSheet 传固定 constraints——高度上限
/// 由 [SheetKeyboardInset] 在键盘 padding 内层施加（见其文档注释）。
/// 若在此处传 maxHeight，键盘弹出时 padding 会挤占内容预算而非抬高面板
/// （v2.3.6 UI 批次 1 首版真机翻车的根因）。
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxHeightRatio = kSheetMaxHeightRatio,
  Color? barrierColor = kSheetBarrierColor,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true, // v2.30.3：状态栏保护下沉到框架（见文档注释）
    backgroundColor: Theme.of(context).colorScheme.surface,
    barrierColor: barrierColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    enableDrag: true,
    sheetAnimationStyle: kSheetAnimationStyle,
    builder: (context) => SheetKeyboardInset(
      maxHeightRatio: maxHeightRatio,
      child: builder(context),
    ),
  );
}

/// Sheet 内容骨架：标题行（左标题 + 右关闭键）+ 固定顶部区 + 滚动内容区
///
/// - 标题 16sp 加粗左对齐，右侧 24dp 关闭图标（需求规格）
/// - **顶部安全区**：标题行上边距自动叠加 `MediaQuery.padding.top`
///   （v2.30.3 全局修复——面板顶到屏幕顶时标题不被状态栏遮挡；
///   配合 showAppBottomSheet 的 useSafeArea:true，弹层内 padding.top
///   保留真实状态栏高度，刘海屏/横竖屏自适应，
///   全 app 所有走 [SheetScaffold] 的弹层一次生效）
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
    // 顶部安全区（v2.30.3 全局修复）：Sheet 高度上限是比例值，在矮屏/
    // 大内容下面板可顶到屏幕顶——标题行必须从状态栏下沿开始布局。
    // showAppBottomSheet 已设 useSafeArea:true（弹层内 padding.top
    // 保留真实状态栏高度），这里动态读取叠加，刘海屏/横竖屏自适应，
    // 禁止硬编码 24dp（用户验收要求 #1）。
    final topInset = MediaQuery.paddingOf(context).top;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 标题行：16sp 加粗左对齐 + 24dp 关闭图标；上边距 = 安全区 + 12dp
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12 + topInset, 8, 4),
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
///
/// 高度上限（[kSheetMaxHeightRatio] × 屏高）施加在 padding **内层**：
/// 键盘弹出时面板总高 = 内容高 + 键盘高，内容预算不被键盘挤占，
/// 搜索框/列表保持完整可视；上限只约束内容部分，面板整体仍可越过
/// 60% 线顶到键盘上沿。若把上限放在 padding 外层（如首版在
/// showModalBottomSheet.constraints 传 maxHeight），padding 会反向
/// 压缩内容——列表被压到不足半行。
///
/// **状态栏保护（v2.16.0 验收反馈）**：键盘在场时内容上限额外取
/// `屏高 − 键盘 − 状态栏`，保证面板顶边不越过状态栏下沿——否则
/// 「60% 内容 + 键盘」在矮屏/高键盘（中文输入法带工具条可达 320dp+）
/// 下会把标题行和搜索框顶进通知栏遮挡区（同类问题在多个项目复现，
/// 已沉淀 lessons：2026-10-29-flutter-sheet-keyboard-statusbar-overflow.md）。
/// 无键盘时该值远大于 60% 上限，不改变既有布局。
///
/// **v2.30.3 关键修复**：状态栏高度依赖 `showAppBottomSheet` 的
/// `useSafeArea: true`——SDK 默认 useSafeArea=false 且内部
/// `removePadding(removeTop: true)` 把弹层内 padding/viewPadding
/// 双双清零，此前 `paddingOf` 读到的恒为 0，状态栏保护在真实弹层
/// 路径从未生效（组件级测试直 pump 读得到 24，掩盖了这一点——
/// 接线级测试才能暴露）。
///
/// 注意：本组件必须工作在**松约束**下（BottomSheet 内部是
/// Align(heightFactor: 1.0) 的松约束）。若外层传紧约束
/// （如 SizedBox.expand），ConstrainedBox 的上限会被紧约束吞掉。
class SheetKeyboardInset extends StatelessWidget {
  const SheetKeyboardInset({
    super.key,
    required this.child,
    this.maxHeightRatio = kSheetMaxHeightRatio,
  });

  final Widget child;

  /// 内容区最大高度占屏高比例（键盘 padding 之外的部分）
  final double maxHeightRatio;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final screenH = MediaQuery.heightOf(context);
    // 状态栏高度：showAppBottomSheet 已设 useSafeArea:true，弹层内
    // padding.top 保留真实值（默认 useSafeArea=false 时 SDK 内部
    // removePadding(removeTop:true) 会把 padding/viewPadding 双双清零，
    // 此前 paddingOf 读到的恒为 0，状态栏保护从未在真机生效——v2.30.3 修复）
    final statusBar = MediaQuery.paddingOf(context).top;
    // 常规上限：60% 屏高
    final ratioCap = math.max(0.0, screenH * maxHeightRatio);
    // 状态栏保护：键盘在场时，面板顶边 = 屏高 − 键盘 − 内容高，
    // 要求顶边不低于状态栏下沿 → 内容高 ≤ 屏高 − 键盘 − 状态栏。
    // 无键盘时该值 ≥ 屏高 − 状态栏 > 60% 上限，取 min 后不生效。
    final keyboardCap = math.max(0.0, screenH - inset - statusBar);
    return AnimatedPadding(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: inset),
      // 高度上限在 padding 内层：键盘弹出时面板总高 = 内容 + 键盘，
      // 内容预算不被键盘挤占。AnimatedPadding 的 deflate 会把外层约束
      // 减去键盘高度后再传给 ConstrainedBox，与 60% 上限取小——
      // 极端矮屏/高键盘时内容自动收缩，不会溢出屏幕。
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.min(ratioCap, keyboardCap),
        ),
        child: child,
      ),
    );
  }
}
