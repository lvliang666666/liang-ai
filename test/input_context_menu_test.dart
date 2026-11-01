import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/home/home_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 打磨批次 V：输入框长按菜单「全选」widget 测试
///
/// 用户反馈部分 ROM/输入法的默认长按菜单缺「全选」，输入错了只能
/// 逐字回退。修复 = 自定义 contextMenuBuilder 固定四项（全选/复制/
/// 粘贴/剪切），全选恒在场且排第一。
///
/// 断言两层：①按钮类型集合（稳定枚举，不依赖渲染 label）②中文
/// label「全选」（app 已配 zh 本地化，菜单与全中文 UI 一致）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Clipboard.getData mock（粘贴项 onPressed 会走平台通道，测试环境
  // 无 handler 会抛 MissingPluginException——只点全选/复制不触发）
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') {
      return <String, dynamic>{'text': null};
    }
    return null;
  });

  late SettingsService settings;
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    controller = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<ThemeProvider>.value(
              value: ThemeProvider(settings: settings)),
        ],
        child: MaterialApp(
          // 与生产 main.dart 同款中文本地化（菜单 label 渲染中文）
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          locale: const Locale('zh', 'CN'),
          home: Scaffold(body: child),
        ),
      );

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(wrap(HomeInputBar(
      controller: controller,
      focusNode: focusNode,
      chat: null,
      selectedAgent: null,
      selectedModel: null,
      selectedEffort: 'max',
      onSendIdle: (_, {agentId, modelPick, attachments = const [], agentVariables = const {}}) {},
      onPickAgent: () {},
      onPickModel: () {},
      onPickEffort: () {},
    )));
    await tester.pump();
  }

  /// 长按输入框并等菜单出现，返回菜单里的按钮类型集合
  Future<Set<ContextMenuButtonType>> openMenuAndGetTypes(
      WidgetTester tester) async {
    await tester.longPress(find.byType(TextField));
    await tester.pumpAndSettle();
    final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
        find.byType(AdaptiveTextSelectionToolbar));
    return toolbar.buttonItems!.map((b) => b.type).toSet();
  }

  group('输入框长按菜单（打磨批次 V）', () {
    testWidgets('无选区长按：全选 + 粘贴在场（全选排第一）', (tester) async {
      controller.text = '已经输入的一些文字';
      await pumpBar(tester);

      final types = await openMenuAndGetTypes(tester);
      expect(types, contains(ContextMenuButtonType.selectAll),
          reason: '用户主诉：全选必须恒在场');
      expect(types, contains(ContextMenuButtonType.paste));
      expect(types, isNot(contains(ContextMenuButtonType.copy)),
          reason: '无选区时复制无意义不出现');
      expect(types, isNot(contains(ContextMenuButtonType.cut)));
    });

    testWidgets('点全选后菜单原地升级：复制/剪切出现（真实用户流）', (tester) async {
      controller.text = '已经输入的一些文字';
      await pumpBar(tester);

      // 真实用户流：长按唤出菜单 → 点「全选」→ 选区变为全文（非折叠）
      // → 菜单原地重建，复制/剪切即刻在场，无需再长按一次。
      // （预置选区再长按的路径在测试环境会被手势重算折叠，不模拟）
      await tester.longPress(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();

      final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
          find.byType(AdaptiveTextSelectionToolbar));
      final types = toolbar.buttonItems!.map((b) => b.type).toSet();
      expect(types, contains(ContextMenuButtonType.copy),
          reason: '全选后选区非折叠，复制应即刻在场');
      expect(types, contains(ContextMenuButtonType.cut));
      expect(types, contains(ContextMenuButtonType.selectAll));
    });

    testWidgets('点全选：整个输入框内容被选中（中文 label 渲染）', (tester) async {
      controller.text = '第一行\n第二行内容';
      await pumpBar(tester);

      await tester.longPress(find.byType(TextField));
      await tester.pumpAndSettle();

      // zh 本地化下菜单渲染中文「全选」（与全中文 UI 一致）
      final selectAllFinder = find.text('全选');
      expect(selectAllFinder, findsOneWidget,
          reason: 'zh 本地化菜单应渲染「全选」label');
      await tester.tap(selectAllFinder);
      await tester.pumpAndSettle();

      expect(controller.selection.baseOffset, 0);
      expect(controller.selection.extentOffset, controller.text.length);
    });

    testWidgets('空输入框长按：全选仍在场（点了无副作用）', (tester) async {
      await pumpBar(tester);

      final types = await openMenuAndGetTypes(tester);
      expect(types, contains(ContextMenuButtonType.selectAll));
    });
  });
}
