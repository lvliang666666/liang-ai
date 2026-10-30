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
import 'package:ai_chat_app/widgets/home/chat_message_list.dart';
import 'package:ai_chat_app/widgets/home/home_input_bar.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock（F6 双答按调用序号分流，同 chat_provider_test）
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();
  int chatStreamCalls = 0;
  final List<List<SseEvent>> scriptsByCall = [];
  final List<StreamController<SseEvent>> _scriptControllers = [];

  void emit(SseEvent event) => _controller.add(event);

  int get scriptControllerCount => _scriptControllers.length;

  @override
  Stream<SseEvent> chatStream({
    required ProviderProfile profile,
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required CancelToken cancelToken,
    double temperature = 0.7,
    List<Map<String, Object?>>? tools,
  }) {
    final callIndex = chatStreamCalls;
    chatStreamCalls++;
    if (callIndex < scriptsByCall.length) {
      final c = StreamController<SseEvent>.broadcast();
      _scriptControllers.add(c);
      scheduleMicrotask(() {
        for (final e in scriptsByCall[callIndex]) {
          c.add(e);
        }
      });
      return c.stream;
    }
    return _controller.stream;
  }

  @override
  void dispose() {}
}

/// F6 同问双答 UI 测试：来源徽标 + 「用这个继续」按钮 + 双答 tag
///
/// 引擎行为（双流/选择/切换）已在 chat_provider_test 覆盖；这里验证
/// 渲染接线——徽标随 sourceLabel 显示、按钮随 dualOf 显隐、tag 随
/// 双答状态切换、点击回调透传到宿主。
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
      dualApiFactory: (profile) => api,
    );
    await provider.loadMessages();
  });

  tearDown(() async {
    provider.dispose();
    controller.dispose();
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

  /// 种子一对互指的双答消息（待选择态）并刷新 provider
  Future<void> seedDualPair() async {
    await db.insertMessage(ChatMessage(
      id: 'u1',
      sessionId: 's1',
      role: 'user',
      content: '同一个问题',
      createdAt: 1000,
    ));
    await db.insertMessage(ChatMessage(
      id: 'a-left',
      sessionId: 's1',
      role: 'assistant',
      content: '主侧回答',
      dualOf: 'a-right',
      sourceLabel: '公司 GLM · glm5.1',
      createdAt: 2000,
    ));
    await db.insertMessage(ChatMessage(
      id: 'a-right',
      sessionId: 's1',
      role: 'assistant',
      content: '对侧回答',
      dualOf: 'a-left',
      sourceLabel: 'DeepSeek · deepseek-chat',
      createdAt: 2001,
    ));
    await provider.loadMessages();
  }

  group('MessageBubble 双答渲染', () {
    testWidgets('来源徽标：sourceLabel 非空显示，null 不显示', (tester) async {
      await tester.pumpWidget(wrap(Column(children: [
        MessageBubble(
          message: ChatMessage(
            id: 'a1',
            sessionId: 's1',
            role: 'assistant',
            content: '带徽标',
            sourceLabel: '公司 GLM · glm5.1',
            createdAt: 1000,
          ),
        ),
        MessageBubble(
          message: ChatMessage(
            id: 'a2',
            sessionId: 's1',
            role: 'assistant',
            content: '无徽标',
            createdAt: 1001,
          ),
        ),
      ])));
      expect(find.text('公司 GLM · glm5.1'), findsOneWidget);
      // 无徽标消息只有正文，无徽标文本
      expect(find.text('无徽标'), findsOneWidget);
    });

    testWidgets('「用这个继续」按钮：dualOf 非空且有回调时显示，点击触发',
        (tester) async {
      var chosen = 0;
      await tester.pumpWidget(wrap(MessageBubble(
        message: ChatMessage(
          id: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '待选择的回答',
          dualOf: 'a2',
          createdAt: 1000,
        ),
        onChooseDual: () => chosen++,
      )));
      expect(find.text('用这个继续'), findsOneWidget);

      await tester.tap(find.text('用这个继续'));
      expect(chosen, 1);
    });

    testWidgets('普通消息（dualOf null）无「用这个继续」按钮', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: ChatMessage(
          id: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '普通回答',
          createdAt: 1000,
        ),
        onChooseDual: () {},
      )));
      expect(find.text('用这个继续'), findsNothing);
    });

    testWidgets('无回调（onChooseDual null）时按钮不显示', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: ChatMessage(
          id: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '待选择的回答',
          dualOf: 'a2',
          createdAt: 1000,
        ),
      )));
      expect(find.text('用这个继续'), findsNothing);
    });
  });

  group('ChatMessageList 双答接线', () {
    testWidgets('待选择态：两条双答气泡都显示「用这个继续」，点击回调带消息',
        (tester) async {
      await tester.runAsync(seedDualPair);
      ChatMessage? chosen;
      await tester.pumpWidget(wrap(ChatMessageList(
        chatKey: const ValueKey('chat'),
        chat: provider,
        onDelete: () {},
        onChooseDualMessage: (m) => chosen = m,
      )));
      await tester.pump();

      expect(find.text('主侧回答'), findsOneWidget);
      expect(find.text('对侧回答'), findsOneWidget);
      expect(find.byIcon(Icons.verified_outlined), findsNWidgets(2));
      expect(find.text('用这个继续'), findsNWidgets(2));

      // 点对侧（DeepSeek）气泡内的按钮：回调带回该消息
      // （reverse 列表树序与视觉序相反，按气泡定位而非 .last）
      final rightBubble = find.ancestor(
        of: find.text('对侧回答'),
        matching: find.byType(MessageBubble),
      );
      await tester
          .tap(find.descendant(of: rightBubble, matching: find.text('用这个继续')));
      expect(chosen?.id, 'a-right');
    });

    testWidgets('选择后（chooseDual 已执行）：单线消息无按钮', (tester) async {
      await tester.runAsync(seedDualPair);
      await tester.pumpWidget(wrap(ChatMessageList(
        chatKey: const ValueKey('chat'),
        chat: provider,
        onDelete: () {},
        onChooseDualMessage: (_) {},
      )));
      await tester.pump();
      expect(find.text('用这个继续'), findsNWidgets(2));

      // 宿主执行选择（直接调 provider，模拟 home_page 管线）：
      // chooseDual(keep) 删除姊妹、保留 keep——这里保留对侧（a-right）
      await tester.runAsync(() async {
        final msgs = await db.getMessages('s1');
        await provider.chooseDual(msgs[2]);
      });
      await tester.pump();

      expect(find.text('主侧回答'), findsNothing);
      expect(find.text('用这个继续'), findsNothing);
      expect(find.text('对侧回答'), findsOneWidget);
    });
  });

  group('HomeInputBar 双答 tag', () {
    Future<void> pumpBar(WidgetTester tester,
        {VoidCallback? onPickDual}) async {
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
        onPickDual: onPickDual,
      )));
      await tester.pump();
    }

    testWidgets('聊天态显示「双答」tag，点击触发回调', (tester) async {
      var picked = false;
      await pumpBar(tester, onPickDual: () => picked = true);
      expect(find.text('双答'), findsOneWidget);

      await tester.tap(find.text('双答'));
      expect(picked, isTrue);
    });

    testWidgets('无回调（onPickDual null）时 tag 不显示', (tester) async {
      await pumpBar(tester);
      expect(find.text('双答'), findsNothing);
    });

    testWidgets('待选择态隐藏双答 tag（选择走气泡按钮）', (tester) async {
      await tester.runAsync(seedDualPair);
      await pumpBar(tester, onPickDual: () {});
      expect(find.text('双答'), findsNothing);
    });

    testWidgets('双答进行中显示「双答中…」且点击不触发回调', (tester) async {
      await tester.runAsync(() async {
        api.scriptsByCall
          ..add([const SseDeltaContent('主侧')])
          ..add([const SseDeltaContent('对侧')]);
        // 不 await：双流无收尾事件，sendDualMessage 挂起到测试结束
        unawaited(provider.sendDualMessage('问题'));
        // 等两侧脚本流订阅建立（isDualRunning 置位）
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (api.scriptControllerCount < 2) {
          if (DateTime.now().isAfter(deadline)) fail('双答未启动');
          await Future.delayed(const Duration(milliseconds: 5));
        }
      });
      var picked = false;
      await pumpBar(tester, onPickDual: () => picked = true);
      expect(find.text('双答中…'), findsOneWidget);

      await tester.tap(find.text('双答中…'));
      expect(picked, isFalse, reason: '双答进行中禁点');
    });
  });
}
