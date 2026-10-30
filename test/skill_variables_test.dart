import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/services/agent_parser.dart';
import 'package:ai_chat_app/services/skill_variables.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SkillVariables.extractCustom 变量提取', () {
    test('提取单个自定义变量', () {
      expect(SkillVariables.extractCustom('你是{{风格}}助手'), ['风格']);
    });

    test('多个变量去重保序', () {
      final vars = SkillVariables.extractCustom(
          '{{a}} 和 {{b}}，再来一次 {{a}}，最后 {{c}}');
      expect(vars, ['a', 'b', 'c']);
    });

    test('内置变量排除', () {
      final vars = SkillVariables.extractCustom(
          '今天是 {{date}} {{weekday}}，现在 {{time}}，主题 {{topic}}');
      expect(vars, ['topic']);
    });

    test('无变量返回空', () {
      expect(SkillVariables.extractCustom('普通提示词'), isEmpty);
      expect(SkillVariables.extractCustom(''), isEmpty);
    });

    test('坏形式不误匹配', () {
      expect(SkillVariables.extractCustom('{{ }}'), isEmpty);
      expect(SkillVariables.extractCustom('{{含 空格}}'), isEmpty);
      expect(SkillVariables.extractCustom('{单括号}'), isEmpty);
    });
  });

  group('SkillVariables.render 变量替换', () {
    test('自定义变量替换为填写值', () {
      final out = SkillVariables.render(
        '你是{{风格}}助手，主题是{{topic}}',
        values: {'风格': '严谨', 'topic': '物理'},
      );
      expect(out, '你是严谨助手，主题是物理');
    });

    test('未填写的变量替换为空串', () {
      final out = SkillVariables.render('你是{{风格}}助手', values: {});
      expect(out, '你是助手');
    });

    test('内置变量按时间求值', () {
      final out = SkillVariables.render(
        '今天 {{date}}（{{weekday}}）{{time}}',
        now: DateTime(2026, 10, 30, 14, 5), // 周五
      );
      expect(out, '今天 2026-10-30（周五）14:05');
    });

    test('替换值里的花括号不被二次展开', () {
      final out = SkillVariables.render(
        '值是{{v}}',
        values: {'v': '{{date}}'},
      );
      expect(out, '值是{{date}}');
    });

    test('无变量 prompt 原样返回', () {
      const p = '普通提示词';
      expect(SkillVariables.render(p), p);
    });
  });

  group('SkillVariables.parsePersonas 预设解析', () {
    test('标准格式解析', () {
      final ps = SkillVariables.parsePersonas('正式=正式商务,轻松=轻松口语');
      expect(ps, hasLength(2));
      expect(ps[0].name, '正式');
      expect(ps[0].value, '正式商务');
      expect(ps[1].name, '轻松');
    });

    test('坏段跳过（无 = /空名/空值）', () {
      final ps = SkillVariables.parsePersonas('没有等号,=空名,正式=,=值,好=好的');
      expect(ps, hasLength(1));
      expect(ps.first.name, '好');
    });

    test('null/空串返回空清单', () {
      expect(SkillVariables.parsePersonas(null), isEmpty);
      expect(SkillVariables.parsePersonas(''), isEmpty);
      expect(SkillVariables.parsePersonas('  '), isEmpty);
    });

    test('重复名称后者覆盖', () {
      final ps = SkillVariables.parsePersonas('A=第一,A=第二');
      expect(ps, hasLength(1));
      expect(ps.first.value, '第二');
    });
  });

  group('AgentParser personas 集成', () {
    test('front matter personas 解析进 Agent', () {
      final agent = AgentParser.parseToAgent('t', '''---
name: 写作助手
personas: 正式=正式商务,轻松=轻松口语
---
你是写作助手，当前风格：{{persona}}''');
      expect(agent.personas, hasLength(2));
      expect(agent.personas[0].name, '正式');
      expect(agent.customVariables, ['persona']);
    });

    test('无 personas 声明 = 空清单（老资产零影响）', () {
      final agent = AgentParser.parseToAgent('t', '''---
name: 默认助手
---
你是默认助手''');
      expect(agent.personas, isEmpty);
    });

    test('分享码往返：personas 序列化与解析对称', () {
      final agent = Agent(
        id: 'a1',
        name: '写手',
        prompt: '风格 {{persona}}',
        personas: const [SkillPersona('正式', '正式商务')],
      );
      final code = AgentParser.toShareCode(agent);
      expect(code, contains('personas: 正式=正式商务'));
      final imported = AgentParser.fromShareCode('a2', code);
      expect(imported.personas, hasLength(1));
      expect(imported.personas.first.value, '正式商务');
    });

    test('toShareCode 无 personas 不输出该行', () {
      final code = AgentParser.toShareCode(
          Agent(id: 'a', name: 'x', prompt: 'p'));
      expect(code, isNot(contains('personas')));
    });
  });
}
