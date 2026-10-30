import 'dart:async';

import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/services/skill_variables.dart';
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

/// F10 agent tag 长按 = 重开变量/预设配置表单
///
/// ① 聊天态：确认写入 ChatProvider（变量 + 预设名回显）
/// ② 空闲态：确认经 onIdleAgentVariables 回传主页暂存
/// ③ 无变量无预设的 agent：长按入口不出现（onLongPress == null）
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late ChatProvider provider;
  late SettingsService settings;
  late TextEditingController controller;
  late FocusNode focusNode;
  late MockApiService api;

  final agent = Agent(
    id: 'a1',
    name: '周报助手',
    icon: '📊',
    prompt: '你是{{tone}}的写手，今天{{date}}',
    personas: const [
      SkillPersona('正式', '正式商务'),
      SkillPersona('轻松', '轻松口语'),
    ],
  );

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
    await provider.setAgent(agent, variables: {'tone': '幽默'});
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

  Future<void> pumpBar(
    WidgetTester tester, {
    ChatProvider? chat,
    Agent? selectedAgent,
    Map<String, String>? agentVariables,
    ValueChanged<Map<String, String>>? onIdleAgentVariables,
  }) async {
    await tester.pumpWidget(wrap(HomeInputBar(
      controller: controller,
      focusNode: focusNode,
      chat: chat,
      selectedAgent: selectedAgent,
      selectedModel: null,
      selectedEffort: 'max',
      onSendIdle: (_, {agentId, modelPick, attachments = const [], agentVariables = const {}}) {},
      onPickAgent: () {},
      onPickModel: () {},
      onPickEffort: () {},
      agentVariables: agentVariables,
      onIdleAgentVariables: onIdleAgentVariables,
    )));
    await tester.pump();
  }

  testWidgets('聊天态长按 agent tag：确认后写入 provider（变量+预设名）', (tester) async {
    await pumpBar(tester, chat: provider);

    // 长按 agent tag（显示「周报助手」）
    await tester.longPress(find.text('周报助手'));
    await tester.pumpAndSettle();

    // 表单弹出，预填上次值
    expect(find.text('配置「周报助手」'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'tone'), findsOneWidget);
    expect(find.text('幽默'), findsOneWidget);

    // 改值 + 选预设 + 确认
    await tester.enterText(find.widgetWithText(TextField, 'tone'), '严谨');
    await tester.ensureVisible(find.text('正式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正式'));
    await tester.pump();
    await tester.ensureVisible(find.text('开始对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();

    // 写入 provider：变量更新 + 预设名回显
    expect(provider.agentVariables['tone'], '严谨');
    expect(provider.agentVariables['persona'], '正式商务');
    expect(provider.activePersonaName, '正式');
  });

  testWidgets('聊天态长按取消（点遮罩）：provider 保持原值', (tester) async {
    await pumpBar(tester, chat: provider);

    await tester.longPress(find.text('周报助手'));
    await tester.pumpAndSettle();

    // 点遮罩关闭（sheet 外区域）
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(provider.agentVariables['tone'], '幽默'); // 原值未动
    expect(find.text('配置「周报助手」'), findsNothing);
  });

  testWidgets('空闲态长按 agent tag：确认经回调回传', (tester) async {
    Map<String, String>? received;
    await pumpBar(
      tester,
      selectedAgent: agent,
      agentVariables: const {'tone': '初值'},
      onIdleAgentVariables: (v) => received = v,
    );

    await tester.longPress(find.text('周报助手'));
    await tester.pumpAndSettle();

    expect(find.text('配置「周报助手」'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'tone'), '新值');
    await tester.ensureVisible(find.text('开始对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();

    expect(received, isNotNull);
    expect(received!['tone'], '新值');
  });

  testWidgets('无变量无预设的 agent：长按不弹表单', (tester) async {
    // 空闲态验证（testWidgets 区禁真实 DB IO，不能在用例内 setAgent）
    final plain = Agent(
        id: 'a2', name: '翻译', icon: '🌐', prompt: '翻译成英文');
    await pumpBar(tester, selectedAgent: plain);

    // 长按不弹表单（onLongPress == null，InkWell 无响应）
    await tester.longPress(find.text('翻译'));
    await tester.pumpAndSettle();
    expect(find.text('配置「翻译」'), findsNothing);
  });
}
