import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// I3 长按菜单升级 UI 测试：底部 action sheet + 重答入口
///
/// 核心行为：
/// - 长按 assistant 气泡弹底部 sheet（复制全文/选择文字/引用/重答/
///   钉住/导出并分享），不再是锚点 showMenu
/// - 长按 user 气泡弹 sheet（复制/编辑重发/钉住）
/// - 点「重答」触发 onRegenerate 回调；onRegenerate null 不显示该项
/// - 点「引用」触发 onQuote；点「编辑重发」触发 onEdit
void main() {
  late SharedPreferences prefs;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ChatMessage msg(String content,
          {String role = 'assistant', int at = 1000}) =>
      ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: role,
        content: content,
        createdAt: at,
      );

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>(
            create: (_) => SettingsService(prefs),
          ),
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(settings: SettingsService(prefs)),
          ),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  group('assistant 气泡长按菜单', () {
    testWidgets('长按弹底部 sheet：六项操作齐全', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答内容'),
        onQuote: () {},
        onRegenerate: () {},
        onTogglePin: (_) {},
      )));
      await tester.pump();

      await tester.longPress(find.text('回答内容'));
      await tester.pumpAndSettle();

      expect(find.text('消息操作'), findsOneWidget);
      expect(find.text('复制全文'), findsOneWidget);
      expect(find.text('选择文字'), findsOneWidget);
      expect(find.text('引用'), findsOneWidget);
      expect(find.text('重答'), findsOneWidget);
      expect(find.text('钉住'), findsOneWidget);
      expect(find.text('导出并分享'), findsOneWidget);
    });

    testWidgets('点「重答」触发 onRegenerate 并关 sheet', (tester) async {
      var regenerated = false;
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答内容'),
        onRegenerate: () => regenerated = true,
      )));
      await tester.pump();

      await tester.longPress(find.text('回答内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重答'));
      await tester.pumpAndSettle();

      expect(regenerated, isTrue);
      expect(find.text('消息操作'), findsNothing);
    });

    testWidgets('onRegenerate 为 null：不显示「重答」项', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答内容'),
        onQuote: () {},
      )));
      await tester.pump();

      await tester.longPress(find.text('回答内容'));
      await tester.pumpAndSettle();

      expect(find.text('重答'), findsNothing);
      expect(find.text('引用'), findsOneWidget);
    });

    testWidgets('点「引用」触发 onQuote 回调', (tester) async {
      var quoted = false;
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答内容'),
        onQuote: () => quoted = true,
      )));
      await tester.pump();

      await tester.longPress(find.text('回答内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用'));
      await tester.pumpAndSettle();

      expect(quoted, isTrue);
    });

    testWidgets('流式中：重答/引用不显示（生成中不可重跑）', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答中'),
        isStreaming: true,
        onQuote: () {},
        onRegenerate: () {},
      )));
      await tester.pump();

      await tester.longPress(find.text('回答中'));
      await tester.pumpAndSettle();

      expect(find.text('重答'), findsNothing);
      expect(find.text('引用'), findsNothing);
      // 复制/选择文字仍可用
      expect(find.text('复制全文'), findsOneWidget);
    });
  });

  group('user 气泡长按菜单', () {
    testWidgets('长按弹底部 sheet：复制/编辑重发/钉住', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('我的提问', role: 'user'),
        onEdit: () {},
        onTogglePin: (_) {},
      )));
      await tester.pump();

      await tester.longPress(find.text('我的提问'));
      await tester.pumpAndSettle();

      // sheet 作用域内查找（横滑动作区也有「复制」label，需限定）
      final sheet = find.ancestor(
        of: find.text('消息操作'),
        matching: find.byType(Column),
      );
      expect(find.text('消息操作'), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('复制')),
          findsOneWidget);
      expect(find.text('编辑重发'), findsOneWidget);
      expect(find.text('钉住'), findsOneWidget);
      // assistant 专属项不出现
      expect(find.text('重答'), findsNothing);
      expect(find.text('引用'), findsNothing);
    });

    testWidgets('点「编辑重发」触发 onEdit 回调', (tester) async {
      var edited = false;
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('我的提问', role: 'user'),
        onEdit: () => edited = true,
      )));
      await tester.pump();

      await tester.longPress(find.text('我的提问'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑重发'));
      await tester.pumpAndSettle();

      expect(edited, isTrue);
    });

    testWidgets('onEdit 为 null：不显示「编辑重发」项', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('我的提问', role: 'user'),
      )));
      await tester.pump();

      await tester.longPress(find.text('我的提问'));
      await tester.pumpAndSettle();

      expect(find.text('编辑重发'), findsNothing);
      // sheet 作用域内「复制」存在（横滑动作区同名 label 需限定作用域）
      final sheet = find.ancestor(
        of: find.text('消息操作'),
        matching: find.byType(Column),
      );
      expect(find.descendant(of: sheet, matching: find.text('复制')),
          findsOneWidget);
    });
  });
}
