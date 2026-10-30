import 'package:ai_chat_app/pages/card_library_page.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ai_chat_app/models/card.dart' as card_model;
import 'helpers/test_db.dart';

/// M5 卡片库面板 UI 测试（真实 DB：sqflite_ffi + runAsync 推进 IO）
///
/// 核心行为：
/// - 列表渲染：标题 + 正文预览 + 标签 chips
/// - 搜索过滤：标题/正文/标签命中 + 清空恢复
/// - 编辑弹窗：预填 + 保存落库 + 空标题拒绝
/// - 删除：确认弹窗 + 落库；清空全部同理
/// - 空态引导文案
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
  });

  tearDown(() async {
    await db.close();
  });

  card_model.Card card(String id, String title, String content,
          {String? tags, int updatedAt = 1000}) =>
      card_model.Card(
        id: id,
        sessionId: 's1',
        sourceMessageId: 'm1',
        title: title,
        content: content,
        tags: tags,
        createdAt: 1000,
        updatedAt: updatedAt,
      );

  /// 种子数据（runAsync：真实异步 IO 在 fakeAsync 区推不动）。
  /// updatedAt 错开：列表按 updated_at DESC 排序，平局顺序不定，
  /// c1（新）在前 → .first 稳定命中 c1
  Future<void> seed() async {
    await db.insertCard(card('c1', '报销发票要求', '发票抬头必须与公司名一致',
        tags: '财务,报销', updatedAt: 2000));
    await db.insertCard(card('c2', 'Flutter 布局口诀', '约束向下，尺寸向上',
        updatedAt: 1000));
  }

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// 挂载面板并等初始加载完成（_reload 的真实 DB IO 必须 runAsync 推进，
  /// 否则 _loading 恒 true → 进度条永转 → pumpAndSettle 超时）
  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(wrap(const CardLibraryPanel()));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  /// 推进「弹窗确认 → 写库 → _reload → setState」整条真实 IO 链。
  ///
  /// 链上有多级 IO 跳：单次 runAsync 只能推进当前挂起的那跳，后续跳的
  /// 续体是 fake 区微任务（pump 才冲刷），冲刷后又起新的真实 IO——
  /// 必须 runAsync/pump 交替两轮才能走完全链，UI 才会刷新。
  Future<void> settleIO(WidgetTester tester) async {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }

  group('CardLibraryPanel', () {
    testWidgets('列表渲染：标题 + 正文 + 标签 chips', (tester) async {
      await tester.runAsync(seed);
      await pumpPanel(tester);

      expect(find.text('报销发票要求'), findsOneWidget);
      expect(find.text('Flutter 布局口诀'), findsOneWidget);
      expect(find.textContaining('发票抬头必须与公司名一致'), findsOneWidget);
      expect(find.text('财务'), findsOneWidget);
      expect(find.text('报销'), findsOneWidget);
    });

    testWidgets('空态：显示引导文案', (tester) async {
      await pumpPanel(tester);

      expect(find.text('还没有卡片'), findsOneWidget);
      expect(find.textContaining('沉淀为卡片'), findsOneWidget);
    });

    testWidgets('搜索过滤：命中标题/正文/标签，清空恢复', (tester) async {
      await tester.runAsync(seed);
      await pumpPanel(tester);

      // 标题命中
      await tester.enterText(find.byType(TextField), '口诀');
      await tester.pump();
      expect(find.text('Flutter 布局口诀'), findsOneWidget);
      expect(find.text('报销发票要求'), findsNothing);

      // 标签命中
      await tester.enterText(find.byType(TextField), '财务');
      await tester.pump();
      expect(find.text('报销发票要求'), findsOneWidget);
      expect(find.text('Flutter 布局口诀'), findsNothing);

      // 清空恢复全部
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('报销发票要求'), findsOneWidget);
      expect(find.text('Flutter 布局口诀'), findsOneWidget);
    });

    testWidgets('搜索无结果：显示「没有匹配的卡片」', (tester) async {
      await tester.runAsync(seed);
      await pumpPanel(tester);

      await tester.enterText(find.byType(TextField), '不存在的关键词');
      await tester.pump();

      expect(find.text('没有匹配的卡片'), findsOneWidget);
    });

    testWidgets('编辑：弹窗预填，保存后落库', (tester) async {
      await tester.runAsync(seed);
      await pumpPanel(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();

      expect(find.text('编辑卡片'), findsOneWidget);
      // 标题预填（卡片 + 弹窗输入框 = 2 处）
      expect(find.text('报销发票要求'), findsNWidgets(2));

      await tester.enterText(
          find.widgetWithText(TextField, '标题'), '改写标题');
      await tester.tap(find.text('保存'));
      // 弹窗 pop 后的 updateCard + _reload 是真实 IO：整链推进
      await settleIO(tester);

      final stored = await tester.runAsync(() => db.getAllCards());
      expect(stored!.firstWhere((c) => c.id == 'c1').title, '改写标题');
      expect(find.text('改写标题'), findsOneWidget);
    });

    testWidgets('编辑：空标题拒绝保存', (tester) async {
      await tester.runAsync(seed);
      await pumpPanel(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '标题'), '   ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      // Toast 提示 + 弹窗未关闭（校验在弹窗内就地拦截）
      expect(find.text('标题不能为空'), findsOneWidget);
      expect(find.text('编辑卡片'), findsOneWidget);

      final stored = await tester.runAsync(() => db.getAllCards());
      expect(stored!.firstWhere((c) => c.id == 'c1').title, '报销发票要求');
    });

    testWidgets('删除单张：确认后落库消失', (tester) async {
      await tester.runAsync(seed);
      await pumpPanel(tester);

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();

      expect(find.text('删除卡片'), findsOneWidget);
      await tester.tap(find.text('删除'));
      // 确认后的 deleteCard + _reload 是真实 IO：整链推进
      await settleIO(tester);

      final stored = await tester.runAsync(() => db.getAllCards());
      expect(stored!.map((c) => c.id), ['c2']);
      expect(find.text('报销发票要求'), findsNothing);
      expect(find.text('Flutter 布局口诀'), findsOneWidget);
    });

    testWidgets('清空全部：确认后列表清空', (tester) async {
      await tester.runAsync(seed);
      await pumpPanel(tester);

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();

      expect(find.text('清空卡片'), findsOneWidget);
      await tester.tap(find.text('清空'));
      // 确认后的 deleteAllCards + _reload 是真实 IO：整链推进
      await settleIO(tester);

      final stored = await tester.runAsync(() => db.getAllCards());
      expect(stored, isEmpty);
      expect(find.text('还没有卡片'), findsOneWidget);
    });

    testWidgets('清空全部：取消不清空', (tester) async {
      await tester.runAsync(seed);
      await pumpPanel(tester);

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      final stored = await tester.runAsync(() => db.getAllCards());
      expect(stored, hasLength(2));
    });
  });
}
