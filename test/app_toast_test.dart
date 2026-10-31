import 'package:ai_chat_app/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全局 Toast 兜底回归测试（UI 批次 1-① 兜底规范验收标准）
///
/// 需求（docs/UI修改建议.html 一·兜底）：删除成功/网络异常等场景的
/// 统一提示——深色胶囊 rgba(0,0,0,0.75)、高 36dp、底部输入栏上方 8dp、
/// 淡入 200ms / 停留 2000ms / 淡出 150ms、无遮罩不阻断点击、
/// 同时仅存在一个（新替旧）。
///
/// 验收标准逐条测试化：
/// 1. 形态：深色胶囊 + 全圆角 + 白色 14sp 单行文案
/// 2. 行为：IgnorePointer 包裹（不阻断底层点击）
/// 3. 单例：连续两次调用，新替旧（同一 entry，不叠加）
/// 4. 自动消失：约 2.35s 后浮层移除
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: Text('page'))),
    ));
  }

  /// 查找 Toast 深色胶囊（rgba(0,0,0,0.75)）
  Finder toastBubble() => find.byWidgetPredicate((w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).color == const Color(0xBF000000));

  testWidgets('验收①：显示深色胶囊 + 白色文案（规格形态）', (tester) async {
    await pumpHost(tester);
    showAppToast(tester.element(find.text('page')), '删除成功');
    await tester.pumpAndSettle();

    expect(toastBubble(), findsOneWidget);
    expect(find.text('删除成功'), findsOneWidget);

    // 胶囊规格：全圆角（高 36 → 半径 18）+ 最小高 36
    final bubble = tester.widget<Container>(toastBubble());
    final decoration = bubble.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(18));
    expect(bubble.constraints?.minHeight, 36);
  });

  testWidgets('验收②：Toast 不阻断底层点击（IgnorePointer）', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => taps++,
            child: const Text('underneath'),
          ),
        ),
      ),
    ));
    showAppToast(tester.element(find.text('underneath')), '提示');
    await tester.pumpAndSettle();

    expect(toastBubble(), findsOneWidget);
    // Toast 在屏时底层按钮仍可点（无遮罩不阻断）
    await tester.tap(find.text('underneath'), warnIfMissed: false);
    expect(taps, 1, reason: 'Toast 无遮罩，底层按钮可正常点击');
  });

  testWidgets('验收③：连续调用新替旧（同一时刻仅一个 Toast）', (tester) async {
    await pumpHost(tester);
    final context = tester.element(find.text('page'));

    showAppToast(context, '第一条');
    await tester.pumpAndSettle();
    expect(toastBubble(), findsOneWidget);
    expect(find.text('第一条'), findsOneWidget);

    showAppToast(context, '第二条');
    await tester.pumpAndSettle();
    // 新替旧：旧文案消失，新文案在屏，仍只有一个胶囊
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);
    expect(toastBubble(), findsOneWidget,
        reason: '同时仅存在一个 Toast，不叠加');
  });

  testWidgets('验收④：约 2.35s 后 Toast 自动消失', (tester) async {
    await pumpHost(tester);
    showAppToast(tester.element(find.text('page')), '会消失');
    await tester.pumpAndSettle();
    expect(toastBubble(), findsOneWidget);

    // 停留段计时 2200ms + 淡出 150ms
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(toastBubble(), findsNothing,
        reason: '停留 2000ms + 淡出后浮层移除');
  });
}
