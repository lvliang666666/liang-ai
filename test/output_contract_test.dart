import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/services/agent_parser.dart';
import 'package:ai_chat_app/services/output_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OutputContract.parse（front matter output 字段）', () {
    test('字段=显示名 逗号分隔', () {
      final c = OutputContract.parse('title=标题, total=合计金额');
      expect(c, isNotNull);
      expect(c!.fields.length, 2);
      expect(c.fields[0].name, 'title');
      expect(c.fields[0].label, '标题');
      expect(c.fields[1].name, 'total');
      expect(c.fields[1].label, '合计金额');
    });

    test('无显示名的段：显示名=字段名', () {
      final c = OutputContract.parse('count, total=合计');
      expect(c!.fields[0].name, 'count');
      expect(c.fields[0].label, 'count');
      expect(c.fields[1].label, '合计');
    });

    test('null/空/全坏段 → null（未声明）', () {
      expect(OutputContract.parse(null), isNull);
      expect(OutputContract.parse(''), isNull);
      expect(OutputContract.parse(' , , '), isNull);
      expect(OutputContract.parse('=只有显示名'), isNull);
    });

    test('按字段名去重保序', () {
      final c = OutputContract.parse('a=甲, b=乙, a=丙');
      expect(c!.fields.length, 2);
      expect(c.fields[0].label, '甲'); // 保序取首个
    });

    test('labelOf：声明字段返回显示名，未声明返回 null', () {
      final c = OutputContract.parse('title=标题');
      expect(c!.labelOf('title'), '标题');
      expect(c.labelOf('other'), isNull);
    });
  });

  group('OutputContract.instruction（格式指令）', () {
    test('包含 yaml 围栏示例与字段清单', () {
      final c = OutputContract.parse('count=张数, totalAmount=合计');
      final ins = c!.instruction;
      expect(ins, contains('【输出格式】'));
      expect(ins, contains('```yaml'));
      expect(ins, contains('count: （张数）'));
      expect(ins, contains('totalAmount: （合计）'));
    });
  });

  group('OutputContract.extract（从回复提取字段）', () {
    final contract = OutputContract.parse('count=张数, total=合计')!;

    test('yaml 围栏块解析成功', () {
      final reply = '分析如下：共 2 张发票。\n\n```yaml\ncount: 2\ntotal: 199.0\n```';
      final map = OutputContract.extract(reply, contract);
      expect(map, {'count': '2', 'total': '199.0'});
    });

    test('裸围栏块容错（模型忘写 yaml 标注）', () {
      final reply = '```\ncount: 3\ntotal: 88\n```';
      expect(OutputContract.extract(reply, contract),
          {'count': '3', 'total': '88'});
    });

    test('多围栏取最后一个', () {
      final reply = '```yaml\ncount: 1\n```\n更正：\n```yaml\ncount: 2\ntotal: 9\n```';
      expect(OutputContract.extract(reply, contract),
          {'count': '2', 'total': '9'});
    });

    test('续行缩进并入字段值', () {
      final reply = '```yaml\ncount: 2\ntotal: 199.0\n  （含税）\n```';
      expect(OutputContract.extract(reply, contract),
          {'count': '2', 'total': '199.0\n（含税）'});
    });

    test('未声明的字段不进 map（防噪音）', () {
      final reply = '```yaml\ncount: 2\ntotal: 9\nextra: 多余\n```';
      expect(OutputContract.extract(reply, contract),
          {'count': '2', 'total': '9'});
    });

    test('无围栏块 → null（降级 markdown）', () {
      expect(OutputContract.extract('普通回答，没有代码块', contract), isNull);
    });

    test('围栏里一个契约字段都没有 → null（降级）', () {
      final reply = '```yaml\nfoo: bar\n```';
      expect(OutputContract.extract(reply, contract), isNull);
    });

    test('字段值为空不进 map', () {
      final reply = '```yaml\ncount: 2\ntotal:\n```';
      expect(OutputContract.extract(reply, contract), {'count': '2'});
    });
  });

  group('AgentParser 集成（output 字段）', () {
    test('front matter output 解析进 Agent', () {
      final agent = AgentParser.parseToAgent('a1', '''---
name: 发票提取
icon: 📄
output: count=张数, totalAmount=合计
---
你是提取器。''');
      expect(agent.outputContract, isNotNull);
      expect(agent.outputContract!.fields.length, 2);
      expect(agent.outputContract!.fields[0].name, 'count');
    });

    test('未声明 output → null', () {
      final agent = AgentParser.parseToAgent('a1', '''---
name: 助手
---
你好。''');
      expect(agent.outputContract, isNull);
    });

    test('分享码 roundtrip：output 输出且可解析回', () {
      final agent = Agent(
        id: 'a1',
        name: '提取',
        prompt: '你是提取器',
        outputContract:
            OutputContract.parse('count=张数, totalAmount=合计'),
      );
      final code = AgentParser.toShareCode(agent);
      expect(code, contains('output: count=张数, totalAmount=合计'));
      final restored = AgentParser.fromShareCode('a2', code);
      expect(restored.outputContract, isNotNull);
      expect(restored.outputContract!.fields[1].label, '合计');
    });

    test('未声明的 Agent 分享码不输出 output 行', () {
      final agent = Agent(id: 'a1', name: 'x', prompt: 'p');
      expect(AgentParser.toShareCode(agent), isNot(contains('output:')));
    });
  });
}
