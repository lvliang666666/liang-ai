import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
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

/// HomeInputBar 编辑态（I4）/ 引用态（I5）widget 测试
///
/// 编辑态：输入框上方「正在编辑」条 + 发送走 editAndResend；
/// 引用态：输入框上方「引用」条 + 发送内容带【引用】前缀。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late ChatProvider provider;
  late SettingsService settings;
  late TextEditingController controller;
  late MockApiService api;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    controller = TextEditingController();

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
    await db.close();
  });

  ChatMessage userMsg(String id, String content, {int at = 1000}) =>
      ChatMessage(
        id: id, sessionId: 's1', role: 'user', content: content, createdAt: at);

  ChatMessage assistantMsg(String id, String content, {int at = 2000}) =>
      ChatMessage(
        id: id,
        sessionId: 's1',
        role: 'assistant',
        content: content,
        createdAt: at);

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<ThemeProvider>.value(
              value: ThemeProvider(settings: settings)),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  Future<void> pumpBar(
    WidgetTester tester, {
    ChatMessage? editing,
    ChatMessage? quoted,
  }) async {
    await tester.pumpWidget(wrap(HomeInputBar(
      controller: controller,
      focusNode: FocusNode(),
      chat: provider,
      selectedAgent: null,
      selectedModel: null,
      selectedEffort: 'max',
      onSendIdle: (_, {agentId, modelPick, attachments = const []}) {},
      onPickAgent: () {},
      onPickModel: () {},
      onPickEffort: () {},
      editingMessage: editing,
      onCancelEdit: () {},
      quotedMessage: quoted,
      onCancelQuote: () {},
    )));
    await tester.pump();
  }

  group('I4 编辑态', () {
    testWidgets('编辑态显示「正在编辑」条与原文预览', (tester) async {
      await pumpBar(tester,
          editing: userMsg('u1', '原始的问题'));
      expect(find.text('正在编辑'), findsOneWidget);
      expect(find.text('原始的问题'), findsOneWidget);
    });

    testWidgets('编辑态无文字也有发送键（发送 = 重发原文）', (tester) async {
      await pumpBar(tester, editing: userMsg('u1', '原始的问题'));
      // 发送键是 arrow_upward 图标的 IconButton.filled
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    });

    testWidgets('非编辑态无「正在编辑」条', (tester) async {
      await pumpBar(tester);
      expect(find.text('正在编辑'), findsNothing);
    });
  });

  group('I5 引用态', () {
    testWidgets('引用态显示「引用」条与原文缩略', (tester) async {
      await pumpBar(tester,
          quoted: assistantMsg('a1', '这是一段很长的回答内容用来验证引用条显示'));
      expect(find.text('引用'), findsOneWidget);
      expect(find.textContaining('这是一段很长的回答'), findsOneWidget);
    });

    testWidgets('非引用态无「引用」条', (tester) async {
      await pumpBar(tester);
      expect(find.text('引用'), findsNothing);
    });

    testWidgets('发送时引用内容以【引用】前缀拼进消息（纯文本方案）', (tester) async {
      // DB 种子同样是真实 IO：必须 runAsync（fakeAsync 区永不完成 → 超时）
      await tester.runAsync(() async {
        await db.insertMessage(assistantMsg('a1', '被引用的回答'));
        await provider.loadMessages();
      });
      await pumpBar(tester, quoted: provider.messages.first);

      await tester.enterText(find.byType(TextField), '展开讲讲');
      await tester.pump(); // onChanged → setState → 发送键出现
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      // runAsync：sendMessage 内部真实 DB IO（sqflite_ffi）与 loop 推进
      // 都需要真实事件循环；fakeAsync 区推不动会永久悬挂
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        api.emitDone(); // 结束流式
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      // DB 读同样是真实 IO：必须 runAsync（fakeAsync 区永不完成 → 超时）
      final msgs = await tester.runAsync(() => db.getMessages('s1'));
      final sent = msgs!.lastWhere((m) => m.role == 'user');
      expect(sent.content, '【引用】被引用的回答\n\n展开讲讲');
    });

    testWidgets('无引用时发送内容不带前缀', (tester) async {
      await pumpBar(tester);

      await tester.enterText(find.byType(TextField), '普通问题');
      await tester.pump(); // onChanged → setState → 发送键出现
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        api.emitDone();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      final msgs = await tester.runAsync(() => db.getMessages('s1'));
      final sent = msgs!.lastWhere((m) => m.role == 'user');
      expect(sent.content, '普通问题');
    });
  });
}
