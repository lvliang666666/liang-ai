import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/tool_call_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  const calls = [
    ToolCall(id: 'c1', name: 'get_current_time', argumentsJson: '{}'),
    ToolCall(
        id: 'c2', name: 'calculate', argumentsJson: '{"expression":"1+1"}'),
  ];

  Widget wrap(Widget child) => ChangeNotifierProvider(
        create: (_) => ThemeProvider(settings: SettingsService(prefs)),
        child: MaterialApp(home: Scaffold(body: child)),
      );

  /// AnimatedCrossFade 折叠后子组件仍在树中（opacity 0），
  /// 用 crossFadeState 断言展开/折叠态
  CrossFadeState fadeStateOf(WidgetTester tester) =>
      tester.widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState;

  group('ToolCallBlock 三态渲染', () {
    testWidgets('执行中：旋转指示 + 默认展开显示调用行', (tester) async {
      await tester.pumpWidget(wrap(const ToolCallBlock(
        calls: calls,
        results: [],
        executing: true,
      )));
      // CircularProgressIndicator 无限动画，pumpAndSettle 会超时
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('正在调用工具…'), findsOneWidget);
      expect(fadeStateOf(tester), CrossFadeState.showFirst);
      // 默认展开：调用行可见
      expect(find.text('get_current_time'), findsOneWidget);
      expect(find.text('calculate'), findsOneWidget);
      // 结果未出：显示等待图标（schedule）
      expect(find.byIcon(Icons.schedule), findsNWidgets(2));
      // 执行中指示器
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('完成：默认折叠，点击展开看结果', (tester) async {
      final results = [
        const ToolCallResult(callId: 'c1', content: '2026-10-19 12:00'),
        const ToolCallResult(callId: 'c2', content: '1+1 = 2'),
      ];
      await tester.pumpWidget(wrap(ToolCallBlock(
        calls: calls,
        results: results,
        executing: false,
      )));
      await tester.pumpAndSettle();

      // 默认折叠
      expect(find.text('已调用工具（2 项）'), findsOneWidget);
      expect(fadeStateOf(tester), CrossFadeState.showSecond);

      // 点击展开
      await tester.tap(find.text('已调用工具（2 项）'));
      await tester.pumpAndSettle();

      expect(fadeStateOf(tester), CrossFadeState.showFirst);
      expect(find.text('get_current_time'), findsOneWidget);
      expect(find.text('calculate'), findsOneWidget);
      // 结果文本可见
      expect(find.textContaining('2026-10-19'), findsOneWidget);
      expect(find.textContaining('1+1 = 2'), findsOneWidget);
      // 成功图标
      expect(find.byIcon(Icons.check), findsNWidgets(2));
    });

    testWidgets('失败：红色调 + 失败计数 + 错误文本', (tester) async {
      final results = [
        const ToolCallResult(callId: 'c1', content: '正常结果'),
        const ToolCallResult(
            callId: 'c2', content: '工具执行失败：除数不能为零', isError: true),
      ];
      await tester.pumpWidget(wrap(ToolCallBlock(
        calls: calls,
        results: results,
        executing: false,
      )));
      await tester.pumpAndSettle();

      expect(find.text('已调用工具（1 项失败）'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      // 展开看错误详情
      await tester.tap(find.text('已调用工具（1 项失败）'));
      await tester.pumpAndSettle();

      expect(find.textContaining('除数不能为零'), findsOneWidget);
      // 失败行用 close 图标
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('执行→完成自动折叠（用户未手动操作）', (tester) async {
      await tester.pumpWidget(wrap(const ToolCallBlock(
        calls: calls,
        results: const [],
        executing: true,
      )));
      await tester.pump(const Duration(milliseconds: 300));

      // 执行中展开
      expect(fadeStateOf(tester), CrossFadeState.showFirst);

      // 完成后自动折叠
      await tester.pumpWidget(wrap(const ToolCallBlock(
        calls: calls,
        results: [
          ToolCallResult(callId: 'c1', content: 'r1'),
          ToolCallResult(callId: 'c2', content: 'r2'),
        ],
        executing: false,
      )));
      await tester.pumpAndSettle();

      expect(find.text('已调用工具（2 项）'), findsOneWidget);
      expect(fadeStateOf(tester), CrossFadeState.showSecond);
    });

    testWidgets('参数摘要显示在调用行', (tester) async {
      await tester.pumpWidget(wrap(const ToolCallBlock(
        calls: calls,
        results: [],
        executing: true,
      )));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('expression'), findsOneWidget);
    });
  });
}
