import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:ai_chat_app/widgets/swipe_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SwipeActionContainer', () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Center(child: child)));

    Future<void> dragHorizontally(
      WidgetTester tester,
      Finder on, {
      required double dx,
    }) async {
      final gesture = await tester.startGesture(tester.getCenter(on));
      // 分步拖拽（每步 20px，模拟真实手指）
      var moved = 0.0;
      final step = dx.isNegative ? -40.0 : 40.0;
      while (moved.abs() < dx.abs()) {
        final remaining = dx.abs() - moved.abs();
        final d = remaining.abs() < step.abs() ? step.sign * remaining : step;
        await gesture.moveBy(Offset(d, 0));
        moved += d;
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
    }

    testWidgets('右滑露出动作区：图标与文字随进度出现', (tester) async {
      var fired = false;
      await tester.pumpWidget(wrap(SwipeActionContainer(
        direction: SwipeDirection.leftToRight,
        icon: Icons.copy_outlined,
        label: '复制',
        color: Colors.blue,
        onAction: () => fired = true,
        child: const SizedBox(width: 200, height: 60),
      )));
      await tester.pump();

      // 未滑动：动作区 opacity 0（仍在树中但透明）
      final opacity0 = tester.widget<Opacity>(
          find.ancestor(of: find.text('复制'), matching: find.byType(Opacity)));
      expect(opacity0.opacity, 0);

      // 拖到一半：进度 0.5 左右
      await dragHorizontally(tester, find.byType(SwipeActionContainer),
          dx: 44);
      final opacityMid = tester.widget<Opacity>(
          find.ancestor(of: find.text('复制'), matching: find.byType(Opacity)));
      expect(opacityMid.opacity, greaterThan(0.3));
      expect(opacityMid.opacity, lessThan(0.7));
      expect(fired, isFalse); // 未松手不触发
    });

    testWidgets('右滑越阈松手：触发 onAction 并回弹归位', (tester) async {
      var fired = 0;
      await tester.pumpWidget(wrap(SwipeActionContainer(
        direction: SwipeDirection.leftToRight,
        icon: Icons.copy_outlined,
        label: '复制',
        color: Colors.blue,
        onAction: () => fired++,
        child: const SizedBox(width: 200, height: 60),
      )));
      await tester.pump();

      // 阈值 88*0.6=52.8，滑 80px 越阈
      await dragHorizontally(tester, find.byType(SwipeActionContainer),
          dx: 80);
      // 松手即触发（onAction 在 dragEnd 同步调用；回弹动画随后）
      expect(fired, 1);

      await tester.pumpAndSettle();
      expect(fired, 1); // 只触发一次

      // 回弹归位：气泡层 Transform.translate 回到 0
      //（取含 Offset 平移的那个 Transform——Stack 里动作区还有
      // Transform.translate 图标微移节点，用 .last 取气泡层）
      final transforms = tester.widgetList<Transform>(
          find.descendant(
              of: find.byType(SwipeActionContainer),
              matching: find.byType(Transform)));
      final bubble = transforms
          .where((t) => t.transform.getTranslation().x.abs() < 1)
          .toList();
      expect(bubble, isNotEmpty,
          reason: '回弹后气泡层平移应归零');
    });

    testWidgets('右滑未越阈松手：不触发，回弹归位', (tester) async {
      var fired = 0;
      await tester.pumpWidget(wrap(SwipeActionContainer(
        direction: SwipeDirection.leftToRight,
        icon: Icons.copy_outlined,
        label: '复制',
        color: Colors.blue,
        onAction: () => fired++,
        child: const SizedBox(width: 200, height: 60),
      )));
      await tester.pump();

      await dragHorizontally(tester, find.byType(SwipeActionContainer),
          dx: 30);
      await tester.pumpAndSettle();

      expect(fired, 0);
    });

    testWidgets('左滑（rightToLeft）：向左拖露出动作区并触发', (tester) async {
      var fired = 0;
      await tester.pumpWidget(wrap(SwipeActionContainer(
        direction: SwipeDirection.rightToLeft,
        icon: Icons.copy_outlined,
        label: '复制',
        color: Colors.blue,
        onAction: () => fired++,
        child: const SizedBox(width: 200, height: 60),
      )));
      await tester.pump();

      await dragHorizontally(tester, find.byType(SwipeActionContainer),
          dx: -80);
      await tester.pumpAndSettle();

      expect(fired, 1);
    });

    testWidgets('enabled=false：拖拽无效不触发', (tester) async {
      var fired = 0;
      await tester.pumpWidget(wrap(SwipeActionContainer(
        direction: SwipeDirection.leftToRight,
        icon: Icons.copy_outlined,
        label: '复制',
        color: Colors.blue,
        enabled: false,
        onAction: () => fired++,
        child: const SizedBox(width: 200, height: 60),
      )));
      await tester.pump();

      await dragHorizontally(tester, find.byType(SwipeActionContainer),
          dx: 80);
      await tester.pumpAndSettle();

      expect(fired, 0);
    });
  });

  group('MessageBubble 横滑复制（I2）', () {
    String? clipboardText;

    setUp(() {
      clipboardText = null;
      // mock 剪贴板通道：widget 测试无 handler 时 Clipboard 调用永不完成
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = call.arguments['text'] as String?;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: ListView(children: [child])));

    /// 横滑三步 + 松手 + 固定 pump（回弹 200ms；不用 pumpAndSettle——
    /// 流式气泡的打字点/打字机是无限动画会卡死）
    Future<void> swipeAndRelease(
      WidgetTester tester,
      Finder on, {
      required double dx,
    }) async {
      final gesture = await tester.startGesture(tester.getCenter(on));
      final step = Offset(dx / 3, 0);
      for (var i = 0; i < 3; i++) {
        await gesture.moveBy(step);
        await tester.pump();
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('助手消息左滑越阈：剪贴板收到全文', (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '助手回答内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(wrap(MessageBubble(message: msg)));
      await tester.pump();

      await swipeAndRelease(
          tester, find.text('助手回答内容'), dx: -120);

      expect(clipboardText, '助手回答内容');

      // 收尾：Toast 定时器走完（防 pending timer 报错）
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('用户消息右滑越阈：剪贴板收到全文', (tester) async {
      final msg = ChatMessage(
        id: 'm2',
        sessionId: 's1',
        role: 'user',
        content: '用户提问内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(wrap(MessageBubble(message: msg)));
      await tester.pump();

      await swipeAndRelease(
          tester, find.text('用户提问内容'), dx: 120);

      expect(clipboardText, '用户提问内容');

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('流式中的消息：横滑禁用（不触发复制）', (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '流式内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg,
        isStreaming: true,
      )));
      await tester.pump();

      await swipeAndRelease(tester, find.text('流式内容'), dx: -120);

      expect(clipboardText, isNull);
    });
  });
}
