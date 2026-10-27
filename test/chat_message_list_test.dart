import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/widgets/home/chat_message_list.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ai_chat_app/services/settings_service.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock（与 chat_provider_test 同款）
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
    // sqflite_ffi 的真实异步 IO 在 widget 测试 fakeAsync 区推不动，
    // DB 初始化也必须发生在 FakeAsync 区外（setUpAll 天然满足）
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

  /// 预置 N 条历史消息并加载（runAsync：真实异步 IO）
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
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  /// 预置长会话并上屏（默认跟随态）
  Future<void> pumpList(
    WidgetTester tester, {
    int messages = 30,
    ValueChanged<ChatMessage>? onEditMessage,
    ValueChanged<ChatMessage>? onQuoteMessage,
  }) async {
    await tester.runAsync(() => seedMessages(messages));
    await tester.pumpWidget(wrap(ChatMessageList(
      chatKey: const ValueKey('s1'),
      chat: provider,
      onDelete: () {},
      onEditMessage: onEditMessage,
      onQuoteMessage: onQuoteMessage,
    )));
    await tester.pump();
  }

  group('I1 智能跟随：跟随态行为', () {
    testWidgets('初始渲染在跟随态：无「回到最新」胶囊', (tester) async {
      await pumpList(tester);
      expect(find.text('回到最新'), findsNothing);
      expect(find.textContaining('回到最新'), findsNothing);
    });

    testWidgets('跟随态下流式增长持续贴底（offset 保持 0）', (tester) async {
      await pumpList(tester);
      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));
      expect(state.scrollController.offset, 0);

      // 驱动一轮流式：内容增长期间 offset 应保持贴底
      await tester.runAsync(() async {
        await provider.sendMessage('你好');
        api.emit(const SseDeltaContent('回答'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(state.scrollController.offset, 0);

      await tester.runAsync(() async {
        api.emit(const SseUsage(promptTokens: 10, completionTokens: 5));
        api.emit(const SseDone());
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(state.scrollController.offset, 0);
    });
  });

  group('I1 智能跟随：滚离底部', () {
    testWidgets('上滑滚离底部：胶囊浮出', (tester) async {
      await pumpList(tester);
      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));

      // 模拟滚离底部（reverse 列表向上滚 = offset 增大）
      state.scrollController.jumpTo(600);
      await tester.pumpAndSettle();

      expect(find.textContaining('回到最新'), findsOneWidget);
    });

    testWidgets('滚回底部：胶囊消失、跟随恢复', (tester) async {
      await pumpList(tester);
      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));

      state.scrollController.jumpTo(600);
      await tester.pumpAndSettle();
      expect(find.textContaining('回到最新'), findsOneWidget);

      // 滚回底部（阈值 60 内）
      state.scrollController.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.textContaining('回到最新'), findsNothing);
      expect(state.scrollController.offset, 0);
    });

    testWidgets('非跟随态流式增长不再拽回底部（核心诉求）', (tester) async {
      await pumpList(tester);
      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));

      // 滚离底部进入回看模式
      state.scrollController.jumpTo(600);
      await tester.pumpAndSettle();
      final offsetBefore = state.scrollController.offset;

      // 流式内容增长：offset 不应被强制归零（用户正在回看）
      await tester.runAsync(() async {
        await provider.sendMessage('你好');
        api.emit(const SseDeltaContent('这是一段很长的流式回答内容'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(state.scrollController.offset, offsetBefore,
          reason: '非跟随态下流式增长不得拽回底部');
      expect(find.textContaining('回到最新'), findsOneWidget);

      // 收尾清理流式状态
      await tester.runAsync(() async {
        api.emit(const SseUsage(promptTokens: 10, completionTokens: 5));
        api.emit(const SseDone());
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
    });

    testWidgets('点胶囊平滑滚回底部并恢复跟随', (tester) async {
      await pumpList(tester);
      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));

      state.scrollController.jumpTo(600);
      await tester.pumpAndSettle();
      expect(find.textContaining('回到最新'), findsOneWidget);

      await tester.tap(find.textContaining('回到最新'));
      await tester.pumpAndSettle();

      expect(state.scrollController.offset, 0);
      expect(find.textContaining('回到最新'), findsNothing);
    });
  });

  group('I1 智能跟随：触摸暂停', () {
    testWidgets('拖拽列表即暂停跟随（拖拽中流式不拽底）', (tester) async {
      await pumpList(tester);
      final state = tester.state<ChatMessageListState>(
          find.byType(ChatMessageList));

      // 手指按下并拖动（ScrollStartNotification.dragDetails != null）
      // reverse 列表：手指下滑（+dy）= 内容向上滚 = 滚离底部
      final gesture = await tester.startGesture(tester.getCenter(
          find.byType(ListView).first));
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();

      // 拖拽中流式增长：不应被拽回底部
      await tester.runAsync(() async {
        await provider.sendMessage('你好');
        api.emit(const SseDeltaContent('流式内容'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(state.scrollController.offset, greaterThan(0),
          reason: '拖拽中流式增长不得强制跳底');

      await gesture.up();
      // 收尾清理流式状态（先结束流式再 settle：流式中的呼吸点动画
      // 无限循环会让 pumpAndSettle 超时）
      await tester.runAsync(() async {
        api.emit(const SseUsage(promptTokens: 10, completionTokens: 5));
        api.emit(const SseDone());
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
    });
  });

  group('I4 编辑重发 / I5 引用追问：气泡菜单回调', () {
    testWidgets('user 气泡长按菜单含「编辑重发」，点击触发 onEditMessage',
        (tester) async {
      ChatMessage? edited;
      await pumpList(tester, messages: 2, onEditMessage: (m) => edited = m);

      // 长按第一条 user 气泡（列表 reverse：index 0 是最后一条）
      final userBubble = find.text('消息内容 0');
      await tester.longPress(userBubble);
      await tester.pumpAndSettle();

      await tester.tap(find.text('编辑重发'));
      await tester.pumpAndSettle();

      expect(edited, isNotNull);
      expect(edited!.id, 'm0');
    });

    testWidgets('assistant 气泡长按菜单含「引用」，点击触发 onQuoteMessage',
        (tester) async {
      ChatMessage? quoted;
      await pumpList(tester, messages: 2, onQuoteMessage: (m) => quoted = m);

      final assistantBubble = find.text('消息内容 1');
      await tester.longPress(assistantBubble);
      await tester.pumpAndSettle();

      await tester.tap(find.text('引用'));
      await tester.pumpAndSettle();

      expect(quoted, isNotNull);
      expect(quoted!.id, 'm1');
    });

    testWidgets('回调为 null 时菜单不显示对应项', (tester) async {
      await pumpList(tester, messages: 2);

      // user 气泡：无 onEditMessage → 无「编辑重发」（菜单仍弹出，含钉住项）
      await tester.longPress(find.text('消息内容 0'));
      await tester.pumpAndSettle();
      expect(find.text('编辑重发'), findsNothing);
      expect(find.text('钉住'), findsOneWidget);
      await tester.tap(find.text('钉住'));
      await tester.pumpAndSettle();

      // assistant 气泡：无 onQuoteMessage → 无「引用」（菜单仍弹出）
      await tester.longPress(find.text('消息内容 1'));
      await tester.pumpAndSettle();
      expect(find.text('引用'), findsNothing);
      expect(find.text('选择文字'), findsOneWidget);
      await tester.tap(find.text('选择文字'));
      await tester.pumpAndSettle();
    });
  });
}
