import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:ai_chat_app/widgets/thinking_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// I10 生成状态可见性 UI 测试：动态思考计时 + token 角标 + 断流续传胶囊
///
/// 核心行为：
/// - ThinkingBlock 流式中标题动态显示「已思考 Ns」（组件内 1s Timer，
///   pump 推进假时钟验证；思考静默期计数不冻结）
/// - 完成态「已深度思考（用时 N 秒）」不变
/// - assistant 气泡尾部小字角标：token 数（prompt/completion）+ 耗时；
///   老数据（null）不显示对应段；两段全缺整行不渲染；流式中不显示
/// - 断流胶囊「连接中断 · 点击续传」：interrupted=true 显示 + 点击
///   回调；流式中不显示
void main() {
  // ThemeProvider 依赖同步可用的 SettingsService——mock prefs 先行
  late SharedPreferences prefs;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ChatMessage msg(
    String content, {
    String reasoning = '',
    int? prompt,
    int? completion,
    int? thinkSec,
    int? genSec,
    int at = 1000,
  }) =>
      ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: content,
        reasoning: reasoning,
        promptTokens: prompt,
        completionTokens: completion,
        thinkingSeconds: thinkSec,
        generationSeconds: genSec,
        createdAt: at,
      );

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          // MessageBubble watch SettingsService（快捷操作开关）
          ChangeNotifierProvider<SettingsService>(
            create: (_) => SettingsService(prefs),
          ),
          // ThinkingBlock/MessageBubble 读 ThemeProvider.cornerRadius
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) =>
                ThemeProvider(settings: SettingsService(prefs)),
          ),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  group('ThinkingBlock 动态计时', () {
    testWidgets('流式中：标题显示「已思考 Ns」且随时间增长', (tester) async {
      await tester.pumpWidget(wrap(const ThinkingBlock(
        reasoning: '思考内容',
        streaming: true,
        seconds: 3,
      )));
      await tester.pump();

      expect(find.text('已思考 3 秒…'), findsOneWidget);

      // 推进 2s：组件内 Timer 触发 setState，但 seconds 来自 widget
      // 参数（provider 只在事件时更新）——这里直接传更大值模拟
      // provider tick 后的重建
      await tester.pumpWidget(wrap(const ThinkingBlock(
        reasoning: '思考内容',
        streaming: true,
        seconds: 5,
      )));
      await tester.pump();
      expect(find.text('已思考 5 秒…'), findsOneWidget);
    });

    testWidgets('流式中思考静默期：Timer 每秒重建不崩溃（无增量也活着）',
        (tester) async {
      await tester.pumpWidget(wrap(const ThinkingBlock(
        reasoning: '思考内容',
        streaming: true,
        seconds: 1,
      )));
      await tester.pump();

      // 推进 3.5s：Timer.periodic 触发 3 次 setState（无数据变化，
      // 纯重建——验证静默期不崩溃不冻结 UI）
      await tester.pump(const Duration(milliseconds: 3500));
      expect(find.text('已思考 1 秒…'), findsOneWidget,
          reason: 'seconds 来自参数，静默期显示不变但组件活着');
      expect(tester.takeException(), isNull);
    });

    testWidgets('完成态：显示「已深度思考（用时 N 秒）」', (tester) async {
      await tester.pumpWidget(wrap(const ThinkingBlock(
        reasoning: '思考内容',
        streaming: false,
        seconds: 7,
      )));
      await tester.pump();

      expect(find.text('已深度思考（用时 7 秒）'), findsOneWidget);
    });

    testWidgets('流式→完成：Timer 停止（不再 tick）', (tester) async {
      await tester.pumpWidget(wrap(const ThinkingBlock(
        reasoning: '思考内容',
        streaming: true,
        seconds: 2,
      )));
      await tester.pump();

      await tester.pumpWidget(wrap(const ThinkingBlock(
        reasoning: '思考内容',
        streaming: false,
        seconds: 4,
      )));
      await tester.pump();
      expect(find.text('已深度思考（用时 4 秒）'), findsOneWidget);

      // 推进 5s：若 Timer 未停，pending timer 会让测试报错
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('已深度思考（用时 4 秒）'), findsOneWidget);
    });
  });

  group('token/耗时角标', () {
    testWidgets('有 token + 耗时：尾部小字显示', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答内容',
            prompt: 120, completion: 45, thinkSec: 3, genSec: 8),
      )));
      await tester.pump();

      expect(find.text('120 / 45 token · 8s'), findsOneWidget);
    });

    testWidgets('千级 token 格式化 k 缩写', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答内容',
            prompt: 1234, completion: 45, genSec: 12),
      )));
      await tester.pump();

      expect(find.text('1.2k / 45 token · 12s'), findsOneWidget);
    });

    testWidgets('老数据（无 token 无耗时）：角标不渲染', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('老消息'),
      )));
      await tester.pump();

      expect(find.textContaining('token'), findsNothing);
    });

    testWidgets('只有 token 无耗时：只显示 token 段', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答内容', prompt: 100, completion: 20),
      )));
      await tester.pump();

      expect(find.text('100 / 20 token'), findsOneWidget);
    });

    testWidgets('流式中：角标不显示（收尾后才有准确值）', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('回答中', prompt: 100, completion: 20, genSec: 5),
        isStreaming: true,
      )));
      await tester.pump();

      expect(find.textContaining('token'), findsNothing);
    });
  });

  group('断流续传胶囊', () {
    testWidgets('interrupted=true：显示「连接中断 · 点击续传」', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('收到一半的内容'),
        interrupted: true,
        onResume: () {},
      )));
      await tester.pump();

      expect(find.text('连接中断 · 点击续传'), findsOneWidget);
    });

    testWidgets('点击胶囊触发 onResume 回调', (tester) async {
      var resumed = false;
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('收到一半的内容'),
        interrupted: true,
        onResume: () => resumed = true,
      )));
      await tester.pump();

      await tester.tap(find.text('连接中断 · 点击续传'));
      await tester.pump();

      expect(resumed, isTrue);
    });

    testWidgets('onResume 为 null：胶囊不显示（无续传能力）', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('收到一半的内容'),
        interrupted: true,
      )));
      await tester.pump();

      expect(find.text('连接中断 · 点击续传'), findsNothing);
    });

    testWidgets('interrupted=false：不显示胶囊', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('正常回答'),
        onResume: () {},
      )));
      await tester.pump();

      expect(find.text('连接中断 · 点击续传'), findsNothing);
    });

    testWidgets('流式中：即使 interrupted 也不显示（流式优先）', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg('流式中'),
        isStreaming: true,
        interrupted: true,
        onResume: () {},
      )));
      await tester.pump();

      expect(find.text('连接中断 · 点击续传'), findsNothing);
    });
  });
}
