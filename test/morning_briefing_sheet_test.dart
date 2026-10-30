import 'package:ai_chat_app/services/morning_briefing_service.dart';
import 'package:ai_chat_app/widgets/morning_briefing_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// P1 晨间简报 Sheet UI 测试
///
/// 核心行为：
/// - 五段卡片按内容显隐（空段不渲染）
/// - 问候语大字 + 生成来源标注（LLM/离线）
/// - 「查看详情」展开玄学工具原文，再点收起
void main() {
  const llmBriefing = MorningBriefing(
    dateKey: '2026-10-30',
    greeting: '早上好，今天也要加油',
    almanac: '宜出行会友，忌动土开仓',
    fortune: '上签，宜稳步推进',
    memory: '你最近在准备考试，加油',
    flashback: '上周今天聊了报销流程',
    huangliRaw: '【黄历】2026 年 10 月 30 日\n宜：出行、会友\n忌：动土、开仓',
    fortuneRaw: '【观音灵签】第 01 签 · 上上签',
    fromLlm: true,
  );

  Future<void> pumpSheet(WidgetTester tester, MorningBriefing briefing) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MorningBriefingSheet(briefing: briefing),
      ),
    ));
    await tester.pump();
  }

  group('LLM 简报渲染', () {
    testWidgets('五段卡片齐全 + 问候语 + 来源标注', (tester) async {
      await pumpSheet(tester, llmBriefing);

      expect(find.text('今日简报 · 2026-10-30'), findsOneWidget);
      expect(find.text('早上好，今天也要加油'), findsOneWidget);
      expect(find.text('为你生成'), findsOneWidget);
      expect(find.byKey(const ValueKey('briefing-almanac')), findsOneWidget);
      expect(find.byKey(const ValueKey('briefing-fortune')), findsOneWidget);
      expect(find.byKey(const ValueKey('briefing-memory')), findsOneWidget);
      expect(find.byKey(const ValueKey('briefing-flashback')), findsOneWidget);
    });

    testWidgets('查看详情：展开玄学原文，再点收起', (tester) async {
      await pumpSheet(tester, llmBriefing);

      // 未展开：原文不可见
      expect(find.textContaining('【黄历】2026 年 10 月 30 日'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('briefing-detail-toggle')));
      await tester.pumpAndSettle();

      expect(find.textContaining('【黄历】2026 年 10 月 30 日'), findsOneWidget);
      expect(find.textContaining('第 01 签'), findsOneWidget);
      expect(find.text('收起详情'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('briefing-detail-toggle')));
      await tester.pumpAndSettle();

      expect(find.textContaining('【黄历】2026 年 10 月 30 日'), findsNothing);
    });
  });

  group('空段显隐', () {
    testWidgets('memory/flashback 为空：对应卡片不渲染', (tester) async {
      await pumpSheet(tester, const MorningBriefing(
        dateKey: '2026-10-30',
        greeting: '早上好',
        almanac: '宜出行',
        fortune: '中签',
        memory: '',
        flashback: '',
        huangliRaw: '【黄历】x',
        fortuneRaw: '',
        fromLlm: true,
      ));

      expect(find.byKey(const ValueKey('briefing-almanac')), findsOneWidget);
      expect(find.byKey(const ValueKey('briefing-fortune')), findsOneWidget);
      expect(find.byKey(const ValueKey('briefing-memory')), findsNothing);
      expect(find.byKey(const ValueKey('briefing-flashback')), findsNothing);
    });

    testWidgets('无玄学原文：不显示「查看详情」入口', (tester) async {
      await pumpSheet(tester, const MorningBriefing(
        dateKey: '2026-10-30',
        greeting: '早上好',
        almanac: '宜出行',
        fortune: '',
        memory: '',
        flashback: '',
        huangliRaw: '',
        fortuneRaw: '',
        fromLlm: false,
      ));

      expect(find.byKey(const ValueKey('briefing-detail-toggle')),
          findsNothing);
    });
  });

  group('离线回退渲染', () {
    testWidgets('fromLlm=false：标注「离线简报」', (tester) async {
      await pumpSheet(tester, const MorningBriefing(
        dateKey: '2026-10-30',
        greeting: '早上好，新的一天',
        almanac: '宜：出行；忌：动土',
        fortune: '第 42 签 · 中签',
        memory: '记得这些：\n- 用户喜欢简洁回答',
        flashback: '上周今天聊过：报销流程讨论',
        huangliRaw: '【黄历】x',
        fortuneRaw: '【观音灵签】y',
        fromLlm: false,
      ));

      expect(find.text('离线简报（网络不可用，素材直出）'), findsOneWidget);
      expect(find.text('早上好，新的一天'), findsOneWidget);
    });
  });
}
