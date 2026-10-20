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

  final List<Memory> _store = [];
  bool _loaded = false;

  final List<String> added = [];
  final List<String> deletedIds = [];
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

Memory memory(String id, String content, {String? tag}) => Memory(
      id: id,
      content: content,
      tag: tag,
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
        child: MaterialApp(home: child),
      );

  group('MemoryPage', () {
    testWidgets('空态：显示引导文案', (tester) async {
      await tester.pumpWidget(wrap(const MemoryPage()));
      await tester.pump();

      expect(
          find.textContaining('AI 还没有记住任何东西'), findsOneWidget);
      expect(find.text('记忆管理'), findsOneWidget);
    });

    testWidgets('列表渲染：内容 + 标签副标题', (tester) async {
      provider.seed([
        memory('m1', '用户喜欢简洁回答', tag: '偏好'),
        memory('m2', '用户在上海工作'),
      ]);
      await tester.pumpWidget(wrap(const MemoryPage()));
      await tester.pump();

      expect(find.text('用户喜欢简洁回答'), findsOneWidget);
      expect(find.text('用户在上海工作'), findsOneWidget);
      expect(find.text('偏好'), findsOneWidget);
    });

    testWidgets('搜索过滤：关键词命中与清空', (tester) async {
      provider.seed([
        memory('m1', '用户喜欢简洁回答'),
        memory('m2', '项目用 Flutter'),
      ]);
      await tester.pumpWidget(wrap(const MemoryPage()));
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
      await tester.pumpWidget(wrap(const MemoryPage()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();

      expect(provider.deletedIds, ['m1']);
    });

    testWidgets('手动添加：输入内容保存 → provider.add 调用', (tester) async {
      await tester.pumpWidget(wrap(const MemoryPage()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, '例如：用户喜欢简洁回答'), '手动加的记忆');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.added, ['手动加的记忆']);
      expect(find.text('手动加的记忆'), findsOneWidget);
    });

    testWidgets('手动添加：空内容不调用 add', (tester) async {
      await tester.pumpWidget(wrap(const MemoryPage()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.added, isEmpty);
    });

    testWidgets('清空全部：确认后调用 deleteAll', (tester) async {
      provider.seed([memory('m1', 'a'), memory('m2', 'b')]);
      await tester.pumpWidget(wrap(const MemoryPage()));
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
      await tester.pumpWidget(wrap(const MemoryPage()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(provider.deletedAllCount, 0);
      expect(find.text('a'), findsOneWidget);
    });
  });
}
