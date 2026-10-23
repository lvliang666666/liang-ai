import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import 'app_bottom_sheet.dart';

/// 名义上下文上限（水位条分母；F3 Token 水位仪表盘）
///
/// 真实上限随模型/网关配置浮动，这里取公司网关常用配置的名义值，
/// 仅作量级参考——UI 明确标注「名义值」。
const int kNominalContextLimit = 32000;

/// token 数格式化：千以下原样，以上 k 缩写（1234 → 1.2k，12345 → 12.3k）
String formatTokenCount(int tokens) {
  if (tokens < 1000) return '$tokens';
  var s = (tokens / 1000).toStringAsFixed(1);
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  return '${s}k';
}

/// 打开 Token 用量详情 Sheet（F3 水位仪表盘入口）
///
/// [onOpenPayload] 非空时底部显示「查看完整请求 payload」入口（F5 透视镜）。
Future<void> showTokenUsageSheet(
  BuildContext context,
  ChatProvider chat, {
  VoidCallback? onOpenPayload,
}) {
  return showAppBottomSheet(
    context: context,
    builder: (context) => TokenUsageSheet(
      chat: chat,
      onOpenPayload: onOpenPayload,
    ),
  );
}

/// 用量详情 Sheet：ListenableBuilder 订阅 provider，流式中数字实时跳动
class TokenUsageSheet extends StatelessWidget {
  const TokenUsageSheet({super.key, required this.chat, this.onOpenPayload});

  final ChatProvider chat;

  /// 「查看完整请求 payload」回调（F5 透视镜入口；null = 不显示）
  final VoidCallback? onOpenPayload;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) => TokenUsageView(
        data: TokenUsageData.fromChat(chat),
        onOpenPayload: onOpenPayload,
      ),
    );
  }
}

/// Sheet 渲染数据（与 provider 解耦，widget 测试无需 DB/网络）
class TokenUsageData {
  const TokenUsageData({
    required this.total,
    required this.input,
    required this.output,
    required this.lastPrompt,
    required this.messages,
  });

  factory TokenUsageData.fromChat(ChatProvider chat) {
    var input = 0;
    var output = 0;
    for (final m in chat.messages) {
      input += m.promptTokens ?? 0;
      output += m.completionTokens ?? 0;
    }
    return TokenUsageData(
      total: chat.totalTokens,
      input: input,
      output: output,
      lastPrompt: chat.lastPromptTokens,
      messages: chat.messages,
    );
  }

  /// 累计消耗（输入+输出）
  final int total;

  /// 输入合计
  final int input;

  /// 输出合计
  final int output;

  /// 最近一轮输入 token（null = 无记录）
  final int? lastPrompt;

  /// 全部落库消息（明细列表用）
  final List<ChatMessage> messages;
}

/// 用量详情视图：统计卡 + 上下文水位条 + 按消息明细
class TokenUsageView extends StatelessWidget {
  const TokenUsageView({super.key, required this.data, this.onOpenPayload});

  final TokenUsageData data;

  /// 「查看完整请求 payload」回调（null = 不显示入口）
  final VoidCallback? onOpenPayload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SheetScaffold(
      title: 'Token 用量',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          _StatsCard(
            key: const ValueKey('token-stats-card'),
            total: data.total,
            input: data.input,
            output: data.output,
          ),
          const SizedBox(height: 16),
          _WaterLevelBar(lastPrompt: data.lastPrompt),
          const SizedBox(height: 16),
          Text('消息明细', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          const _DetailHeader(),
          for (final m in data.messages) _DetailRow(message: m),
          if (onOpenPayload != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onOpenPayload,
              icon: const Icon(Icons.manage_search, size: 18),
              label: const Text('查看完整请求 payload'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 顶部统计卡：累计 / 输入 / 输出 三列
class _StatsCard extends StatelessWidget {
  const _StatsCard({
    super.key,
    required this.total,
    required this.input,
    required this.output,
  });

  final int total;
  final int input;
  final int output;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final valueStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.bold,
    );

    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: valueStyle?.copyWith(color: color ?? cs.onSurface)),
              const SizedBox(height: 2),
              Text(
                label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          cell('累计 token', formatTokenCount(total), color: cs.primary),
          Container(width: 1, height: 28, color: cs.outlineVariant),
          cell('输入', formatTokenCount(input)),
          Container(width: 1, height: 28, color: cs.outlineVariant),
          cell('输出', formatTokenCount(output)),
        ],
      ),
    );
  }
}

/// 上下文水位条：最近一轮输入 token vs 名义上限
class _WaterLevelBar extends StatelessWidget {
  const _WaterLevelBar({required this.lastPrompt});

  final int? lastPrompt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final used = lastPrompt ?? 0;
    final ratio = used / kNominalContextLimit;
    // 水位配色：>60% 转橙、>85% 转红（接近上限提醒）
    final color = ratio >= 0.85
        ? cs.error
        : ratio >= 0.6
            ? Colors.orange
            : cs.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('上下文水位', style: theme.textTheme.labelLarge),
            const Spacer(),
            Text(
              lastPrompt == null
                  ? '暂无数据'
                  : '${formatTokenCount(used)} / '
                      '${formatTokenCount(kNominalContextLimit)}（名义值）',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: lastPrompt == null ? 0 : ratio.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: cs.surfaceContainerHighest,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// 明细表头：角色 / 时间 / 输入 / 输出
class _DetailHeader extends StatelessWidget {
  const _DetailHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 56, child: Text('角色', style: style)),
          Expanded(child: Text('时间', style: style)),
          SizedBox(
              width: 56,
              child: Text('输入', style: style, textAlign: TextAlign.right)),
          SizedBox(
              width: 56,
              child: Text('输出', style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

/// 单条消息明细行
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.message});

  final ChatMessage message;

  (String, IconData) get _role {
    if (message.isUser) return ('你', Icons.person_outline);
    if (message.isToolResult) return ('工具', Icons.build_outlined);
    return ('AI', Icons.smart_toy_outlined);
  }

  /// 微信式时间：今天显示时分，昨天显示「昨天 时分」，更早显示日期
  String _timeLabel(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final hm = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    final diffDays = DateTime(now.year, now.month, now.day)
        .difference(DateTime(dt.year, dt.month, dt.day))
        .inDays;
    if (diffDays == 0) return hm;
    if (diffDays == 1) return '昨天 $hm';
    return '${dt.month}/${dt.day} $hm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (roleLabel, roleIcon) = _role;
    final muted = theme.textTheme.labelSmall
        ?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const []);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Row(
              children: [
                Icon(roleIcon, size: 13, color: cs.onSurfaceVariant),
                const SizedBox(width: 3),
                Text(roleLabel, style: theme.textTheme.labelMedium),
              ],
            ),
          ),
          Expanded(
            child: Text(_timeLabel(message.createdAt),
                style: muted, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 56,
            child: Text(
              message.promptTokens == null
                  ? '—'
                  : formatTokenCount(message.promptTokens!),
              style: muted,
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              message.completionTokens == null
                  ? '—'
                  : formatTokenCount(message.completionTokens!),
              style: muted,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
