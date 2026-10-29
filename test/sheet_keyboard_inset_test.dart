import 'package:ai_chat_app/widgets/app_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// SheetKeyboardInset 键盘适配回归测试
///
/// 背景：v2.3.6 UI 批次 1 首版把高度上限放在 showModalBottomSheet.constraints
/// （键盘 padding 外层），键盘弹出时 padding 挤占内容预算——列表被压到
/// 不足半行、搜索框贴键盘。修复后上限移到 padding 内层。
///
/// 背景 2（v2.16.0 验收反馈）：键盘在场时内容仍取 60% 屏高，矮屏/高键盘
/// 下面板顶边越过状态栏——标题行/搜索框被通知栏遮挡（用户：「整个页面
/// 都铺满了，顶部通知栏挡住了部分的页面」）。修复：键盘在场时内容上限
/// 额外取 `屏高 − 键盘 − 状态栏`。
///
/// 布局数学（松约束下）：
/// - 内容高度 = min(60% 屏高, 屏高 − 键盘高 − 状态栏)
///   - 修复前（上限在外层）：内容 = 60% 屏高 − 键盘高（被挤占）
///   - 修复后（上限在内层）：内容 = min(60% 屏高, 屏高 − 键盘 − 状态栏)
///     真机（屏 ~800dp、键盘 ~280dp、状态栏 ~24dp）→ 内容 496dp，
///     面板顶边正好在状态栏下沿，不再被通知栏遮挡
/// - 面板总高 = 内容 + 键盘 padding，底部锚定屏幕底 → 内容底边
///   正好在键盘上沿
///
/// 测试方式：不真弹键盘（widget 测试推不动 IME），直接以不同
/// viewInsets 值驱动 MediaQuery，断言 SheetKeyboardInset 的布局行为。
/// 宿主布局模拟真实 BottomSheet 内部结构：Align(bottomCenter,
/// heightFactor: 1.0) 的**松约束**（紧约束会吞掉 ConstrainedBox 上限）。
void main() {
  // 测试窗口：800×1200 逻辑像素（典型手机竖屏 dp）
  const screenW = 800.0;
  const screenH = 1200.0;
  const statusBar = 24.0;
  const maxContent = screenH * 0.6; // 720

  void setupView(WidgetTester tester, {double inset = 0}) {
    tester.view.physicalSize = const Size(screenW, screenH);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(top: statusBar);
    tester.view.viewInsets = FakeViewPadding(bottom: inset);
    addTearDown(tester.view.reset);
  }

  /// 模拟 BottomSheet 内部松约束宿主 + 指定键盘 inset
  ///
  /// 状态栏/键盘均通过 tester.view 注入（MediaQuery.fromView 自动读取），
  /// 与真机 WindowInsets 行为一致。
  Widget host(double inset) {
    return MediaQuery.fromView(
      view: RendererBinding.instance.renderViews.single.flutterView,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1.0,
          child: SheetKeyboardInset(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 100), // 模拟标题+搜索框
                Flexible(
                  child: ListView(
                    children: List.generate(
                      20,
                      (i) => SizedBox(height: 48, child: Text('item $i')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 量测内容区（ConstrainedBox 内的 Column）实际高度
  RenderBox contentBox(WidgetTester tester) {
    return tester.renderObject<RenderBox>(
      find.ancestor(
        of: find.text('item 0'),
        matching: find.byType(Column),
      ).first,
    );
  }

  testWidgets('键盘收起（inset=0）：内容上限 = 60% 屏高', (tester) async {
    setupView(tester);
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    expect(contentBox(tester).size.height, closeTo(maxContent, 0.5));
  });

  testWidgets('键盘弹出（inset=300）：内容高度不被挤占（修复前会缩到 420）',
      (tester) async {
    setupView(tester, inset: 300);
    await tester.pumpWidget(host(300));
    await tester.pumpAndSettle();
    // 修复前：上限 720 在 padding 外层 → 内容 = 720-300 = 420（被挤占）
    // 修复后：上限在 padding 内层 → 内容 = min(720, 1200-300-24) = 720
    expect(contentBox(tester).size.height, closeTo(maxContent, 0.5),
        reason: '键盘弹出时内容区高度必须保持 60% 屏高不缩水');
  });

  testWidgets('键盘弹出（inset=300）：内容底边正好在键盘上沿', (tester) async {
    setupView(tester, inset: 300);
    await tester.pumpWidget(host(300));
    await tester.pumpAndSettle();

    // 内容底边 = 键盘上沿（1200 - 300 = 900）
    final box = contentBox(tester);
    final contentBottom = box.localToGlobal(Offset.zero).dy + box.size.height;
    expect(contentBottom, closeTo(screenH - 300, 0.5),
        reason: '内容底边应正好在键盘上沿，搜索框不贴键盘');

    // 面板（含键盘 padding）底部贴屏幕底
    final paddedBox = tester.renderObject<RenderBox>(
      find.ancestor(
        of: find.text('item 0'),
        matching: find.byType(AnimatedPadding),
      ),
    );
    final paddedBottom =
        paddedBox.localToGlobal(Offset.zero).dy + paddedBox.size.height;
    expect(paddedBottom, closeTo(screenH, 0.5), reason: '面板底部应贴屏幕底');
  });

  testWidgets('状态栏保护（v2.16.0 验收反馈）：键盘在场时面板顶边不越过状态栏',
      (tester) async {
    setupView(tester, inset: 500);
    // 高键盘 500dp：60% 上限 720 > 屏高−键盘−状态栏 = 676 → 触发保护
    await tester.pumpWidget(host(500));
    await tester.pumpAndSettle();
    final box = contentBox(tester);
    final contentTop = box.localToGlobal(Offset.zero).dy;
    // 内容 = min(720, 1200-500-24=676) = 676 → 顶边 = 900-676 = 224
    // ≥ 状态栏下沿 24，标题行/搜索框不被通知栏遮挡
    expect(box.size.height, closeTo(screenH - 500 - statusBar, 0.5));
    expect(contentTop, closeTo(statusBar, 0.5),
        reason: '面板顶边应正好落在状态栏下沿，不再被通知栏遮挡');
  });

  testWidgets('状态栏保护不误伤：低键盘时 60% 上限仍生效', (tester) async {
    setupView(tester, inset: 300);
    // 低键盘 300dp：屏高−键盘−状态栏 = 876 > 720 → 60% 上限生效
    await tester.pumpWidget(host(300));
    await tester.pumpAndSettle();
    expect(contentBox(tester).size.height, closeTo(maxContent, 0.5),
        reason: '低键盘时保护上限大于 60% 上限，不应改变既有布局');
  });

  testWidgets('超高键盘（inset=1000 > 60% 屏高）：内容收缩到剩余空间，不溢出',
      (tester) async {
    setupView(tester, inset: 1000);
    await tester.pumpWidget(host(1000));
    await tester.pumpAndSettle();
    // min(720, 1200-1000-24=176) → 内容 176dp（极端情况让位键盘不溢出；
    // 真实设备键盘 240-300dp 不会触发此分支）
    expect(contentBox(tester).size.height,
        closeTo(screenH - 1000 - statusBar, 0.5));
  });

  testWidgets('键盘收起回落：inset 300 → 0，内容高度不变、面板整体回落',
      (tester) async {
    setupView(tester, inset: 300);
    await tester.pumpWidget(host(300));
    await tester.pumpAndSettle();
    final openHeight = contentBox(tester).size.height;
    expect(openHeight, closeTo(maxContent, 0.5));

    // 键盘收起：内容高度不变（不缩水），面板回落
    tester.view.viewInsets = FakeViewPadding(bottom: 0);
    await tester.pumpAndSettle();
    expect(contentBox(tester).size.height, closeTo(openHeight, 0.5),
        reason: '键盘收起后内容高度应与弹出时一致（面板整体回落而非内容回弹）');
  });

  testWidgets('AnimatedPadding 平滑过渡：inset 变化后内容底边位置连续上移',
      (tester) async {
    setupView(tester);
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();

    // 键盘弹出：AnimatedPadding 250ms 过渡（内容高度不变，动的是 padding，
    // 表现为内容底边从屏幕底平滑上移到键盘上沿）
    double contentBottom(WidgetTester t) {
      final box = contentBox(t);
      return box.localToGlobal(Offset.zero).dy + box.size.height;
    }

    final startBottom = contentBottom(tester);
    tester.view.viewInsets = FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final midBottom = contentBottom(tester);
    await tester.pumpAndSettle();
    final endBottom = contentBottom(tester);

    // 内容底边从屏幕底（1200）连续上移到键盘上沿（900）
    expect(startBottom, closeTo(screenH, 0.5));
    expect(endBottom, closeTo(screenH - 300, 0.5));
    expect(midBottom, inExclusiveRange(endBottom, startBottom),
        reason: '过渡中间帧内容底边应连续上移（900 < mid < 1200），无跳变');
  });

  testWidgets('内容不足时贴顶：少内容 + 无键盘，面板高度 = 内容实际高度',
      (tester) async {
    setupView(tester);
    await tester.pumpWidget(
      MediaQuery.fromView(
        view: RendererBinding.instance.renderViews.single.flutterView,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1.0,
            child: SheetKeyboardInset(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  SizedBox(height: 100),
                  SizedBox(height: 80, child: Text('short')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 内容 180dp < 上限 720dp → 面板按内容实际高度收缩
    final box = tester.renderObject<RenderBox>(
      find.ancestor(
        of: find.text('short'),
        matching: find.byType(Column),
      ).first,
    );
    expect(box.size.height, closeTo(180, 0.5));
  });
}
