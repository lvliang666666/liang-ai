import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/home/home_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// F9 剪贴板长文本胶囊 widget 测试
///
/// 触发链路：输入框聚焦 → 读剪贴板 → ≥200 字且未提示过 → 浮出胶囊。
/// 剪贴板经 TestDefaultBinaryMessenger mock（widget 测试无系统剪贴板）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Clipboard.getData 走 SystemChannels.platform（JSONMethodCodec！）。
  // 必须用 SystemChannels.platform 常量 mock——自建 MethodChannel('flutter/platform')
  // 默认 StandardMethodCodec，编码不匹配会让所有框架内部平台调用报 Message corrupted
  late final platform = SystemChannels.platform;

  late DatabaseService db;
  late SettingsService settings;
  late TextEditingController controller;
  late FocusNode focusNode;
  String? clipboardContent;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    controller = TextEditingController();
    focusNode = FocusNode();
    clipboardContent = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return clipboardContent == null
            ? <String, dynamic>{'text': null}
            : <String, dynamic>{'text': clipboardContent};
      }
      // 其余框架内部消息：返回各自类型的空值（不抛 Message corrupted）
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, null);
    controller.dispose();
    focusNode.dispose();
    await db.close();
  });

  /// 生成 n 字的长文本
  String longText(int n) => '这是一段用于测试剪贴板建议功能的超长文本。' * (n ~/ 22 + 1);

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<ThemeProvider>.value(
              value: ThemeProvider(settings: settings)),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(wrap(HomeInputBar(
      controller: controller,
      focusNode: focusNode,
      chat: null,
      selectedAgent: null,
      selectedModel: null,
      selectedEffort: 'max',
      onSendIdle: (_, {agentId, modelPick, attachments = const []}) {},
      onPickAgent: () {},
      onPickModel: () {},
      onPickEffort: () {},
    )));
    await tester.pump();
  }

  /// 聚焦并等剪贴板检测完成（异步 Clipboard.getData）
  Future<void> focusAndWait(WidgetTester tester) async {
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
  }

  group('剪贴板胶囊显隐', () {
    testWidgets('剪贴板长文本 + 聚焦 → 显示「帮你总结？」胶囊', (tester) async {
      clipboardContent = longText(300);
      await pumpBar(tester);
      await focusAndWait(tester);
      expect(find.text('帮你总结？'), findsOneWidget);
    });

    testWidgets('剪贴板短文本（<200 字）不显示', (tester) async {
      clipboardContent = '短文本，不用提示';
      await pumpBar(tester);
      await focusAndWait(tester);
      expect(find.text('帮你总结？'), findsNothing);
    });

    testWidgets('剪贴板为空不显示', (tester) async {
      clipboardContent = null;
      await pumpBar(tester);
      await focusAndWait(tester);
      expect(find.text('帮你总结？'), findsNothing);
    });

    testWidgets('开关关闭不显示', (tester) async {
      await settings.setClipboardSuggestion(false);
      clipboardContent = longText(300);
      await pumpBar(tester);
      await focusAndWait(tester);
      expect(find.text('帮你总结？'), findsNothing);
    });

    testWidgets('输入框已有内容时不打扰', (tester) async {
      clipboardContent = longText(300);
      controller.text = '用户正在输入的内容';
      await pumpBar(tester);
      await focusAndWait(tester);
      expect(find.text('帮你总结？'), findsNothing);
    });
  });

  group('剪贴板胶囊交互', () {
    testWidgets('点击「帮你总结？」→ 全文预填输入框，胶囊消失', (tester) async {
      final text = longText(300);
      clipboardContent = text;
      await pumpBar(tester);
      await focusAndWait(tester);
      expect(find.text('帮你总结？'), findsOneWidget);

      await tester.tap(find.text('帮你总结？'));
      await tester.pump();
      expect(controller.text, text);
      expect(controller.selection.baseOffset, text.length);
      expect(find.text('帮你总结？'), findsNothing);
    });

    testWidgets('点 × 关闭后同段内容不再提示', (tester) async {
      clipboardContent = longText(300);
      await pumpBar(tester);
      await focusAndWait(tester);
      expect(find.text('帮你总结？'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭'));
      await tester.pump();
      expect(find.text('帮你总结？'), findsNothing);

      // 失焦再聚焦：同段内容不重弹
      focusNode.unfocus();
      await tester.pump();
      await focusAndWait(tester);
      expect(find.text('帮你总结？'), findsNothing);
    });

    testWidgets('胶囊显示剪贴板首行缩略', (tester) async {
      clipboardContent = '${'首行内容摘要。' * 30}\n第二行\n第三行';
      await pumpBar(tester);
      await focusAndWait(tester);
      // 首行出现在胶囊里（长文本被 ellipsis 截断，用 contains 语义找前缀）
      expect(find.textContaining('首行内容摘要'), findsOneWidget);
      // 第二行不出现（只显示首行）
      expect(find.textContaining('第二行'), findsNothing);
    });
  });
}
