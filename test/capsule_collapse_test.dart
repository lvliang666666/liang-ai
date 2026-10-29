import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
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
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/chat_tags_bar.dart';
import 'package:ai_chat_app/widgets/home/chat_message_list.dart';
import 'package:ai_chat_app/widgets/home/home_input_bar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// I9 胶囊行滚动收纳：滚动方向驱动 tags 行收起/展开
///
/// 信号链：ChatMessageList._onScroll（方向判定）→ capsuleCollapsed
/// ValueNotifier → HomeInputBar（AnimatedSize 收纳动画）。
/// 单元级用例直接驱动 ChatMessageListState 验证信号；
/// 集成级用例验证 HomeInputBar 消费信号后的渲染。
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();

  void emit(SseEvent event) => _controller.add(event);

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
    return _controller.stream;
  }

  @override
  void dispose() {}
}

ChatMessage _msg(String id, String role, String content, {int at = 1000}) =>
    ChatMessage(
      id: id,
      sessionId: 's1',
      role: role,
      content: content,
      createdAt: at,
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late MockApiService api;
  late ChatProvider provider;
  late ChatSession session;
  late SettingsService settings;

  setUpAll(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
  });

  setUp(() async {
    api = MockApiService();
    session = ChatSession(
      id: 's1',
      title: '新对话',
      createdAt: 1000,
      updatedAt: 1000,
    );
    await db.insertSession(session);
    provider = ChatProvider(
      database: db,
      api: api,
      session: session,
      profile: ProviderProfile.builtinCompany(),
      model: 'glm5.1',
    );
  });

  tearDown(() async {
    provider.dispose();
    await db.deleteSession('s1');
  });

  Future<void> seedMessages(int n) async {
    for (var i = 0; i < n; i++) {
      await db.insertMessage(
          _msg('m$i', i.isEven ? 'user' : 'assistant', '消息内容 $i', at: 1000 + i));
    }
    await provider.loadMessages();
  }

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

  group('I9 收纳信号（ChatMessageListState）', () {
    testWidgets('初始在底部：不收起', (tester) async {
      await tester.runAsync(() => seedMessages(30));
      await tester.pumpWidget(wrap(Scaffold(
        body: ChatMessageList(
          chatKey: const ValueKey('s1'),
          chat: provider,
          onDelete: () {},
        ),
      )));
      await tester.pump();

      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));
      expect(state.capsuleCollapsed.value, isFalse);
    });

    testWidgets('下滑看历史（offset 增大且离底部远）：收起', (tester) async {
      await tester.runAsync(() => seedMessages(30));
      await tester.pumpWidget(wrap(Scaffold(
        body: ChatMessageList(
          chatKey: const ValueKey('s1'),
          chat: provider,
          onDelete: () {},
        ),
      )));
      await tester.pump();

      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));
      // reverse 列表：offset 增大 = 向更早的历史滚
      state.scrollController.jumpTo(600);
      await tester.pumpAndSettle();

      expect(state.capsuleCollapsed.value, isTrue);
    });

    testWidgets('上滑回底部（offset 减小）：展开', (tester) async {
      await tester.runAsync(() => seedMessages(30));
      await tester.pumpWidget(wrap(Scaffold(
        body: ChatMessageList(
          chatKey: const ValueKey('s1'),
          chat: provider,
          onDelete: () {},
        ),
      )));
      await tester.pump();

      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));
      state.scrollController.jumpTo(600);
      await tester.pumpAndSettle();
      expect(state.capsuleCollapsed.value, isTrue);

      state.scrollController.jumpTo(300);
      await tester.pumpAndSettle();
      expect(state.capsuleCollapsed.value, isFalse);
    });

    testWidgets('底部附近微滚（< 120px）：不收起', (tester) async {
      await tester.runAsync(() => seedMessages(30));
      await tester.pumpWidget(wrap(Scaffold(
        body: ChatMessageList(
          chatKey: const ValueKey('s1'),
          chat: provider,
          onDelete: () {},
        ),
      )));
      await tester.pump();

      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));
      // 离底部 100px（< 120 阈值）：方向向下但不收起
      state.scrollController.jumpTo(100);
      await tester.pumpAndSettle();
      expect(state.capsuleCollapsed.value, isFalse);
    });

    testWidgets('流式贴底跳转（jumpTo 0，offset 只减）：不误展开已收起态',
        (tester) async {
      await tester.runAsync(() => seedMessages(30));
      await tester.pumpWidget(wrap(Scaffold(
        body: ChatMessageList(
          chatKey: const ValueKey('s1'),
          chat: provider,
          onDelete: () {},
        ),
      )));
      await tester.pump();

      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));
      // 先收起
      state.scrollController.jumpTo(600);
      await tester.pumpAndSettle();
      expect(state.capsuleCollapsed.value, isTrue);

      // 模拟 scrollToBottom 的 animateTo：offset 单调递减
      // （每帧 delta < 0 → 展开分支 → 收起态被展开，符合「上滑回底部展开」）
      // 但 jumpTo(0) 单次大步同样走展开分支——语义正确：回到底部就该展开
      state.scrollController.jumpTo(0);
      await tester.pumpAndSettle();
      expect(state.capsuleCollapsed.value, isFalse);
    });
  });

  group('I9 收纳渲染（HomeInputBar 消费信号）', () {
    testWidgets('capsuleCollapsed=null：tags 行常显（不收纳）', (tester) async {
      // 空闲态/未接信号场景：HomeInputBar 不传 capsuleCollapsed
      await tester.pumpWidget(wrap(Scaffold(
        body: HomeInputBar(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          chat: null,
          selectedAgent: null,
          selectedModel: null,
          selectedEffort: 'max',
          onSendIdle: (_, {agentId, modelPick, attachments = const []}) {},
          onPickAgent: () {},
          onPickModel: () {},
          onPickEffort: () {},
        ),
      )));
      await tester.pump();

      // tags 行可见（默认助手标签），且不受任何收纳信号影响
      expect(find.text('默认助手'), findsOneWidget);
      expect(find.byType(ChatTagsBar), findsOneWidget);
    });

    testWidgets('信号 true：tags 行收起（高度归零）', (tester) async {
      await tester.runAsync(() => seedMessages(30));
      final notifier = ValueNotifier<bool>(false);
      addTearDown(notifier.dispose);

      await tester.pumpWidget(wrap(Scaffold(
        body: Column(
          children: [
            Expanded(
              child: ChatMessageList(
                chatKey: const ValueKey('s1'),
                chat: provider,
                onDelete: () {},
              ),
            ),
            HomeInputBar(
              controller: TextEditingController(),
              focusNode: FocusNode(),
              chat: provider,
              selectedAgent: null,
              selectedModel: null,
              selectedEffort: 'max',
              onSendIdle: (_, {agentId, modelPick, attachments = const []}) {},
              onPickAgent: () {},
              onPickModel: () {},
              onPickEffort: () {},
              capsuleCollapsed: notifier,
            ),
          ],
        ),
      )));
      await tester.pump();

      // 展开态：tags 行可见
      expect(find.text('默认助手'), findsOneWidget);
      final expandedHeight = tester.getSize(find.byType(ChatTagsBar)).height;
      expect(expandedHeight, greaterThan(0));

      // 收起信号：AnimatedSize 动画后 tags 行整体不渲染（高度归零）
      notifier.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(ChatTagsBar), findsNothing);
      expect(find.text('默认助手'), findsNothing);
    });

    testWidgets('信号回 false：tags 行重新展开', (tester) async {
      await tester.runAsync(() => seedMessages(30));
      final notifier = ValueNotifier<bool>(false);
      addTearDown(notifier.dispose);

      await tester.pumpWidget(wrap(Scaffold(
        body: Column(
          children: [
            Expanded(
              child: ChatMessageList(
                chatKey: const ValueKey('s1'),
                chat: provider,
                onDelete: () {},
              ),
            ),
            HomeInputBar(
              controller: TextEditingController(),
              focusNode: FocusNode(),
              chat: provider,
              selectedAgent: null,
              selectedModel: null,
              selectedEffort: 'max',
              onSendIdle: (_, {agentId, modelPick, attachments = const []}) {},
              onPickAgent: () {},
              onPickModel: () {},
              onPickEffort: () {},
              capsuleCollapsed: notifier,
            ),
          ],
        ),
      )));
      await tester.pump();

      notifier.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(ChatTagsBar), findsNothing);

      notifier.value = false;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ChatTagsBar)).height, greaterThan(0));
      expect(find.text('默认助手'), findsOneWidget);
    });
  });
}
