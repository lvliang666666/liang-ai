import 'dart:async';

import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/widgets/home/home_input_bar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock（widget 测试 fakeAsync 区禁真实网络 IO）
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();

  void emitDone() => _controller.add(const SseDone());

  @override
  Stream<SseEvent> chatStream({
    required ProviderProfile profile,
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required CancelToken cancelToken,
    double temperature = 0.7,
    List<Map<String, Object?>>? tools,
  }) =>
      _controller.stream;

  @override
  void dispose() {}
}

/// HomeInputBar 斜杠面板触发行为（v2.16.1 验收反馈）
///
/// ① 边沿触发：只在「无 / → 有 /」跳变时弹面板——删除时每删一个 /
/// 都重弹一次是电平触发的 bug；② 弹面板前先收键盘（unfocus）——
/// 否则面板先顶到键盘上沿、键盘收起后面板回落一截（弹出又回退）。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late ChatProvider provider;
  late SettingsService settings;
  late TextEditingController controller;
  late FocusNode focusNode;
  late MockApiService api;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    controller = TextEditingController();
    focusNode = FocusNode();

    final session = ChatSession(
        id: 's1', title: '测试会话', createdAt: 1000, updatedAt: 1000);
    await db.insertSession(session);
    api = MockApiService();
    provider = ChatProvider(
      database: db,
      api: api,
      session: session,
      profile: ProviderProfile.builtinCompany(),
      model: 'glm5.1',
    );
    await provider.loadMessages();
  });

  tearDown(() async {
    provider.dispose();
    controller.dispose();
    focusNode.dispose();
    await db.close();
  });

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
      chat: provider,
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

  /// 面板是否已弹出（「快捷短语」标题可见）
  bool sheetOpen(WidgetTester tester) =>
      find.text('快捷短语').evaluate().isNotEmpty;

  group('斜杠面板边沿触发', () {
    testWidgets('输入 / 弹出面板', (tester) async {
      await pumpBar(tester);
      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();

      expect(sheetOpen(tester), isTrue);
    });

    testWidgets('面板打开后继续输入筛选词不重弹（单例面板）', (tester) async {
      await pumpBar(tester);
      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();
      final barrierCount =
          find.byType(ModalBarrier, skipOffstage: false).evaluate().length;

      // 面板开着时继续输入（筛选词）——不应再叠一层面板。
      // 注意：面板路由持有焦点，enterText 需直接改 controller 绕过
      // showKeyboard 的「唯一 EditableText」断言。
      controller.text = '/周';
      await tester.pumpAndSettle();

      expect(find.text('快捷短语'), findsOneWidget,
          reason: '面板不应重复弹出');
      expect(
          find.byType(ModalBarrier, skipOffstage: false)
              .evaluate()
              .length,
          barrierCount,
          reason: '路由栈不应新增面板');
    });

    testWidgets('删除时每删一个 / 不重弹（验收反馈 ②）', (tester) async {
      await pumpBar(tester);

      // 输入 ///（电平触发会连弹 3 次）
      await tester.enterText(find.byType(TextField), '///');
      await tester.pumpAndSettle();
      expect(sheetOpen(tester), isTrue);
      final sheetCount = find.text('快捷短语').evaluate().length;
      expect(sheetCount, 1);

      // 关闭面板（点遮罩）
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(sheetOpen(tester), isFalse);

      // 删到 //：仍以 / 开头，但「有 → 有」无跳变，不应重弹
      await tester.enterText(find.byType(TextField), '//');
      await tester.pumpAndSettle();
      expect(sheetOpen(tester), isFalse,
          reason: '删除后仍以 / 开头不应重弹面板');

      // 删到 /：同理不弹
      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();
      expect(sheetOpen(tester), isFalse);

      // 删到空：无 /，不弹
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(sheetOpen(tester), isFalse);

      // 再输入 /：「无 → 有」跳变，重新弹出
      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();
      expect(sheetOpen(tester), isTrue, reason: '重新输入 / 应再次弹出');
    });

    testWidgets('非 / 开头的普通输入不弹面板', (tester) async {
      await pumpBar(tester);
      await tester.enterText(find.byType(TextField), '普通问题');
      await tester.pumpAndSettle();

      expect(sheetOpen(tester), isFalse);
    });

    testWidgets('中间含 / 但非开头的文本不弹', (tester) async {
      await pumpBar(tester);
      await tester.enterText(find.byType(TextField), '路径 /usr/bin');
      await tester.pumpAndSettle();

      expect(sheetOpen(tester), isFalse);
    });
  });

  group('弹面板前收键盘', () {
    testWidgets('输入 / 后焦点被移除（键盘收起，面板不回落）', (tester) async {
      await pumpBar(tester);
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();

      expect(focusNode.hasFocus, isFalse,
          reason: '弹面板前应 unfocus 收键盘，避免面板先顶键盘再回落');
      expect(sheetOpen(tester), isTrue);
    });
  });

  group('选短语后的边沿状态', () {
    testWidgets('选短语填入后（无 / 前缀），再删字符不弹面板', (tester) async {
      await settings.addSlashPhrase('帮我写周报');
      await pumpBar(tester);

      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();
      expect(sheetOpen(tester), isTrue);

      // 点短语 → 面板 pop，输入框替换为短语（无 / 前缀）
      await tester.tap(find.byKey(const ValueKey('slash-phrase-帮我写周报')));
      await tester.pumpAndSettle();
      expect(controller.text, '帮我写周报');
      expect(sheetOpen(tester), isFalse);

      // 删一个字符：无 / 前缀，不弹
      await tester.enterText(find.byType(TextField), '帮我写周');
      await tester.pumpAndSettle();
      expect(sheetOpen(tester), isFalse);
    });
  });
}
