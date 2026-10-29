import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/providers/agent_provider.dart';
import 'package:ai_chat_app/services/agent_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/widgets/home/session_drawer_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// E11 ② 会话列表游标分页：ListView.builder 惰性构建 + 首屏 50 条 +
/// 「加载更多」步进追加
///
/// 核心行为：
/// - ≤50 条：全部展示，无「加载更多」
/// - >50 条：首屏只展示 50 条，末尾「加载更多」
/// - 点「加载更多」：追加一个步进页（100 条）
/// - 全部加载后「加载更多」消失
/// - 搜索态不受分页限制（必须命中全部）
/// - 分组标题与会话条目在 builder 模式下顺序正确
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
    agents = AgentProvider(service: AgentService(database: db));
    await agents.load();
  });

  tearDown(() async {
    await db.close();
  });

  /// 生成 n 个会话（updatedAt 递减，保证排序稳定）
  List<ChatSession> sessions(int n) => List.generate(
        n,
        (i) => ChatSession(
          id: 's$i',
          title: '会话 $i',
          createdAt: 10000 - i,
          updatedAt: 10000 - i,
        ),
      );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  Future<void> pumpPanel(
    WidgetTester tester,
    List<ChatSession> list, {
    void Function(String id)? onOpenChat,
  }) async {
    await tester.pumpWidget(wrap(SessionDrawerPanel(
      sessions: list,
      agentsProvider: agents,
      loaded: true,
      batchMode: ValueNotifier(false),
      removingIds: const {},
      onClose: () {},
      onDeleteSelected: (_) async {},
      onOpenChat: onOpenChat ?? (_) {},
      onOpenMessage: (_, _) {},
      onOpenSettings: () {},
      onShowActions: (_, _, _, _) {},
    )));
    await tester.pump();
  }

  group('E11 ② 游标分页', () {
    testWidgets('≤50 条：全部在数据集内，无「加载更多」', (tester) async {
      await pumpPanel(tester, sessions(30));

      // builder 惰性构建：首条可见，末条滚到底可见（数据集 30 < 50 不裁剪）
      expect(find.text('会话 0'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('会话 29'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('会话 29'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
    });

    testWidgets('>50 条：首屏 50 条 + 「加载更多」', (tester) async {
      await pumpPanel(tester, sessions(80));

      // 首屏 50 条：最新的 50 个（updatedAt 递减 → s0..s49）
      expect(find.text('会话 0'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('会话 49'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('会话 49'), findsOneWidget);
      // 第 51 条不在数据集（被游标裁剪），滚不到
      expect(find.text('会话 50'), findsNothing);
      // 加载更多入口
      expect(find.text('加载更多'), findsOneWidget);
    });

    testWidgets('点「加载更多」：追加一个步进页', (tester) async {
      await pumpPanel(tester, sessions(80));

      await tester.scrollUntilVisible(
        find.text('加载更多'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();

      // 100 条上限内：80 条全部进数据集，「加载更多」消失
      await tester.scrollUntilVisible(
        find.text('会话 79'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('会话 79'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
    });

    testWidgets('超大量：多次加载逐步逼近全量', (tester) async {
      await pumpPanel(tester, sessions(130));

      // 第一页：s0..s49
      expect(find.text('会话 0'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('加载更多'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();

      // 第二页：s0..s99
      await tester.scrollUntilVisible(
        find.text('会话 99'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('会话 99'), findsOneWidget);
      expect(find.text('会话 100'), findsNothing);
      expect(find.text('加载更多'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('加载更多'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();

      // 第三页：130 条全量
      await tester.scrollUntilVisible(
        find.text('会话 129'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('会话 129'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
    });

    testWidgets('搜索态不受分页限制：命中全部', (tester) async {
      // 80 条会话，其中 60 条标题含「项目」
      final list = <ChatSession>[
        for (var i = 0; i < 60; i++)
          ChatSession(
            id: 'p$i',
            title: '项目 $i',
            createdAt: 10000 - i,
            updatedAt: 10000 - i,
          ),
        for (var i = 0; i < 20; i++)
          ChatSession(
            id: 'o$i',
            title: '其他 $i',
            createdAt: 100 - i,
            updatedAt: 100 - i,
          ),
      ];
      await pumpPanel(tester, list);

      // 进入搜索态（防抖 300ms + FTS 真实 IO 用 runAsync 推进，
      // 否则查询挂在 fakeAsync 区列表体永远停在 loading）
      await tester.tap(find.byTooltip('搜索会话'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '项目');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      // 搜索命中不受 50 条裁剪：60 条全部可滚到。
      // scrollable 必须锁定 ListView 的——TextField 自带 Scrollable，
      // find.byType(Scrollable).first 会命中输入框的（DFS 序在前）
      await tester.scrollUntilVisible(
        find.text('项目 59'),
        300,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first,
      );
      expect(find.text('项目 59'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
    });

    testWidgets('分组标题在 builder 模式下顺序正确', (tester) async {
      final now = DateTime.now();
      final startOfToday =
          DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
      final list = [
        ChatSession(
            id: 'today',
            title: '今天会话',
            createdAt: startOfToday + 100,
            updatedAt: startOfToday + 100),
        ChatSession(
            id: 'old',
            title: '更早会话',
            createdAt: startOfToday - 30 * 24 * 3600 * 1000,
            updatedAt: startOfToday - 30 * 24 * 3600 * 1000),
      ];
      await pumpPanel(tester, list);

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('7 天内'), findsNothing);
      expect(find.text('更早'), findsOneWidget);
      expect(find.text('今天会话'), findsOneWidget);
      expect(find.text('更早会话'), findsOneWidget);

      // 分组标题在对应会话之上
      final todayY = tester.getTopLeft(find.text('今天')).dy;
      final todaySessionY = tester.getTopLeft(find.text('今天会话')).dy;
      expect(todayY, lessThan(todaySessionY));
    });

    testWidgets('点会话回调 onOpenChat（builder 模式交互不回归）', (tester) async {
      String? openedId;
      await pumpPanel(tester, sessions(5), onOpenChat: (id) => openedId = id);

      await tester.tap(find.text('会话 2'));
      await tester.pump();

      expect(openedId, 's2');
    });
  });
}
