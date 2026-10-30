import 'package:ai_chat_app/services/agent_parser.dart';
import 'package:ai_chat_app/services/agent_service.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

/// T4 结构化提取 Skill 资产测试
///
/// 四个提取类内置 Skill（账单/发票/名片/待办）：front matter 可解析、
/// tools 声明为 none（纯文本提取不碰工具）、prompt 含强 JSON 约束。
/// 资产在 AgentService.builtinAssets 清单中（启动重播种自动生效）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const extractorAssets = [
    ('assets/agents/bill_extractor.md', '账单提取'),
    ('assets/agents/invoice_extractor.md', '发票提取'),
    ('assets/agents/contact_extractor.md', '名片提取'),
    ('assets/agents/todo_extractor.md', '待办提取'),
  ];

  group('T4 提取 Skill 资产', () {
    for (final (asset, name) in extractorAssets) {
      test('$name：front matter 可解析 + tools none + JSON 约束', () async {
        final raw = await rootBundle.loadString(asset);
        final agent = AgentParser.parseToAgent(
            asset.split('/').last.replaceAll('.md', ''), raw);

        expect(agent.name, name);
        expect(agent.isBuiltin, isTrue);
        // 纯文本提取不碰工具：tools: none（空列表，非 null=全部）
        expect(agent.toolNames, isEmpty,
            reason: '$name 应声明 tools: none');
        // 强 JSON 输出约束：prompt 必须含「严格 JSON」与输出格式示例
        expect(agent.prompt, contains('严格 JSON'));
        expect(agent.prompt, contains('输出格式'));
        // 提取器通用纪律：不编造（待办提取用「不把闲聊当待办」同义表达）
        // + 空输入输出空结构
        final noFabrication = agent.prompt.contains('绝不编造') ||
            agent.prompt.contains('不把闲聊当待办');
        expect(noFabrication, isTrue, reason: '$name 缺不编造纪律');
        expect(agent.prompt, contains('[]'));
        // 低温：提取任务要确定性输出
        expect(agent.temperature, lessThanOrEqualTo(0.2));
      });
    }

    test('四个提取 Skill 已登记进 builtinAssets 清单', () {
      for (final (asset, _) in extractorAssets) {
        expect(AgentService.builtinAssets, contains(asset),
            reason: '$asset 未登记，启动重播种不会入库');
      }
    });

    test('提取 Skill 与既有内置 Skill 无 id 冲突', () {
      final ids = AgentService.builtinAssets
          .map((a) => a.split('/').last.replaceAll('.md', ''))
          .toList();
      expect(ids.toSet().length, ids.length, reason: '资产 id 重复会互相覆盖');
    });

    test('账单提取 prompt：金额符号约定（支出负/收入正）明确', () async {
      final raw = await rootBundle.loadString('assets/agents/bill_extractor.md');
      final agent = AgentParser.parseToAgent('bill_extractor', raw);
      expect(agent.prompt, contains('支出为负数'));
      expect(agent.prompt, contains('收入为正数'));
    });

    test('待办提取 prompt：owner/due/priority 字段规则完整', () async {
      final raw = await rootBundle.loadString('assets/agents/todo_extractor.md');
      final agent = AgentParser.parseToAgent('todo_extractor', raw);
      expect(agent.prompt, contains('owner'));
      expect(agent.prompt, contains('due'));
      expect(agent.prompt, contains('priority'));
      // 相对时间推算不出时放 uncertain，不硬编日期
      expect(agent.prompt, contains('uncertain'));
    });

    test('发票提取 prompt：reimbursable 布尔字段明确', () async {
      final raw =
          await rootBundle.loadString('assets/agents/invoice_extractor.md');
      final agent = AgentParser.parseToAgent('invoice_extractor', raw);
      expect(agent.prompt, contains('reimbursable'));
      expect(agent.prompt, contains('布尔'));
    });

    test('名片提取 prompt：联系方式字段不编造约束明确', () async {
      final raw =
          await rootBundle.loadString('assets/agents/contact_extractor.md');
      final agent = AgentParser.parseToAgent('contact_extractor', raw);
      expect(agent.prompt, contains('绝不猜测邮箱或电话'));
    });
  });
}
