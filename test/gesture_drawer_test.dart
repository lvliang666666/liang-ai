import 'package:ai_chat_app/widgets/gesture_drawer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('GestureDrawer 跟手性', () {
    testWidgets('dragStartBehavior 必须为 down（消除起手死区）', (tester) async {
      // 默认 start 会吞掉竞技场裁决前的位移（约一个触摸容差）：
      // 起手先有一段抽屉不动的死区、随后突然追赶——"抖一下再滑"。
      // down 让位移从按下点起算，抽屉始终与手指对齐。
      await tester.pumpWidget(wrap(const GestureDrawer(
        drawer: SizedBox.expand(),
        child: SizedBox.expand(),
      )));

      final detectors = tester.widgetList<GestureDetector>(
        find.byType(GestureDetector),
      );
      // 主页面层 + 抽屉面板层 + Scrim（onTap）各一个
      final dragDetectors = detectors
          .where((d) => d.onHorizontalDragStart != null)
          .toList();
      expect(dragDetectors.length, 2, reason: '主页面层 + 抽屉面板层各一个');
      for (final d in dragDetectors) {
        expect(
          d.dragStartBehavior,
          DragStartBehavior.down,
          reason: '两处拖拽 GestureDetector 都必须用 down 起算位移',
        );
      }
    });

    testWidgets('右滑拖拽：进度跟随手指位移（含裁决前积累量）', (tester) async {
      await tester.pumpWidget(wrap(const GestureDrawer(
        drawer: SizedBox.expand(),
        child: SizedBox.expand(),
      )));

      final state = tester.state<GestureDrawerState>(find.byType(GestureDrawer));
      expect(state.progress, 0.0);

      // 从屏幕左缘向右拖 200px（屏宽 800 - edgeMargin 40 = 抽屉宽 760）
      final gesture = await tester.startGesture(const Offset(0, 300));
      await tester.pump();
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();

      // down 行为下位移从按下点起算：200px / 760px ≈ 0.263
      // （start 行为会先吞 ~18px 触摸容差，进度只有 ~0.24）
      expect(state.progress, closeTo(200 / 760, 0.02));

      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      expect(state.progress, closeTo(400 / 760, 0.02));

      // 松手：进度过半 → 保持打开
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.progress, 1.0);
    });

    testWidgets('逐帧增量累加：每帧 update 都在上一帧基础上推进', (tester) async {
      // 回归锁：primaryDelta 是逐帧增量，必须累加而非"起始进度+delta"
      // 直接赋值（后者会让进度每帧被重置回起手位置 = 完全不跟手）
      await tester.pumpWidget(wrap(const GestureDrawer(
        drawer: SizedBox.expand(),
        child: SizedBox.expand(),
      )));

      final state = tester.state<GestureDrawerState>(find.byType(GestureDrawer));

      final gesture = await tester.startGesture(const Offset(0, 300));
      await tester.pump();
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      final afterFirst = state.progress;
      expect(afterFirst, closeTo(50 / 760, 0.02));

      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      // 累加语义：第二次 update 后进度 ≈ 100/760（若实现错误会仍是 50/760）
      expect(state.progress, closeTo(100 / 760, 0.02));
      expect(state.progress, greaterThan(afterFirst));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.progress, 0.0); // 未过半回弹
    });

    testWidgets('拖拽中途松手：速度不足且未过半 → 回弹关闭', (tester) async {
      await tester.pumpWidget(wrap(const GestureDrawer(
        drawer: SizedBox.expand(),
        child: SizedBox.expand(),
      )));

      final state = tester.state<GestureDrawerState>(find.byType(GestureDrawer));

      final gesture = await tester.startGesture(const Offset(0, 300));
      await tester.pump();
      await gesture.moveBy(const Offset(150, 0)); // 150/760 ≈ 0.2 < 0.5
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(state.progress, 0.0);
    });

    testWidgets('打开态左滑拖拽可关闭（面板层手势）', (tester) async {
      await tester.pumpWidget(wrap(const GestureDrawer(
        drawer: SizedBox.expand(),
        child: SizedBox.expand(),
      )));

      final state = tester.state<GestureDrawerState>(find.byType(GestureDrawer));
      state.open();
      await tester.pumpAndSettle();
      expect(state.progress, 1.0);

      // 打开态主页面被面板/Scrim 覆盖，命中面板层 GestureDetector
      final gesture = await tester.startGesture(const Offset(400, 300));
      await tester.pump();
      await gesture.moveBy(const Offset(-300, 0));
      await tester.pump();
      // 1 - 300/760 ≈ 0.605，仍过半 → 松手保持打开
      expect(state.progress, closeTo(1 - 300 / 760, 0.02));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.progress, 1.0);

      // 继续左滑超过一半 → 松手关闭
      final gesture2 = await tester.startGesture(const Offset(400, 300));
      await tester.pump();
      await gesture2.moveBy(const Offset(-500, 0));
      await tester.pump();
      expect(state.progress, closeTo(1 - 500 / 760, 0.02));
      await gesture2.up();
      await tester.pumpAndSettle();
      expect(state.progress, 0.0);
    });
  });
}
