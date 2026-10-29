import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/providers/agent_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/agent_service.dart';
import 'package:ai_chat_app/widgets/home/session_drawer_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// I7 全文搜索 UI 测试：抽屉搜索接 FTS（防抖 → 命中列表 → 跳转回调）
///
/// 核心行为：
/// - 搜索态输入 ≥2 字：FTS 命中消息以「会话名 + 缩略」展示在会话结果下方
///   （会话组置顶——会话少，搜会话不该滚过一堆消息；用户定版 2026-10-28）
/// - 命中词在缩略中高亮（TextSpan 主色加粗）
/// - 单字走 LIKE 兜底同样出结果
/// - 点命中项回调 onOpenMessage（宿主负责切会话 + 定位高亮）
/// - 防抖：300ms 内连续输入只发最后一次查询
///
/// 测试区注意：testWidgets 体是 fakeAsync 区，DB 真实异步 IO 必须
/// tester.runAsync 包裹；防抖 Timer 是 fake 时钟，pump(350ms) 触发。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late AgentProvider agents;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    SharedPreferences.setMockInitialValues({});
    agents = AgentProvider(
      service: AgentService(database: db),
    );
    await agents.load();
  });

  tearDown(() async {
    await db.close();
  });

  ChatSession session(String id, String title, {int at = 1000}) =>
      ChatSession(id: id, title: title, createdAt: at, updatedAt: at);

  ChatMessage msg(String id, String sessionId, String content,
          {int at = 1000}) =>
      ChatMessage(
        id: id,
        sessionId: sessionId,
        role: 'user',
        content: content,
        createdAt: at,
      );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  Future<void> pumpPanel(
    WidgetTester tester, {
    List<ChatSession> sessions = const [],
    void Function(String id)? onOpenChat,
    void Function(ChatMessage hit, String query)? onOpenMessage,
  }) async {
    await tester.pumpWidget(wrap(SessionDrawerPanel(
      sessions: sessions,
      agentsProvider: agents,
      loaded: true,
      batchMode: ValueNotifier(false),
      removingIds: const {},
      onClose: () {},
      onDeleteSelected: (_) async {},
      onOpenChat: onOpenChat ?? (_) {},
      onOpenMessage: onOpenMessage ?? (_, __) {},
      onOpenSettings: () {},
      onShowActions: (_, __, ___, ____) {},
    )));
    await tester.pump();
  }

  /// 展开搜索框并输入：pump 推进假时钟触发防抖 Timer，runAsync 等
  /// FTS 真实 IO 完成，末次 pump 冲刷 fake 区微任务（setState 生效）
  Future<void> search(WidgetTester tester, String query) async {
    await tester.tap(find.byTooltip('搜索会话'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
  }

  group('FTS 命中结果展示', () {
    testWidgets('正文命中：消息内容组展示会话名 + 缩略', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '报销讨论'));
        await db.insertSession(session('s2', '闲聊'));
        await db.insertMessage(msg('m1', 's1', '今天讨论了报销流程'));
        await db.insertMessage(msg('m2', 's2', '明天去公园玩'));
      });
      await pumpPanel(tester, sessions: [
        session('s1', '报销讨论'),
        session('s2', '闲聊'),
      ]);

      await search(tester, '报销');

      // 命中分组标题 + 会话名 + 缩略（「报销讨论」出现 2 次：
      // 消息命中条目的会话名 + 会话命中条目的标题）
      expect(find.text('消息内容'), findsOneWidget);
      expect(find.text('报销讨论'), findsNWidgets(2));
      expect(find.textContaining('报销流程'), findsOneWidget);
      // 不命中的消息不出现
      expect(find.textContaining('公园'), findsNothing);
    });

    testWidgets('命中词在缩略中高亮（主色 TextSpan）', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '工作'));
        await db.insertMessage(msg('m1', 's1', '今天讨论了报销流程的事情'));
      });
      await pumpPanel(tester, sessions: [session('s1', '工作')]);

      await search(tester, '报销');

      // 缩略里命中词以独立 TextSpan 呈现（主色加粗）
      final richText = tester.widget<Text>(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.byWidgetPredicate(
            (w) => w is Text && w.textSpan != null,
          ),
        ).first,
      );
      final spans =
          (richText.textSpan as TextSpan).children!.cast<TextSpan>();
      final hitSpans = spans.where((s) => s.text == '报销').toList();
      expect(hitSpans, hasLength(1), reason: '命中词应切为独立 TextSpan');
      expect(hitSpans.first.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('单字查询走 LIKE 兜底同样出结果', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '工作'));
        await db.insertMessage(msg('m1', 's1', '今天讨论了报销流程'));
      });
      await pumpPanel(tester, sessions: [session('s1', '工作')]);

      await search(tester, '报');

      expect(find.text('消息内容'), findsOneWidget);
      expect(find.textContaining('报销流程'), findsOneWidget);
    });

    testWidgets('标题命中：会话组展示', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '报销讨论'));
      });
      await pumpPanel(tester, sessions: [session('s1', '报销讨论')]);

      await search(tester, '报销');

      expect(find.text('会话'), findsOneWidget);
      expect(find.text('报销讨论'), findsOneWidget);
    });

    testWidgets('标题和正文都命中：两组都展示', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '报销讨论'));
        await db.insertMessage(msg('m1', 's1', '报销流程怎么走'));
      });
      await pumpPanel(tester, sessions: [session('s1', '报销讨论')]);

      await search(tester, '报销');

      expect(find.text('消息内容'), findsOneWidget);
      expect(find.text('会话'), findsOneWidget);
    });

    testWidgets('分组顺序：会话组在消息内容组之上（用户定版）', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '报销讨论'));
        await db.insertMessage(msg('m1', 's1', '报销流程怎么走'));
      });
      await pumpPanel(tester, sessions: [session('s1', '报销讨论')]);

      await search(tester, '报销');

      // 会话少消息多：会话组置顶，消息组在下（搜会话不用滚过一堆消息）
      final sessionGroupY =
          tester.getTopLeft(find.text('会话')).dy;
      final messageGroupY =
          tester.getTopLeft(find.text('消息内容')).dy;
      expect(sessionGroupY, lessThan(messageGroupY),
          reason: '会话组应排在消息内容组上方');
    });

    testWidgets('无命中：显示「没有找到」', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '工作'));
        await db.insertMessage(msg('m1', 's1', '今天讨论了报销流程'));
      });
      await pumpPanel(tester, sessions: [session('s1', '工作')]);

      await search(tester, '不存在的词');

      expect(find.text('没有找到「不存在的词」'), findsOneWidget);
    });
  });

  group('命中项交互', () {
    testWidgets('点命中项回调 onOpenMessage（带命中消息 + 查询词）', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '报销讨论'));
        await db.insertMessage(msg('m1', 's1', '今天讨论了报销流程'));
      });
      ChatMessage? receivedHit;
      String? receivedQuery;
      await pumpPanel(
        tester,
        sessions: [session('s1', '报销讨论')],
        onOpenMessage: (hit, query) {
          receivedHit = hit;
          receivedQuery = query;
        },
      );

      await search(tester, '报销');
      await tester.tap(find.textContaining('报销流程'));
      await tester.pump();

      expect(receivedHit?.id, 'm1');
      expect(receivedQuery, '报销');
    });

    testWidgets('点标题命中项回调 onOpenChat', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '报销讨论'));
      });
      String? openedId;
      await pumpPanel(
        tester,
        sessions: [session('s1', '报销讨论')],
        onOpenChat: (id) => openedId = id,
      );

      await search(tester, '报销');
      await tester.tap(find.text('报销讨论'));
      await tester.pump();

      expect(openedId, 's1');
    });
  });

  group('搜索状态管理', () {
    testWidgets('清空查询：FTS 结果清空回到常规列表', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '报销讨论'));
        await db.insertMessage(msg('m1', 's1', '今天讨论了报销流程'));
      });
      await pumpPanel(tester, sessions: [session('s1', '报销讨论')]);

      await search(tester, '报销');
      expect(find.text('消息内容'), findsOneWidget);

      // 清空（点输入框内的 ×）
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(find.text('消息内容'), findsNothing);
      // 回到常规时间分组列表（会话标题含「报销」仍显示）
      expect(find.text('报销讨论'), findsOneWidget);
    });

    testWidgets('关闭搜索：查询与结果全部重置', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '报销讨论'));
        await db.insertMessage(msg('m1', 's1', '今天讨论了报销流程'));
      });
      await pumpPanel(tester, sessions: [session('s1', '报销讨论')]);

      await search(tester, '报销');
      expect(find.text('消息内容'), findsOneWidget);

      // 点放大镜关闭搜索
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
      expect(find.text('消息内容'), findsNothing);
      expect(find.text('报销讨论'), findsOneWidget);
    });

    testWidgets('防抖：快速连续输入只发最后一次查询', (tester) async {
      await tester.runAsync(() async {
        await db.insertSession(session('s1', '工作'));
        await db.insertMessage(msg('m1', 's1', '今天讨论了报销流程'));
      });
      await pumpPanel(tester, sessions: [session('s1', '工作')]);

      await tester.tap(find.byTooltip('搜索会话'));
      await tester.pump();
      // 快速连续输入（每次都重置防抖计时器）
      await tester.enterText(find.byType(TextField), '报销');
      await tester.enterText(find.byType(TextField), '报销流');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      // 最终查询生效（防抖后最后一次）
      expect(find.textContaining('报销流程'), findsOneWidget);
    });
  });
}
