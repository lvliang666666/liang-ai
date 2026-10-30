import 'package:flutter/material.dart';

import '../services/morning_briefing_service.dart';
import 'app_bottom_sheet.dart';

/// P1 晨间简报 Sheet：展示当天生成的个性化简报
///
/// 结构：问候语大字 → 五段卡片（黄历/灵签/记忆/上周今天）→
/// 底部「查看详情」展开玄学工具原文 + 生成来源标注。
/// 渲染数据 [MorningBriefing] 与生成服务解耦（widget 测试无需 DB/网络）。
Future<void> showMorningBriefingSheet(
  BuildContext context,
  MorningBriefing briefing,
) {
  return showAppBottomSheet(
    context: context,
    builder: (context) => MorningBriefingSheet(briefing: briefing),
  );
}

class MorningBriefingSheet extends StatelessWidget {
  const MorningBriefingSheet({super.key, required this.briefing});

  final MorningBriefing briefing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasDetail =
        briefing.huangliRaw.isNotEmpty || briefing.fortuneRaw.isNotEmpty;

    return SheetScaffold(
      title: '今日简报 · ${briefing.dateKey}',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          // 问候语：大字突出
          Text(
            briefing.greeting,
            key: const ValueKey('briefing-greeting'),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          // 生成来源标注（离线回退时提示）
          Text(
            briefing.fromLlm ? '为你生成' : '离线简报（网络不可用，素材直出）',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          if (briefing.almanac.isNotEmpty)
            _SectionCard(
              key: const ValueKey('briefing-almanac'),
              icon: Icons.calendar_today,
              title: '黄历',
              body: briefing.almanac,
            ),
          if (briefing.fortune.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionCard(
              key: const ValueKey('briefing-fortune'),
              icon: Icons.auto_awesome,
              title: '灵签',
              body: briefing.fortune,
            ),
          ],
          if (briefing.memory.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionCard(
              key: const ValueKey('briefing-memory'),
              icon: Icons.psychology,
              title: '记忆',
              body: briefing.memory,
            ),
          ],
          if (briefing.flashback.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionCard(
              key: const ValueKey('briefing-flashback'),
              icon: Icons.history,
              title: '上周今天',
              body: briefing.flashback,
            ),
          ],
          if (hasDetail) ...[
            const SizedBox(height: 12),
            _DetailExpander(briefing: briefing),
          ],
        ],
      ),
    );
  }
}

/// 单段卡片：图标 + 标题 + 正文
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// 「查看详情」展开区：黄历/灵签工具原文（等宽小字）
class _DetailExpander extends StatefulWidget {
  const _DetailExpander({required this.briefing});

  final MorningBriefing briefing;

  @override
  State<_DetailExpander> createState() => _DetailExpanderState();
}

class _DetailExpanderState extends State<_DetailExpander> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          key: const ValueKey('briefing-detail-toggle'),
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more,
              size: 18),
          label: Text(_expanded ? '收起详情' : '查看详情'),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              [
                if (widget.briefing.huangliRaw.isNotEmpty)
                  widget.briefing.huangliRaw,
                if (widget.briefing.fortuneRaw.isNotEmpty)
                  widget.briefing.fortuneRaw,
              ].join('\n\n'),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
            ),
          ),
      ],
    );
  }
}
