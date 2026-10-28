import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/home/chat_message_list.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// I7 搜索定位测试：scrollToMessage 滚动定位 + 命中气泡临时高亮
///
/// 核心行为：
/// - 定位到消息：滚动到可见 + 气泡高亮
/// - 高亮 2s 后自动渐隐清除
/// - 定位后暂停跟随（新消息不拽回底部）
/// - MessageBubble highlight 参数：描边/底色变化
///
/// 测试区注意：scrollToMessage 内部 await ensureVisible 动画与
/// endOfFrame，fakeAsync 区必须用 pump 驱动帧——不能直接 await 该
/// Future（帧只在 pump 时发生，裸 await 永久挂起）。高亮清除 Timer
/// 是 pending timer，测试结束前必须 pump 过它。
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

  ChatMessage _msg(String id, String role, String content, {int at = 1000}) =>
      ChatMessage(
        id: id,
        sessionId: 's1',
        role: role,
        content: content,
        createdAt: at,
      );

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  Future<ChatMessageListState> pumpList(
    WidgetTester tester, {
    int messages = 30,
  }) async {
    await tester.runAsync(() async {
      for (var i = 0; i < messages; i++) {
        await db.insertMessage(_msg(
            'm$i', i.isEven ? 'user' : 'assistant', '消息内容 $i', at: 1000 + i));
      }
      await provider.loadMessages();
    });
    await tester.pumpWidget(wrap(ChatMessageList(
      chatKey: const ValueKey('s1'),
      chat: provider,
      onDelete: () {},
    )));
    await tester.pump();
    return tester.state<ChatMessageListState>(
        find.byType(ChatMessageList));
  }

  /// 定位到消息并驱动完动画（pump 驱动 ensureVisible + endOfFrame）
  Future<void> locate(WidgetTester tester, ChatMessageListState state,
      String messageId) async {
    final locating = state.scrollToMessage(messageId);
    await tester.pumpAndSettle();
    await locating;
  }

  /// 目标消息的气泡 widget
  MessageBubble bubbleOf(WidgetTester tester, String content) =>
      tester.widget<MessageBubble>(
        find.ancestor(
          of: find.text(content),
          matching: find.byType(MessageBubble),
        ),
      );

  group('scrollToMessage 定位', () {
    testWidgets('定位：滚动到可见 + 气泡高亮', (tester) async {
      final state = await pumpList(tester);
      // 30 条消息，reverse 列表初始在底部（offset 0）
      expect(state.scrollController.offset, 0);

      // 定位到最早的消息 m0（列表最深处）
      await locate(tester, state, 'm0');

      // 滚动了（offset > 0），m0 气泡在屏上且高亮
      expect(state.scrollController.offset, greaterThan(0));
      expect(find.text('消息内容 0'), findsOneWidget);
      expect(bubbleOf(tester, '消息内容 0').highlight, isTrue,
          reason: '定位目标应处于高亮态');

      // 清 pending 高亮 Timer（防测试结束报 pending timer）
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('高亮 2s 后自动渐隐', (tester) async {
      final state = await pumpList(tester);
      await locate(tester, state, 'm0');
      expect(bubbleOf(tester, '消息内容 0').highlight, isTrue);

      // 推进 2s+：高亮清除（Timer 在 pump 中触发）
      await tester.pump(const Duration(milliseconds: 2100));
      expect(bubbleOf(tester, '消息内容 0').highlight, isFalse,
          reason: '高亮 2s 后应自动清除');
    });

    testWidgets('定位后暂停跟随：新消息不拽回底部', (tester) async {
      final state = await pumpList(tester);
      await locate(tester, state, 'm0');
      final offsetAfterLocate = state.scrollController.offset;
      expect(offsetAfterLocate, greaterThan(0));

      // 模拟新消息出现（displayMessages 变化触发 _maybeAutoScroll）：
      // 定位态（非跟随）不得被拽回底部
      await tester.runAsync(() async {
        await db.insertMessage(_msg('m30', 'user', '新消息', at: 2000));
        await provider.loadMessages();
      });
      await tester.pump();

      expect(state.scrollController.offset, offsetAfterLocate,
          reason: '定位后非跟随态，新消息不得拽回底部');

      // 清 pending 高亮 Timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('不存在的消息 id：无操作不崩溃', (tester) async {
      final state = await pumpList(tester);
      await state.scrollToMessage('不存在');
      await tester.pump();
      expect(state.scrollController.offset, 0);
    });
  });

  group('MessageBubble highlight', () {
    // 气泡本体 Container（带 BoxDecoration + 宽度约束）。SwipeActionContainer
    // 的动作区也有 BoxDecoration 但无 constraints，按谓词排除
    Container bubbleContainer(WidgetTester tester) =>
        tester.widget<Container>(
          find
              .descendant(
                of: find.byType(MessageBubble),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Container &&
                      w.decoration is BoxDecoration &&
                      w.constraints != null,
                ),
              )
              .first,
        );

    testWidgets('highlight=true：助手气泡带主色描边', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: ChatMessage(
          id: 'm1',
          sessionId: 's1',
          role: 'assistant',
          content: '回答内容',
          createdAt: 1000,
        ),
        highlight: true,
      )));

      final decoration = bubbleContainer(tester).decoration as BoxDecoration;
      // 高亮态：主色描边（底色换 primaryContainer）
      expect(decoration.border, isA<Border>());
      expect((decoration.border as Border).top.width, 1.5);
    });

    testWidgets('highlight=false（默认）：无描边', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: ChatMessage(
          id: 'm1',
          sessionId: 's1',
          role: 'assistant',
          content: '回答内容',
          createdAt: 1000,
        ),
      )));

      final decoration = bubbleContainer(tester).decoration as BoxDecoration;
      expect(decoration.border, isNull);
    });
  });
}

/// 无操作 API（本文件只测列表定位，不发请求）
class _NoopApi implements ApiService {
  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
