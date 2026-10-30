import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/services/output_contract.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:ai_chat_app/widgets/output_contract_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nested/nested.dart' show SingleChildWidget;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final contract = OutputContract.parse('count=张数, total=合计金额')!;

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// MessageBubble 依赖 SettingsService（快捷操作开关）
  Future<List<SingleChildWidget>> bubbleProviders() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService(await SharedPreferences.getInstance());
    return [ChangeNotifierProvider<SettingsService>.value(value: settings)];
  }

  group('OutputContractCard 组件', () {
    testWidgets('渲染徽标 + 契约字段行（显示名 + 值）', (tester) async {
      await tester.pumpWidget(wrap(OutputContractCard(
        contract: contract,
        values: {'count': '2', 'total': '199.0'},
      )));

      expect(find.text('结构化结果'), findsOneWidget);
      expect(find.text('张数'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('合计金额'), findsOneWidget);
      expect(find.text('199.0'), findsOneWidget);
    });

    testWidgets('未声明字段不渲染；空值字段不渲染', (tester) async {
      await tester.pumpWidget(wrap(OutputContractCard(
        contract: contract,
        values: {'count': '2', 'extra': '噪音'},
      )));

      expect(find.text('张数'), findsOneWidget);
      expect(find.text('噪音'), findsNothing);
      expect(find.text('合计金额'), findsNothing); // 无值不渲染
    });

    testWidgets('长值换行显示（多行文本）', (tester) async {
      await tester.pumpWidget(wrap(OutputContractCard(
        contract: contract,
        values: {'count': '2', 'total': '199.0\n（含税）'},
      )));

      expect(find.textContaining('含税'), findsOneWidget);
    });

    testWidgets('空 values 渲染空（不炸）', (tester) async {
      await tester.pumpWidget(wrap(OutputContractCard(
        contract: contract,
        values: const {},
      )));
      expect(find.byType(OutputContractCard), findsOneWidget);
      expect(find.text('结构化结果'), findsNothing);
    });
  });

  group('MessageBubble 集成', () {
    ChatMessage assistant(String content) => ChatMessage(
          id: 'm1',
          sessionId: 's1',
          role: 'assistant',
          content: content,
          createdAt: 1000,
        );

    Future<void> pumpBubble(WidgetTester tester, Widget bubble) async {
      final providers = await bubbleProviders();
      await tester.pumpWidget(MultiProvider(
        providers: providers,
        child: wrap(bubble),
      ));
      await tester.pump();
    }

    testWidgets('声明契约 + 回复含 yaml 块：渲染专属卡片', (tester) async {
      await pumpBubble(
          tester,
          MessageBubble(
            message:
                assistant('共 2 张发票。\n\n```yaml\ncount: 2\ntotal: 199.0\n```'),
            outputContract: contract,
          ));

      expect(find.text('结构化结果'), findsOneWidget);
      expect(find.text('张数'), findsOneWidget);
      expect(find.text('199.0'), findsOneWidget);
    });

    testWidgets('声明契约但回复无 yaml 块：无卡片（markdown 照常）', (tester) async {
      await pumpBubble(
          tester,
          MessageBubble(
            message: assistant('普通回答，没有结构化输出'),
            outputContract: contract,
          ));

      expect(find.text('结构化结果'), findsNothing);
      expect(find.text('普通回答，没有结构化输出'), findsOneWidget);
    });

    testWidgets('未声明契约：无卡片（零改动）', (tester) async {
      await pumpBubble(
          tester,
          MessageBubble(
            message: assistant('回答\n\n```yaml\ncount: 2\n```'),
          ));

      expect(find.text('结构化结果'), findsNothing);
    });

    testWidgets('流式中不渲染卡片（yaml 半截会闪烁）', (tester) async {
      await pumpBubble(
          tester,
          MessageBubble(
            message: assistant('回答中\n\n```yaml\ncount: 2\n```'),
            isStreaming: true,
            outputContract: contract,
          ));

      expect(find.text('结构化结果'), findsNothing);
    });

    testWidgets('user 消息不渲染卡片', (tester) async {
      final user = ChatMessage(
        id: 'm2',
        sessionId: 's1',
        role: 'user',
        content: '```yaml\ncount: 2\n```',
        createdAt: 1000,
      );
      await pumpBubble(
          tester,
          MessageBubble(
            message: user,
            outputContract: contract,
          ));

      expect(find.text('结构化结果'), findsNothing);
    });
  });
}
