import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/pages/home_page.dart';
import 'package:ai_chat_app/providers/agent_provider.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/providers/http_tool_provider.dart';
import 'package:ai_chat_app/providers/memory_provider.dart';
import 'package:ai_chat_app/providers/provider_provider.dart';
import 'package:ai_chat_app/providers/sessions_provider.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/agent_service.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/memory_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/home/home_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 杀 app 草稿存活（问题 1 修复回归锁）：
/// - 聊天态打字防抖 800ms 落盘（旧实现只在切换/发送时机存，杀 app 必丢）
/// - 冷启动恢复空闲态草稿（旧实现只在 _newChat 退出聊天态时恢复）
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late ChatProvider provider;
  late ChatSession session;
  late SettingsService settings;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    session = ChatSession(
      id: 's1',
      title: '新对话',
      createdAt: 1000,
      updatedAt: 1000,
    );
    await db.insertSession(session);
    provider = ChatProvider(
      database: db,
      api: _NoopApi(),
      session: session,
      profile: ProviderProfile.builtinCompany(),
      model: 'glm5.1',
    );
  });

  tearDown(() async {
    provider.dispose();
    await db.deleteSession('s1');
  });

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider(create: (_) => ThemeProvider(settings: settings)),
          ChangeNotifierProvider(create: (_) => SessionsProvider(database: db)),
          ChangeNotifierProvider(create: (_) => AgentProvider(service: AgentService(database: db))),
          ChangeNotifierProvider(create: (_) => ProviderProvider(database: db)),
          ChangeNotifierProvider(create: (_) => MemoryProvider(service: MemoryService(database: db))),
          ChangeNotifierProvider(create: (_) => HttpToolProvider(database: db)),
        ],
        child: MaterialApp(home: child),
      );

  group('聊天态草稿防抖落盘（杀 app 存活）', () {
    testWidgets('聊天态输入停顿 800ms 后写入会话草稿', (tester) async {
      await tester.pumpWidget(wrap(Scaffold(
        body: HomeInputBar(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          chat: provider,
          selectedAgent: null,
          selectedModel: null,
          selectedEffort: 'max',
          onSendIdle: (_, {agentId, modelPick, attachments = const [], agentVariables = const {}}) {},
          onPickAgent: () {},
          onPickModel: () {},
          onPickEffort: () {},
        ),
      )));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '聊天中打的字');
      // 防抖 800ms 未到：不落盘
      await tester.pump(const Duration(milliseconds: 500));
      expect(settings.getDraft('s1'), '');

      // 越过防抖窗口：落盘
      await tester.pump(const Duration(milliseconds: 500));
      expect(settings.getDraft('s1'), '聊天中打的字');
    });

    testWidgets('连续输入重置防抖：只在停顿后落盘一次', (tester) async {
      await tester.pumpWidget(wrap(Scaffold(
        body: HomeInputBar(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          chat: provider,
          selectedAgent: null,
          selectedModel: null,
          selectedEffort: 'max',
          onSendIdle: (_, {agentId, modelPick, attachments = const [], agentVariables = const {}}) {},
          onPickAgent: () {},
          onPickModel: () {},
          onPickEffort: () {},
        ),
      )));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '第一段');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField), '第一段第二段');
      await tester.pump(const Duration(milliseconds: 500));
      // 第一次的防抖被重置，尚未落盘
      expect(settings.getDraft('s1'), '');

      await tester.pump(const Duration(milliseconds: 500));
      expect(settings.getDraft('s1'), '第一段第二段');
    });

    testWidgets('清空输入：防抖后草稿被清除', (tester) async {
      await settings.setDraft('s1', '旧草稿');
      await tester.pumpWidget(wrap(Scaffold(
        body: HomeInputBar(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          chat: provider,
          selectedAgent: null,
          selectedModel: null,
          selectedEffort: 'max',
          onSendIdle: (_, {agentId, modelPick, attachments = const [], agentVariables = const {}}) {},
          onPickAgent: () {},
          onPickModel: () {},
          onPickEffort: () {},
        ),
      )));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '临时内容');
      await tester.pump(const Duration(milliseconds: 900));
      expect(settings.getDraft('s1'), '临时内容');

      // 清空 → 防抖后 setDraft('') = 清除草稿
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 900));
      expect(settings.getDraft('s1'), '');
    });
  });

  group('冷启动恢复空闲草稿', () {
    // HomePage 门控：sessions.loaded 前主体是转圈，输入栏不渲染——
    // loadSessions 是真实异步 IO，runAsync 等它跑完再 pump 消费通知。
    // P2 widget 推送的 MethodChannel 在测试环境无 handler：mock 掉防
    // MissingPluginException 异步异常干扰收尾
    Future<void> pumpHome(WidgetTester tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ai_chat_app/share'),
              (call) async => null);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('ai_chat_app/share'), null);
      });
      await tester.pumpWidget(wrap(const HomePage()));
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump();
      // 清掉 P2 防抖推送的 pending Timer（500ms）
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('启动时有空闲草稿：输入框静默恢复', (tester) async {
      await settings.setIdleDraft('上次没发出去的话');
      await pumpHome(tester);

      expect(find.widgetWithText(TextField, '上次没发出去的话'), findsOneWidget,
          reason: '冷启动应静默恢复空闲态草稿');
    });

    testWidgets('启动时无空闲草稿：输入框为空', (tester) async {
      await pumpHome(tester);

      final textField = tester.widget<TextField>(find.byType(TextField).first);
      expect(textField.controller!.text, '');
    });
  });
}

/// 无操作 API（本文件不发请求）
class _NoopApi implements ApiService {
  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
