import 'package:ai_chat_app/widgets/app_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sheet 全局安全区 + 入口统一上限回归测试（v2.30.3 用户验收要求）
///
/// 用户 Bug 报告：「Token 用量页标题被状态栏遮挡……此问题为重复出现
/// （此前其他页面已发生同类 bug），请在全局基类/通用 Scaffold 层统一
/// 处理安全区，一次性修复所有页面，不要逐页打补丁。」
///
/// 框架级根因（SDK 源码确认）：showModalBottomSheet 默认 useSafeArea=false
/// 且内部 `MediaQuery.removePadding(removeTop: true)`——弹层内 padding.top
/// 清零、viewPadding.top 同步清零（removePadding 的 viewPadding 计算 =
/// max(0, viewPadding − padding)，真机两者相等相减为 0），SafeArea/
/// paddingOf/viewPaddingOf 在弹层内**全部失效**。这就是状态栏遮挡 bug
/// 反复出现、逐页打补丁打不完的深层原因。
///
/// 修复：showAppBottomSheet 设 useSafeArea:true——SDK 用
/// SafeArea(bottom:false) 包裹内容，其 Padding(top: 状态栏) 从**约束层**
/// 扣掉状态栏高度，面板内容结构上无法顶进状态栏（键盘在场时同理：
/// 可用高 = 屏高 − 状态栏 − 键盘）。
///
/// 验收标准逐条测试化：
/// 1. 基线：无状态栏时标题行上边距 12dp（布局不变）
/// 2. 接线：弹层内容被 SafeArea 包裹 + 标题不与状态栏重叠
/// 3. 矮屏大内容：SafeArea 约束保护，面板顶边不越过状态栏
///    （60% 上限在 H<60dp 屏会失效，SafeArea 约束削减兜底）
/// 4. 入口统一施加：调用点不包 wrapper 也有 60% 上限（结构性杜绝漏包）
/// 5. maxHeightRatio 透传
/// 6. 键盘在场：面板顶边正好落在状态栏下沿
/// 7. 双层包裹防护：迁移期残留 wrapper 不叠加顶起、不溢出
void main() {
  const screenW = 800.0;
  const screenH = 1200.0;

  void setupView(WidgetTester tester,
      {double statusBar = 0, double inset = 0, Size? size}) {
    tester.view.physicalSize = size ?? const Size(screenW, screenH);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(top: statusBar);
    tester.view.viewInsets = FakeViewPadding(bottom: inset);
    addTearDown(tester.view.reset);
  }

  /// 真实走 showAppBottomSheet 弹出路径（松约束宿主 + useSafeArea + 入口 wrapper）
  Future<void> openViaEntry(
    WidgetTester tester, {
    double maxHeightRatio = kSheetMaxHeightRatio,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showAppBottomSheet<void>(
                context: context,
                maxHeightRatio: maxHeightRatio,
                builder: (context) => SheetScaffold(
                  title: '测试面板',
                  child: ListView(
                    children: [
                      for (var i = 0; i < 40; i++)
                        ListTile(title: Text('条目 $i')),
                    ],
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// 标题行 Padding（SheetScaffold 第一个 child：标题 Text 的直接 Padding 祖先）
  EdgeInsets titleRowPadding(WidgetTester tester) {
    final row = find
        .ancestor(of: find.text('测试面板'), matching: find.byType(Row))
        .first;
    final pad = tester.widget<Padding>(
      find.ancestor(of: row, matching: find.byType(Padding)).first,
    );
    return pad.padding as EdgeInsets;
  }

  testWidgets('验收①：无状态栏（top=0）时标题行上边距 = 12dp（基线不变）',
      (tester) async {
    setupView(tester);
    await openViaEntry(tester);

    expect(titleRowPadding(tester).top, 12,
        reason: '无状态栏时布局与修复前一致（12dp 基线）');
  });

  testWidgets('验收②：状态栏在场（top=24）——SafeArea 接线 + 标题不与状态栏重叠',
      (tester) async {
    setupView(tester, statusBar: 24);
    await openViaEntry(tester);

    // 接线证明：useSafeArea:true → SDK SafeArea 包裹弹层内容
    expect(
      find.ancestor(
          of: find.byType(SheetScaffold), matching: find.byType(SafeArea)),
      findsOneWidget,
      reason: 'showAppBottomSheet 必须以 useSafeArea:true 弹出（全局安全区接线）',
    );
    // 验收标准：标题完整可见，与状态栏无重叠
    final titleTop = tester.getTopLeft(find.text('测试面板')).dy;
    expect(titleTop, greaterThanOrEqualTo(24),
        reason: '标题从安全区下方开始布局，与状态栏无重叠');
  });

  testWidgets('验收②b：刘海屏大 inset（top=48）标题仍不被遮挡', (tester) async {
    setupView(tester, statusBar: 48);
    await openViaEntry(tester);

    final titleTop = tester.getTopLeft(find.text('测试面板')).dy;
    expect(titleTop, greaterThanOrEqualTo(48),
        reason: 'inset 动态读取（SafeArea 约束），刘海屏自适应，无硬编码');
  });

  testWidgets('验收②c：矮屏大内容——SafeArea 约束保护，面板顶边不越过状态栏',
      (tester) async {
    // 屏高 200、状态栏 24、上限 95%：无保护时面板顶边 = 200-190 = 10 < 24；
    // SafeArea 约束削减后可用高 = 200-24 = 176 → 顶边 = 24（结构性保护）
    setupView(tester, statusBar: 24, size: const Size(screenW, 200));
    await openViaEntry(tester, maxHeightRatio: 0.95);

    final box = tester.renderObject<RenderBox>(
      find.byType(SheetScaffold).first,
    );
    final top = box.localToGlobal(Offset.zero).dy;
    expect(top, greaterThanOrEqualTo(24),
        reason: 'SafeArea 从约束层扣掉状态栏高度，面板顶边不越过状态栏下沿');
    expect(box.size.height, lessThanOrEqualTo(200 - 24 + 0.5),
        reason: '内容高 ≤ 屏高 − 状态栏（约束层保护，非布局补丁）');
  });

  testWidgets('验收③：入口统一施加——调用点不包 wrapper 也有 60% 上限',
      (tester) async {
    setupView(tester);
    await openViaEntry(tester);

    final box = tester.renderObject<RenderBox>(
      find.byType(SheetScaffold).first,
    );
    // 40 个条目内容远超上限 → 面板被压到 60% 屏高
    expect(box.size.height, closeTo(screenH * 0.6, 0.5),
        reason: 'showAppBottomSheet 入口自动包 SheetKeyboardInset，'
            '调用点漏包也受 60% 上限约束（结构性杜绝）');
  });

  testWidgets('验收③b：maxHeightRatio 透传（0.45 → 45% 上限）', (tester) async {
    setupView(tester);
    await openViaEntry(tester, maxHeightRatio: 0.45);

    final box = tester.renderObject<RenderBox>(
      find.byType(SheetScaffold).first,
    );
    expect(box.size.height, closeTo(screenH * 0.45, 0.5),
        reason: '入口 maxHeightRatio 参数正确传给内层上限');
  });

  testWidgets('验收④：键盘在场时面板顶边正好落在状态栏下沿', (tester) async {
    setupView(tester, statusBar: 24, inset: 500);
    await openViaEntry(tester);

    final box = tester.renderObject<RenderBox>(
      find.byType(SheetScaffold).first,
    );
    final top = box.localToGlobal(Offset.zero).dy;
    // SafeArea 约束削减 24 + 键盘 padding 500 → 内容 = 1200-24-500 = 676，
    // 内容底边在键盘上沿（700）→ 顶边 = 700-676 = 24 = 状态栏下沿
    expect(box.size.height, closeTo(screenH - 500 - 24, 0.5));
    expect(top, closeTo(24, 0.5),
        reason: '键盘在场时面板顶边正好落在状态栏下沿，标题/搜索框不被通知栏遮挡');
  });

  testWidgets('验收⑤：双层包裹防护——迁移期残留 wrapper 不叠加顶起、不溢出',
      (tester) async {
    // 历史调用点若残留手动 SheetKeyboardInset（迁移遗漏），入口再包一层：
    // 外层 padding 300 + 内层 padding 300 = 600 总 padding，
    // 内容被外层约束压缩到 420（1200-300-300-24×0），总高 1020 < 1200 不溢出
    setupView(tester, inset: 300);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showAppBottomSheet<void>(
                context: context,
                builder: (context) => SheetKeyboardInset(
                  child: SheetScaffold(
                    title: '双层',
                    child: ListView(
                      children: [
                        for (var i = 0; i < 40; i++)
                          ListTile(title: Text('条目 $i')),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final box = tester.renderObject<RenderBox>(
      find.byType(SheetScaffold).first,
    );
    expect(box.size.height, closeTo(420, 0.5),
        reason: '双层包裹时内容被外层约束压缩（1200-300-300-180 键盘外扩）'
            '但不溢出屏幕、不叠加顶起（迁移期防护）');
  });
}
