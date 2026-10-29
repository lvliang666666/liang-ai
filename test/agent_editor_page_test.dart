import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/pages/agent_editor_page.dart';
import 'package:ai_chat_app/providers/http_tool_provider.dart';
import 'package:ai_chat_app/providers/agent_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/agent_service.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 假 AgentProvider：不碰真实 DB（sqflite_ffi 异步 IO 在 widget 测试
/// fake async 环境推不动，pop 永远等不到），create/update 同步完成并
/// 记录调用参数供断言。
class _FakeAgentProvider extends AgentProvider {
  _FakeAgentProvider()
      // create/update 已覆写，service 永不被调用，传单例占位即可
      : super(service: AgentService(database: DatabaseService.instance));

  final List<Agent> created = [];
  final List<Agent> updated = [];

  @override
  Future<Agent> create({
    required String name,
    required String prompt,
    String icon = '🤖',
    String description = '',
    double? temperature,
    String? effort,
    List<String>? toolNames,
  }) async {
    final agent = Agent(
      id: 'fake-${created.length}',
      name: name,
      icon: icon,
      description: description,
      prompt: prompt,
      temperature: temperature,
      effort: effort,
      toolNames: toolNames,
    );
    created.add(agent);
    return agent;
  }

  @override
  Future<void> update(Agent agent) async {
    updated.add(agent);
  }
}

void main() {
  late _FakeAgentProvider provider;

  setUp(() {
    provider = _FakeAgentProvider();
  });

  tearDown(() {
    provider.dispose();
  });

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<AgentProvider>.value(value: provider),
          // T1：编辑器工具列表会读 HttpToolProvider（测试无自定义工具）
          ChangeNotifierProvider<HttpToolProvider>(
            create: (_) => HttpToolProvider(
                database: DatabaseService.instance),
          ),
        ],
        child: MaterialApp(home: child),
      );

  /// 内置 Agent（只读查看用例）
  Agent builtinAgent() => Agent(
        id: 'builtin-1',
        name: '默认助手',
        prompt: '内置提示词',
        isBuiltin: true,
      );

  group('AgentEditorPage', () {
    testWidgets('新建默认全勾：直接保存 → toolNames == null', (tester) async {
      // 13 个工具超出默认测试窗口高度，ListView 懒构建导致部分条目
      // 不在树中——放大窗口让全部条目可见
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(const AgentEditorPage()));

      // 填名称（基本信息分区）
      await tester.enterText(
          find.widgetWithText(TextField, '名称'), '测试 Agent');
      await tester.pump();

      // 切到提示词分区填写（PageView 未缓存页不在树中，需先切页）
      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, '系统提示词（System Prompt）'), '你是测试');
      await tester.pump();

      // 切到可用工具分区确认全勾
      await tester.tap(find.text('可用工具'));
      await tester.pumpAndSettle();
      for (final t in builtinTools) {
        final tile = tester.widget<CheckboxListTile>(
          find.ancestor(
            of: find.text(t.name),
            matching: find.byType(CheckboxListTile),
          ),
        );
        expect(tile.value, isTrue, reason: '${t.name} 默认应勾选');
      }

      // 保存：假 Provider 同步完成，pop 在微任务后
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      // pop 回来了
      expect(find.byType(AgentEditorPage), findsNothing);

      // create 调用参数：toolNames == null（全勾语义）
      expect(provider.created, hasLength(1));
      final created = provider.created.single;
      expect(created.name, '测试 Agent');
      expect(created.toolNames, isNull);
      expect(created.prompt, '你是测试');
    });

    testWidgets('新建去勾一个工具：保存 → toolNames 为显式子集', (tester) async {
      await tester.pumpWidget(wrap(const AgentEditorPage()));

      await tester.enterText(
          find.widgetWithText(TextField, '名称'), '子集 Agent');
      await tester.pump();

      // 切到提示词分区填写
      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, '系统提示词（System Prompt）'), 'p');
      await tester.pump();

      // 切到可用工具分区，去勾第一个工具
      await tester.tap(find.text('可用工具'));
      await tester.pumpAndSettle();
      final removedTool = builtinTools.first;
      await tester.tap(find.text(removedTool.name));
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentEditorPage), findsNothing);

      expect(provider.created, hasLength(1));
      final created = provider.created.single;
      expect(created.toolNames, isNotNull);
      expect(created.toolNames!.length, builtinTools.length - 1);
      expect(created.toolNames, isNot(contains(removedTool.name)));
    });

    testWidgets('名称留空点保存：不 pop，仍在编辑页', (tester) async {
      await tester.pumpWidget(wrap(const AgentEditorPage()));

      // 只填提示词，名称留空（先切到提示词分区）
      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, '系统提示词（System Prompt）'), 'p');
      await tester.pump();

      await tester.tap(find.text('保存'));
      // Toast 走 Overlay：第 1 帧 post-frame 写入文案，第 2 帧才上屏
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 未 pop：编辑页还在
      expect(find.byType(AgentEditorPage), findsOneWidget);
      // 提示了名称错误（Toast 走 Overlay，文案在 post-frame 帧才上屏）
      expect(find.text('名称不能为空'), findsOneWidget);
      // 未触发 create
      expect(provider.created, isEmpty);

      // 收尾：让 Toast timer 走完，避免 pending timer 报错
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('编辑自定义 Agent：保存走 update，保留原 id', (tester) async {
      final original = Agent(
        id: 'custom-1',
        name: '旧名字',
        prompt: '旧提示词',
      );
      await tester.pumpWidget(wrap(AgentEditorPage(agent: original)));
      await tester.pumpAndSettle();

      // 改名称
      await tester.enterText(find.widgetWithText(TextField, '名称'), '新名字');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentEditorPage), findsNothing);
      expect(provider.updated, hasLength(1));
      final saved = provider.updated.single;
      expect(saved.id, 'custom-1'); // 编辑保留原 id
      expect(saved.name, '新名字');
      expect(provider.created, isEmpty); // 不走 create
    });

    testWidgets('内置 Agent：只读查看，无保存按钮', (tester) async {
      await tester.pumpWidget(wrap(AgentEditorPage(agent: builtinAgent())));
      await tester.pumpAndSettle();

      // 标题为查看
      expect(find.text('查看 Agent'), findsOneWidget);
      // 无保存按钮
      expect(find.text('保存'), findsNothing);
      // 名称输入框禁用
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, '名称'),
      );
      expect(nameField.enabled, isFalse);
      // 工具勾选框禁用（切到可用工具分区）
      await tester.tap(find.text('可用工具'));
      await tester.pumpAndSettle();
      final tile = tester.widget<CheckboxListTile>(
        find.ancestor(
          of: find.text(builtinTools.first.name),
          matching: find.byType(CheckboxListTile),
        ),
      );
      expect(tile.onChanged, isNull);

      // 取消退出
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentEditorPage), findsNothing);
    });
  });
}
