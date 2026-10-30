import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/services/skill_variables.dart';
import 'package:ai_chat_app/widgets/skill_variables_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Agent agentWithAll() => Agent(
        id: 'a1',
        name: '周报助手',
        icon: '📊',
        prompt: '你是{{tone}}的周报写手，今天{{date}}，主题：{{topic}}',
        personas: const [
          SkillPersona('正式', '正式商务'),
          SkillPersona('轻松', '轻松口语'),
        ],
      );

  Agent agentPlain() => Agent(
        id: 'a2',
        name: '翻译',
        icon: '🌐',
        prompt: '把用户输入翻译成英文',
      );

  Future<void> openSheet(WidgetTester tester, Agent agent,
      {Map<String, String> initial = const {}}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showSkillVariablesSheet(context,
                  agent: agent, initial: initial),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('变量表单：每个自定义变量一个输入框，内置变量不出现', (tester) async {
    await openSheet(tester, agentWithAll());

    // 自定义变量 tone/topic 有输入框
    expect(find.widgetWithText(TextField, 'tone'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'topic'), findsOneWidget);
    // 内置变量 date 不出现
    expect(find.text('date'), findsNothing);
    // 人格预设 chips 出现
    expect(find.text('正式'), findsOneWidget);
    expect(find.text('轻松'), findsOneWidget);
  });

  testWidgets('确认返回变量值 map；选中预设写入 persona 变量', (tester) async {
    Map<String, String>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                result = await showSkillVariablesSheet(context,
                    agent: agentWithAll());
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 填变量 + 选预设（sheet 内容超 60% 屏高，先滚到可见再点）
    await tester.enterText(find.widgetWithText(TextField, 'tone'), '严谨');
    await tester.enterText(find.widgetWithText(TextField, 'topic'), 'Q4 复盘');
    await tester.ensureVisible(find.text('轻松'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('轻松'));
    await tester.pump();
    await tester.ensureVisible(find.text('开始对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!['tone'], '严谨');
    expect(result!['topic'], 'Q4 复盘');
    expect(result!['persona'], '轻松口语'); // 预设=变量值
  });

  testWidgets('initial 预填上次值', (tester) async {
    await openSheet(tester, agentWithAll(),
        initial: {'tone': '幽默', 'topic': '年度总结'});
    expect(find.text('幽默'), findsOneWidget);
    expect(find.text('年度总结'), findsOneWidget);
  });

  testWidgets('无变量无预设：显示空态文案', (tester) async {
    await openSheet(tester, agentPlain());
    expect(find.text('该助手没有可配置的变量'), findsOneWidget);
  });

  testWidgets('预设可取消选中（再点一次取消）', (tester) async {
    Map<String, String>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                result = await showSkillVariablesSheet(context,
                    agent: agentWithAll());
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('正式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正式'));
    await tester.pump();
    await tester.tap(find.text('正式')); // 再点取消
    await tester.pump();
    await tester.ensureVisible(find.text('开始对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.containsKey('persona'), isFalse);
  });
}
