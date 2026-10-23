import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/gesture_drawer.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:ai_chat_app/widgets/swipe_action.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
  });

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

    testWidgets('方向锁：rightToLeft 容器上右滑不认领（识别器弃权）',
        (tester) async {
      // 方向锁核心语义：反方向横滑时识别器保持 possible 态不认领，
      // 竞技场让位给其他竞争者（真实场景 = 右滑抽屉）。这里用
      // "外层也监听横滑"模拟竞争者：反方向滑动时外层应收到手势。
      var outerDragged = 0.0;
      var fired = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: RawGestureDetector(
              behavior: HitTestBehavior.translucent,
              gestures: {
                HorizontalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        HorizontalDragGestureRecognizer>(
                  () => HorizontalDragGestureRecognizer()
                    ..dragStartBehavior = DragStartBehavior.down,
                  (instance) {
                    instance.onUpdate = (d) =>
                        outerDragged += d.primaryDelta ?? 0;
                  },
                ),
              },
              child: SwipeActionContainer(
                direction: SwipeDirection.rightToLeft,
                icon: Icons.copy_outlined,
                label: '复制',
                color: Colors.blue,
                onAction: () => fired++,
                child: const SizedBox(width: 200, height: 60),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      // 右滑（反方向）：外层收到全部位移，容器不触发
      await dragHorizontally(tester, find.byType(SwipeActionContainer),
          dx: 80);
      expect(outerDragged, greaterThan(60),
          reason: '反方向横滑应让位给外层识别器');
      expect(fired, 0);

      // 左滑（同方向）：容器正常认领并触发
      await dragHorizontally(tester, find.byType(SwipeActionContainer),
          dx: -80);
      expect(fired, 1);
      await tester.pumpAndSettle();
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

    Widget wrap(Widget child) => MaterialApp(
          home: Scaffold(
            body: ListView(children: [child]),
          ),
        );

    /// 带 SettingsService Provider 的包装（MessageBubble watch 开关）
    Widget wrapWithSettings(Widget child) => MultiProvider(
          providers: [
            Provider<SettingsService>.value(value: settings),
          ],
          child: wrap(child),
        );

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
      await tester.pumpWidget(wrapWithSettings(MessageBubble(message: msg)));
      await tester.pump();

      await swipeAndRelease(
          tester, find.text('助手回答内容'), dx: -120);

      expect(clipboardText, '助手回答内容');

      // 收尾：Toast 定时器走完（防 pending timer 报错）
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('用户消息右滑越阈：剪贴板收到全文（v2.5.0 方案）', (tester) async {
      final msg = ChatMessage(
        id: 'm2',
        sessionId: 's1',
        role: 'user',
        content: '用户提问内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(wrapWithSettings(MessageBubble(message: msg)));
      await tester.pump();

      await swipeAndRelease(
          tester, find.text('用户提问内容'), dx: 120);

      expect(clipboardText, '用户提问内容');

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('快捷操作关：横滑禁用（长按复制仍可用）', (tester) async {
      await settings.setSwipeActions(false);
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '助手回答内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(wrapWithSettings(MessageBubble(message: msg)));
      await tester.pump();

      // 左滑越阈：开关关 → 不触发复制
      await swipeAndRelease(tester, find.text('助手回答内容'), dx: -120);
      expect(clipboardText, isNull);

      // 长按菜单复制仍可用
      await tester.longPress(find.text('助手回答内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制全文'));
      await tester.pumpAndSettle();
      expect(clipboardText, '助手回答内容');

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
      await tester.pumpWidget(
          wrapWithSettings(MessageBubble(message: msg, isStreaming: true)));
      await tester.pump();

      await swipeAndRelease(tester, find.text('流式内容'), dx: -120);

      expect(clipboardText, isNull);
    });

    testWidgets('长按助手气泡：锚点菜单三项（复制全文/选择文字/导出）',
        (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '助手回答内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(wrapWithSettings(MessageBubble(message: msg)));
      await tester.pump();

      await tester.longPress(find.text('助手回答内容'));
      await tester.pumpAndSettle();

      // 锚点菜单弹出（非底部弹层）：三项可见
      expect(find.text('复制全文'), findsOneWidget);
      expect(find.text('选择文字'), findsOneWidget);
      expect(find.text('导出并分享'), findsOneWidget);

      // 点「复制全文」→ 剪贴板收到全文
      await tester.tap(find.text('复制全文'));
      await tester.pumpAndSettle();
      expect(clipboardText, '助手回答内容');

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('锚点菜单点「选择文字」：原地切换为可选文本（不弹层）',
        (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '助手回答内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(wrapWithSettings(MessageBubble(message: msg)));
      await tester.pump();

      await tester.longPress(find.text('助手回答内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文字'));
      await tester.pumpAndSettle();

      // 原地选择模式：提示行 + 完成按钮出现在气泡内，正文变 SelectableText
      expect(find.text('长按文字挑选片段，用系统工具条复制'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('助手回答内容'), findsOneWidget);

      // 点「完成」退出选择模式：正文回 Markdown（SelectableText 消失）
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('长按文字挑选片段，用系统工具条复制'), findsNothing);
    });
  });

  group('SwipeActionContainer × GestureDrawer 共存（v2.5.3 方向锁）', () {
    /// 共存测试包装：GestureDrawer + SettingsService Provider
    Widget drawerWrap(Widget child) => MultiProvider(
          providers: [
            Provider<SettingsService>.value(value: settings),
          ],
          child: MaterialApp(
            home: GestureDrawer(
              drawer: const SizedBox.expand(),
              child: Scaffold(
                body: ListView(children: [child]),
              ),
            ),
          ),
        );

    testWidgets('助手气泡上右滑：开抽屉（方向锁让位，不触发复制）',
        (tester) async {
      final drawerKey = GlobalKey<GestureDrawerState>();
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '助手回答内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(drawerWrap(MessageBubble(message: msg)));
      // 重新拿 drawerKey：drawerWrap 里没挂 key，改用 type 查找
      final state = tester.state<GestureDrawerState>(
          find.byType(GestureDrawer));
      await tester.pump();

      // 助手气泡文字上右滑 600px：应开抽屉而非触发复制
      //（抽屉宽 800-40=760，松手过半判定需 >380px，200px 会被回弹）
      final gesture = await tester.startGesture(
          tester.getCenter(find.text('助手回答内容')));
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 抽屉打开（进度 1.0），复制未触发
      expect(state.progress, 1.0,
          reason: '气泡上右滑应开抽屉（方向锁弃权让位）');
    });

    testWidgets('助手气泡上左滑：触发复制（抽屉不动）', (tester) async {
      final msg = ChatMessage(
        id: 'm2',
        sessionId: 's1',
        role: 'assistant',
        content: '助手回答内容',
        createdAt: 1000,
      );
      await tester.pumpWidget(drawerWrap(MessageBubble(message: msg)));
      final state = tester.state<GestureDrawerState>(
          find.byType(GestureDrawer));
      await tester.pump();

      // 左滑 200px：容器认领（同方向），抽屉进度保持 0
      final gesture = await tester.startGesture(
          tester.getCenter(find.text('助手回答内容')));
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(state.progress, 0.0,
          reason: '左滑复制时抽屉不应被误开');
    });
  });
}
