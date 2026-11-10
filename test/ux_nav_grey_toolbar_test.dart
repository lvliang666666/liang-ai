import 'package:ai_chat_app/widgets/app_error_widget.dart';
import 'package:ai_chat_app/widgets/chat_tags_bar.dart';
import 'package:ai_chat_app/widgets/gesture_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全局返回导航与灰屏治理批次回归锁（需求一/二/三）
///
/// 需求一：抽屉展开按返回 → 关抽屉不退出；关闭态放行返回
/// 需求二：ErrorWidget.builder 兜底页渲染可读错误 + 重试重建
/// 需求三：tags 工具条 32dp 高 + 4dp 内边距（紧贴输入框）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('需求一：抽屉返回键拦截', () {
    testWidgets('展开态按返回：抽屉关闭，页面不 pop', (tester) async {
      var popped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) popped = true;
            },
            child: Scaffold(
              body: GestureDrawer(
                drawer: const SizedBox.expand(),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      final state =
          tester.state<GestureDrawerState>(find.byType(GestureDrawer));
      state.open();
      await tester.pumpAndSettle();
      expect(state.isOpen, isTrue);

      // 模拟系统返回键（maybePop 走 PopEntry 链：doNotPop 也返回 true
      // =「pop 请求已被处理」，bubble 才返回 false）
      final navigatorState = tester.state<NavigatorState>(
        find.byType(Navigator),
      );
      final handled = await navigatorState.maybePop();
      await tester.pumpAndSettle();

      // 抽屉被拦截关闭：maybePop 返回 true（请求被消费，未 bubble），
      // 页面没退（popped 未触发），抽屉进度归零
      expect(handled, isTrue, reason: '展开态返回事件应被抽屉 PopEntry 消费');
      expect(popped, isFalse, reason: '宿主页不应收到 pop');
      expect(state.progress, 0.0, reason: '返回键应关闭抽屉');
    });

    testWidgets('关闭态按返回：放行（宿主双击退出逻辑接管）', (tester) async {
      var popInvoked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) => popInvoked = true,
            child: Scaffold(
              body: GestureDrawer(
                drawer: const SizedBox.expand(),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      final navigatorState = tester.state<NavigatorState>(
        find.byType(Navigator),
      );
      await navigatorState.maybePop();
      await tester.pumpAndSettle();

      // 关闭态 canPop=true → 抽屉不消费，事件冒泡到宿主 PopScope
      expect(popInvoked, isTrue,
          reason: '关闭态返回应放行给宿主（双击退出判定）');
    });

    testWidgets('isOpen 阈值：进度 >0.05 视为展开', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDrawer(
              drawer: const SizedBox.expand(),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      final state =
          tester.state<GestureDrawerState>(find.byType(GestureDrawer));
      expect(state.isOpen, isFalse, reason: '关闭态 isOpen=false');

      state.open();
      await tester.pumpAndSettle();
      expect(state.isOpen, isTrue, reason: '展开态 isOpen=true');

      state.close();
      await tester.pumpAndSettle();
      expect(state.isOpen, isFalse, reason: '关回后 isOpen=false');
    });
  });

  group('需求二：全局错误页兜底', () {
    testWidgets('GlobalErrorPage 渲染可读错误页（图标+摘要+重试）',
        (tester) async {
      // flutter_test 禁止测试修改 ErrorWidget.builder（框架校验），
      // 直接 pump 组件本体验证渲染结构（installGlobalErrorWidget 的
      // 接线在 main() 里，真机路径覆盖）
      await tester.pumpWidget(
        const MaterialApp(home: GlobalErrorPage(summary: 'Null check operator')),
      );

      expect(find.text('页面出错了'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('重试按钮自增 generation（触发子树重建）', (tester) async {
      final before = kErrorPageRetryGeneration.value;

      await tester.pumpWidget(
        const MaterialApp(home: GlobalErrorPage(summary: 'boom')),
      );
      await tester.tap(find.text('重试'));
      await tester.pump();

      expect(kErrorPageRetryGeneration.value, before + 1,
          reason: '重试必须自增 generation 以强制重建');
    });

    testWidgets('可 pop 的路由下显示「返回上一页」按钮', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const GlobalErrorPage(summary: '二级页崩了'),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('返回上一页'), findsOneWidget,
          reason: '二级页出错应提供返回入口');
    });

    testWidgets('根路由（不可 pop）不显示「返回上一页」按钮', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: GlobalErrorPage(summary: '根页崩了')),
      );

      expect(find.text('返回上一页'), findsNothing,
          reason: '根页面无上一页可回，按钮应隐藏');
    });
  });

  group('需求三：工具条收窄', () {
    testWidgets('ChatTagsBar 行高 32dp（原 40dp）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatTagsBar(tags: [
              ChatTag(icon: Icons.smart_toy_outlined, label: '默认助手', onTap: _noop),
              ChatTag(icon: Icons.tune, label: '默认模型', onTap: _noop),
            ]),
          ),
        ),
      );

      final bar = tester.widget<SizedBox>(
        find.ancestor(
          of: find.byType(ListView),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(bar.height, 32, reason: '工具条行高收窄到 32dp');
    });

    testWidgets('胶囊按钮内边距 vertical 4dp（按钮高 32dp）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatTagsBar(tags: [
              ChatTag(icon: Icons.smart_toy_outlined, label: '默认助手', onTap: _noop),
            ]),
          ),
        ),
      );

      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      final padding = container.padding as EdgeInsets;
      // EdgeInsets.symmetric 的 horizontal getter = left+right = 24，
      // 必须分别断言 left/right
      expect(padding.top, 4, reason: '上内边距 4dp');
      expect(padding.bottom, 4, reason: '下内边距 4dp');
      expect(padding.left, 12, reason: '左内边距 12dp');
      expect(padding.right, 12, reason: '右内边距 12dp');
    });
  });
}

void _noop() {}
