import 'package:ai_chat_app/models/memory.dart';
import 'package:ai_chat_app/pages/memory_page.dart';
import 'package:ai_chat_app/providers/memory_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/memory_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 假 MemoryProvider：不碰真实 DB（sqflite_ffi 异步 IO 在 widget 测试
/// fake async 环境推不动），CRUD 同步完成并记录调用参数供断言。
class _FakeMemoryProvider extends MemoryProvider {
  _FakeMemoryProvider()
      : super(service: MemoryService(database: DatabaseService.instance));

  List<Memory> _store = [];
  bool _loaded = false;

  final List<String> added = [];
  final List<String> addedTags = [];
  final List<String> deletedIds = [];
  final List<(String, bool)> pinCalls = [];
  final List<(String, String?, String?)> updateCalls = [];
  int deletedAllCount = 0;

  @override
  List<Memory> get memories => _store;

  @override
  bool get loaded => _loaded;

  @override
  Future<void> load() async {
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<Memory> add(String content, {String? tag}) async {
    added.add(content);
    addedTags.add(tag ?? '');
    final m = Memory(
        id: 'fake-${added.length}',
        content: content,
        tag: tag,
        createdAt: 1,
        updatedAt: 1);
    _store.add(m);
    notifyListeners();
    return m;
  }

  @override
  Future<void> delete(String id) async {
    deletedIds.add(id);
    _store.removeWhere((m) => m.id == id);
    notifyListeners();
  }

  @override
  Future<void> setPinned(String id, bool pinned) async {
    _store = [
      for (final m in _store)
        if (m.id == id) m.copyWith(pinned: pinned) else m
    ];
    pinCalls.add((id, pinned));
    notifyListeners();
  }

  @override
  Future<void> update(String id, {String? content, String? tag}) async {
    updateCalls.add((id, content, tag));
    _store = [
      for (final m in _store)
        if (m.id == id)
          m.copyWith(content: content ?? m.content, tag: tag ?? m.tag)
        else
          m
    ];
    notifyListeners();
  }

  @override
  Future<void> deleteAll() async {
    deletedAllCount++;
    _store.clear();
    notifyListeners();
  }

  // 测试辅助：直接操纵内部状态
  void seed(List<Memory> memories) {
    _store.addAll(memories);
    _loaded = true;
  }
}

Memory memory(String id, String content, {String? tag, bool pinned = false}) =>
    Memory(
      id: id,
      content: content,
      tag: tag,
      pinned: pinned,
      createdAt: 1000,
      updatedAt: 1000,
    );

void main() {
  late _FakeMemoryProvider provider;

  setUp(() {
    provider = _FakeMemoryProvider();
  });

  tearDown(() {
    provider.dispose();
  });

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<MemoryProvider>.value(value: provider),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  group('MemoryPanel', () {
    testWidgets('空态：显示引导文案', (tester) async {
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      expect(
          find.textContaining('AI 还没有记住任何东西'), findsOneWidget);
    });

    testWidgets('列表渲染：内容 + 标签副标题', (tester) async {
      provider.seed([
        memory('m1', '用户喜欢简洁回答', tag: '偏好'),
        memory('m2', '用户在上海工作'),
      ]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      expect(find.text('用户喜欢简洁回答'), findsOneWidget);
      expect(find.text('用户在上海工作'), findsOneWidget);
      // 「偏好」同时出现在 chip 与卡片副标题（M1 策展台新增 chips 行）
      expect(find.text('偏好'), findsNWidgets(2));
    });

    testWidgets('搜索过滤：关键词命中与清空', (tester) async {
      provider.seed([
        memory('m1', '用户喜欢简洁回答'),
        memory('m2', '项目用 Flutter'),
      ]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.enterText(find.widgetWithText(TextField, '搜索记忆'), '简洁');
      await tester.pump();

      expect(find.text('用户喜欢简洁回答'), findsOneWidget);
      expect(find.text('项目用 Flutter'), findsNothing);

      // 清空搜索恢复全部
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('项目用 Flutter'), findsOneWidget);
    });

    testWidgets('单条删除：调用 provider.delete', (tester) async {
      provider.seed([memory('m1', '待删记忆')]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();

      expect(provider.deletedIds, ['m1']);
    });

    testWidgets('手动添加：输入内容保存 → provider.add 调用', (tester) async {
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, '例如：用户喜欢简洁回答'), '手动加的记忆');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.added, ['手动加的记忆']);
      expect(find.text('手动加的记忆'), findsOneWidget);
    });

    testWidgets('手动添加：空内容不调用 add', (tester) async {
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.added, isEmpty);
    });

    testWidgets('清空全部：确认后调用 deleteAll', (tester) async {
      provider.seed([memory('m1', 'a'), memory('m2', 'b')]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();

      // 确认弹窗出现
      expect(find.text('清空记忆'), findsOneWidget);
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();

      expect(provider.deletedAllCount, 1);
      expect(find.textContaining('AI 还没有记住任何东西'), findsOneWidget);
    });

    testWidgets('清空全部：取消不删除', (tester) async {
      provider.seed([memory('m1', 'a')]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(provider.deletedAllCount, 0);
      expect(find.text('a'), findsOneWidget);
    });
  });

  group('M1 策展台', () {
    testWidgets('tag 筛选 chips：动态 tag 渲染 + 点选过滤 + 再点取消', (tester) async {
      provider.seed([
        memory('m1', '喜欢简洁', tag: '偏好'),
        memory('m2', '在上海工作', tag: '背景'),
        memory('m3', '无标签记忆'),
      ]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      // chips 行出现：全部 + 偏好 + 背景（「偏好」chip + 卡片副标题 = 2 处）
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('偏好'), findsNWidgets(2));
      expect(find.text('背景'), findsNWidgets(2));

      // 点「偏好」chip（第一个匹配）→ 只剩该 tag 的记忆
      await tester.tap(find.text('偏好').first);
      await tester.pump();
      expect(find.text('喜欢简洁'), findsOneWidget);
      expect(find.text('在上海工作'), findsNothing);
      expect(find.text('无标签记忆'), findsNothing);

      // 再点「偏好」chip → 取消筛选恢复全部
      await tester.tap(find.text('偏好').first);
      await tester.pump();
      expect(find.text('在上海工作'), findsOneWidget);
      expect(find.text('无标签记忆'), findsOneWidget);
    });

    testWidgets('置顶分组：置顶条显示在置顶组最前', (tester) async {
      provider.seed([
        memory('m1', '普通记忆'),
        memory('m2', '置顶记忆', pinned: true),
      ]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      expect(find.textContaining('置顶（永久记忆'), findsOneWidget);
      expect(find.text('置顶记忆'), findsOneWidget);
      expect(find.text('普通记忆'), findsOneWidget);

      // 置顶组在普通组之前
      final pinnedY = tester.getTopLeft(find.text('置顶记忆')).dy;
      final normalY = tester.getTopLeft(find.text('普通记忆')).dy;
      expect(pinnedY, lessThan(normalY));
    });

    testWidgets('点置顶按钮：调用 setPinned(true)，再点取消', (tester) async {
      provider.seed([memory('m1', '待置顶')]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.push_pin_outlined));
      await tester.pump();
      expect(provider.pinCalls, [('m1', true)]);

      // 状态已变（fake provider 同步更新）→ 图标变实心，再点取消
      await tester.tap(find.byIcon(Icons.push_pin));
      await tester.pump();
      expect(provider.pinCalls, [('m1', true), ('m1', false)]);
    });

    testWidgets('编辑：弹窗预填原内容，保存调用 update', (tester) async {
      provider.seed([memory('m1', '原始内容', tag: '旧标签')]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      // 弹窗预填（「原始内容」同时出现在卡片与弹窗输入框 = 2 处）
      expect(find.text('编辑记忆'), findsOneWidget);
      expect(find.text('原始内容'), findsNWidgets(2));

      // 改内容与标签
      await tester.enterText(
          find.widgetWithText(TextField, '例如：用户喜欢简洁回答'), '改写内容');
      await tester.enterText(
          find.widgetWithText(TextField, '偏好 / 背景 / 习惯 / 其他'), '新标签');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.updateCalls, [('m1', '改写内容', '新标签')]);
      expect(find.text('改写内容'), findsOneWidget);
    });

    testWidgets('编辑：清空内容保存不调用 update', (tester) async {
      provider.seed([memory('m1', '原始内容')]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, '例如：用户喜欢简洁回答'), '   ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.updateCalls, isEmpty);
    });

    testWidgets('归档摘要行：无编辑按钮，有置顶/删除', (tester) async {
      provider.seed([
        memory('m1', '归档摘要内容', tag: Memory.archiveTag),
      ]);
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      expect(find.text('归档摘要内容'), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('手动添加：带标签保存 → add 收到 tag', (tester) async {
      await tester.pumpWidget(wrap(const MemoryPanel()));
      await tester.pump();

      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, '例如：用户喜欢简洁回答'), '带标签记忆');
      await tester.enterText(
          find.widgetWithText(TextField, '偏好 / 背景 / 习惯 / 其他'), '偏好');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.added, ['带标签记忆']);
      expect(provider.addedTags, ['偏好']);
    });
  });
}
