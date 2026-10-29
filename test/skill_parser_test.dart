import 'package:ai_chat_app/models/skill.dart';
import 'package:ai_chat_app/services/skill_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SkillParser front matter', () {
    test('完整字段解析（含 tools 子集）', () {
      const raw = '''
---
name: 技术架构师
icon: 🏗️
description: 严谨的系统设计专家
temperature: 0.3
effort: high
tools: calculate, get_current_time
---
你是资深架构师。
''';
      final r = SkillParser.parse(raw);
      expect(r.name, '技术架构师');
      expect(r.icon, '🏗️');
      expect(r.description, '严谨的系统设计专家');
      expect(r.temperature, 0.3);
      expect(r.effort, 'high');
      expect(r.toolNames, ['calculate', 'get_current_time']);
      expect(r.prompt, '你是资深架构师。');
    });

    test('tools: none → 空列表（无工具）', () {
      const raw = '''
---
name: 翻译官
tools: none
---
你是翻译。
''';
      final r = SkillParser.parse(raw);
      expect(r.toolNames, isEmpty);
    });

    test('tools: 空值 → 空列表（无工具）', () {
      const raw = '''
---
name: 文案
tools:
---
你是文案。
''';
      final r = SkillParser.parse(raw);
      expect(r.toolNames, isEmpty);
    });

    test('tools 键缺省 → null（全部工具）', () {
      const raw = '''
---
name: 默认助手
---
你是默认助手。
''';
      final r = SkillParser.parse(raw);
      expect(r.toolNames, isNull);
    });

    test('无 front matter → 整体视为 prompt', () {
      const raw = '直接就是提示词';
      final r = SkillParser.parse(raw);
      expect(r.prompt, '直接就是提示词');
      expect(r.name, isNull);
      expect(r.toolNames, isNull);
    });

    test('有开头无结尾 front matter 容错', () {
      const raw = '---\nname: 残缺文档';
      final r = SkillParser.parse(raw);
      expect(r.prompt, raw);
    });

    test('值带引号剥离', () {
      const raw = '''
---
name: "引号名字"
tools: 'calculate'
---
正文
''';
      final r = SkillParser.parse(raw);
      expect(r.name, '引号名字');
      expect(r.toolNames, ['calculate']);
    });

    test('parseToSkill 生成完整 Skill（缺省字段回退）', () {
      const raw = '''
---
name: 学习导师
tools: calculate
---
你是导师。
''';
      final skill = SkillParser.parseToSkill('tutor', raw);
      expect(skill.id, 'tutor');
      expect(skill.name, '学习导师');
      expect(skill.icon, '🤖'); // 缺省回退
      expect(skill.toolNames, ['calculate']);
      expect(skill.isBuiltin, isTrue);
    });

    test('parseToSkill 自定义标记', () {
      final skill = SkillParser.parseToSkill('x', '正文', isBuiltin: false);
      expect(skill.isBuiltin, isFalse);
      expect(skill.name, 'x'); // 无 name 时回退 id
    });
  });

  group('T3 Skill 分享码', () {
    test('toShareCode → fromShareCode 往返一致（全字段）', () {
      final skill = Skill(
        id: 'src',
        name: '技术架构师',
        icon: '🏗️',
        description: '严谨的系统设计专家',
        prompt: '你是资深架构师。',
        temperature: 0.3,
        effort: 'high',
        toolNames: ['calculate', 'get_current_time'],
      );
      final code = SkillParser.toShareCode(skill);
      expect(code.startsWith('---'), isTrue);

      final restored = SkillParser.fromShareCode('dst', code);
      expect(restored.name, '技术架构师');
      expect(restored.icon, '🏗️');
      expect(restored.description, '严谨的系统设计专家');
      expect(restored.prompt, '你是资深架构师。');
      expect(restored.temperature, 0.3);
      expect(restored.effort, 'high');
      expect(restored.toolNames, ['calculate', 'get_current_time']);
      expect(restored.isBuiltin, isFalse);
      expect(restored.id, 'dst');
    });

    test('toolNames null（全部工具）→ 分享码不含 tools 行 → 导回 null', () {
      final skill = Skill(id: 'a', name: 'N', prompt: 'P');
      final code = SkillParser.toShareCode(skill);
      expect(code.contains('tools:'), isFalse);
      expect(SkillParser.fromShareCode('b', code).toolNames, isNull);
    });

    test('toolNames []（无工具）→ tools: none → 导回空列表', () {
      final skill = Skill(id: 'a', name: 'N', prompt: 'P', toolNames: []);
      final code = SkillParser.toShareCode(skill);
      expect(code.contains('tools: none'), isTrue);
      expect(SkillParser.fromShareCode('b', code).toolNames, isEmpty);
    });

    test('缺省字段不输出行；导回回退默认值', () {
      final skill = Skill(id: 'a', name: 'N', prompt: 'P');
      final code = SkillParser.toShareCode(skill);
      expect(code.contains('temperature:'), isFalse);
      expect(code.contains('effort:'), isFalse);
      expect(code.contains('description:'), isFalse);
      final restored = SkillParser.fromShareCode('b', code);
      expect(restored.temperature, isNull);
      expect(restored.effort, isNull);
      expect(restored.description, '');
      expect(restored.icon, '🤖');
    });

    test('无 front matter 的纯正文分享码：name 回退「导入的 Skill」', () {
      final restored = SkillParser.fromShareCode('b', '只有正文没有头');
      expect(restored.name, '导入的 Skill');
      expect(restored.prompt, '只有正文没有头');
      expect(restored.isBuiltin, isFalse);
    });

    test('与内置资产格式互通：解析 default.md 同构文本', () {
      const raw = '''
---
name: 默认助手
icon: 🤖
description: 通用智能助手，均衡可靠，适合日常问答
---
你是 Liang AI 的默认助手。
''';
      final restored = SkillParser.fromShareCode('b', raw);
      expect(restored.name, '默认助手');
      expect(restored.description, '通用智能助手，均衡可靠，适合日常问答');
      expect(restored.toolNames, isNull); // 资产未声明 tools = 全部
    });
  });
}
