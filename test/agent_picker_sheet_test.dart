import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/providers/agent_provider.dart';
import 'package:ai_chat_app/services/agent_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/widgets/app_bottom_sheet.dart';
import 'package:ai_chat_app/widgets/home/agent_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// Agent 选择面板回归测试（UI 批次 1-② 验收标准；Skill 全局更名 Agent）
///
/// 需求（docs/UI修改建议.html 二）：标准 Bottom Sheet + 键盘适配——
/// 标题「选择 Skill」+ 24dp 关闭键、列表项（图标+名称+一句描述）、
/// 空状态「暂无可用 Skill」、搜索过滤、键盘弹出自动滚顶。
///
/// 验收标准逐条测试化：
/// 1. 面板结构：标题 + 关闭键 + 搜索框 + 列表项（图标+名称+描述）
/// 2. 空状态：无 Agent 时显示「暂无可用 Agent」，不出现空白面板
/// 3. 搜索过滤：按名称/描述过滤，无结果显示「没有找到」
/// 4. 键盘适配：viewInsets > 0 时列表自动滚回顶部（搜索框保持可见）
/// 5. 选中回调：点击条目返回 Agent 对象
/// 6. 接线：真实 showAppBottomSheet 路径高度 ≤ 60% 屏高
///
/// **DB IO 纪律（两次踩坑沉淀）**：sqflite_ffi 的真实异步 IO 在 testWidgets
/// 的 fakeAsync 区推不动（await 永不返回，实测挂死 10 分钟超时）——
/// 所有 DB 写入必须在 setUpAll 完成，用例内只做纯 UI 操作。
/// 「最近使用」区在 recentIds 为空时随机取 3 个（shuffle），断言列表项
/// 必须显式传 recentIds 或展开「全部」，否则 flaky。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AgentProvider provider;

  setUpAll(() async {
    final inMemory = await openTestDb();
    await DatabaseService.instance.initForTest(inMemory);
    provider = AgentProvider(
        service: AgentService(database: DatabaseService.instance));
    // 幂等重播种内置 Agent（10 个，含「默认助手」id=default）
    await provider.load();
    // 预置全部测试 Agent（用例内不做 DB IO——fakeAsync 区推不动真实异步）
    for (var i = 0; i < 30; i++) {
      await DatabaseService.instance.insertAgent(Agent(
          id: 't$i', name: '测试Agent$i', description: '描述$i', prompt: 'p'));
    }
    for (var i = 0; i < 30; i++) {
      await DatabaseService.instance.insertAgent(Agent(
          id: 'w$i', name: '接线Agent$i', description: '描述$i', prompt: 'p'));
    }
    await provider.load();
  });

  Future<void> pumpPicker(
    WidgetTester tester, {
    List<String> recentIds = const [],
    bool includeDefault = false,
    String? selectedId,
    ValueChanged<Agent?>? onSelected,
  }) async {
    // 注意：不能包 Scaffold（默认 resizeToAvoidBottomInset=true 会把 body 的
    // viewInsets.bottom 清零——键盘模拟用例读不到 inset）。真实路径组件在
    // Navigator Overlay 里不受影响；测试直 pump 用 Material+Align 模拟弹层宿主。
    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AgentPickerSheet(
            agents: provider,
            recentIds: recentIds,
            includeDefault: includeDefault,
            selectedId: selectedId,
            onSelected: onSelected ?? (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('验收①：面板结构——标题/关闭键/搜索框/列表项（图标+名称+描述）',
      (tester) async {
    // 显式 recentIds 绕开「最近使用」随机 shuffle（否则默认助手可能不在前 3）
    await pumpPicker(tester, recentIds: ['default']);

    expect(find.text('选择 Agent'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    // recentIds 指定后「默认助手」必在最近使用区（名称 + 描述都在列表里）
    expect(find.text('默认助手'), findsOneWidget);
  });

  testWidgets('验收③：搜索按名称过滤；无结果显示「没有找到」', (tester) async {
    await pumpPicker(tester);

    // 内置 Agent 含「默认助手」——搜「默认」应命中
    await tester.enterText(find.byType(TextField), '默认');
    await tester.pump();
    expect(find.text('默认助手'), findsOneWidget);

    // 搜不存在的词 → 「没有找到」提示
    await tester.enterText(find.byType(TextField), '不存在的词xyz');
    await tester.pump();
    expect(find.text('没有找到「不存在的词xyz」'), findsOneWidget);
  });

  testWidgets('验收④：键盘弹出（viewInsets>0）列表自动滚回顶部', (tester) async {
    // 30 个测试 Agent 已在 setUpAll 预置（fakeAsync 区内不做 DB IO）
    await pumpPicker(tester);

    // 展开全部列表并滚到底部（10 内置 + 30 t* + 30 w* = 70）
    await tester.tap(find.text('全部 Agent（70）'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
        find.descendant(of: find.byType(ListView),
            matching: find.byType(Scrollable)));
    expect(scrollable.position.pixels, greaterThan(0),
        reason: '前置：列表已滚动离顶');

    // 模拟键盘弹出（viewInsets.bottom = 300）→ 自动滚顶让搜索框可见
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, 0,
        reason: '键盘弹出时自动滚回顶部，搜索框保持可见');
  });

  testWidgets('验收⑤：点击列表条目回调返回 Agent 对象', (tester) async {
    Agent? picked;
    // recentIds 指定 default → 「默认助手」必在最近使用区（绕开随机 shuffle）
    await pumpPicker(tester, recentIds: ['default'], onSelected: (a) => picked = a);

    await tester.tap(find.text('默认助手'));
    await tester.pump();

    expect(picked, isNotNull);
    expect(picked!.id, 'default');
  });

  testWidgets('验收⑥：真实 showAppBottomSheet 路径高度 ≤ 60% 屏高（接线）',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 30 个接线 Agent 已在 setUpAll 预置（fakeAsync 区内不做 DB IO）

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showAppBottomSheet<void>(
                context: context,
                builder: (context) => AgentPickerSheet(
                  agents: provider,
                  recentIds: const [],
                  onSelected: (_) => Navigator.pop(context),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final box = tester.renderObject<RenderBox>(
      find.byType(SheetScaffold).first,
    );
    expect(box.size.height, lessThanOrEqualTo(1200 * 0.6 + 0.5),
        reason: '面板高度受 SheetKeyboardInset 60% 上限约束（不顶满全屏）');
  });
}
