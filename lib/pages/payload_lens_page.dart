import 'package:flutter/material.dart';

import '../providers/chat_provider.dart';
import '../widgets/token_usage_sheet.dart';

/// F5 上下文透视镜：只读展示下一轮请求将发送的完整 payload
///
/// 入口在 Token 用量 Sheet 底部「查看完整请求 payload」。
/// 头部元信息（模型/档位/温度/工具数）+ 消息卡片列表（角色徽章 +
/// 内容预览，点开全文）。数据来自 [ChatProvider.buildPayloadPreview]，
/// 与真实请求组装同源（复用 _buildApiMessages）。
class PayloadLensPage extends StatelessWidget {
  const PayloadLensPage({super.key, required this.chat});

  final ChatProvider chat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final payload = chat.buildPayloadPreview();

    return Scaffold(
      appBar: AppBar(title: const Text('上下文透视镜')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // ===== 头部元信息卡 =====
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('下一轮请求将发送', style: theme.textTheme.titleSmall),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MetaChip(
                        icon: Icons.tune,
                        label: '模型',
                        value: chat.model),
                    _MetaChip(
                        icon: Icons.bolt,
                        label: '档位',
                        value: chat.effectiveEffort),
                    _MetaChip(
                        icon: Icons.thermostat,
                        label: '温度',
                        value: chat.effectiveTemperature.toString()),
                    _MetaChip(
                        icon: Icons.build_outlined,
                        label: '工具',
                        value: '${chat.toolCount} 个'),
                    _MetaChip(
                        icon: Icons.format_list_numbered,
                        label: '消息',
                        value: '${payload.length} 条'),
                    _MetaChip(
                        icon: Icons.data_usage,
                        label: '估算输入',
                        value:
                            '~${formatTokenCount(estimatePromptTokens(payload))}'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ===== 消息卡片列表 =====
          for (var i = 0; i < payload.length; i++)
            _PayloadCard(index: i, message: payload[i]),
        ],
      ),
    );
  }
}

/// 头部元信息小胶囊
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: cs.primary),
          const SizedBox(width: 4),
          Text(
            '$label $value',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 单条 payload 消息卡片：角色徽章 + 内容预览（点开全文）
class _PayloadCard extends StatelessWidget {
  const _PayloadCard({required this.index, required this.message});

  final int index;
  final Map<String, Object?> message;

  (String, Color, IconData) get _role {
    return switch (message['role']) {
      'system' => ('system', Colors.deepPurple, Icons.settings_suggest_outlined),
      'user' => ('user', Colors.blue, Icons.person_outline),
      'tool' => ('tool', Colors.teal, Icons.build_outlined),
      _ => ('assistant', Colors.orange, Icons.smart_toy_outlined),
    };
  }

  /// 内容预览文本：字符串直接用；多模态数组拼 text 部分 + 图片占位
  String get _preview {
    final content = message['content'];
    if (content is String) return content;
    if (content is List) {
      final parts = <String>[];
      for (final part in content) {
        if (part is Map<String, dynamic>) {
          if (part['type'] == 'text') {
            parts.add(part['text'] as String? ?? '');
          } else if (part['type'] == 'image_url') {
            parts.add('[图片]');
          }
        }
      }
      return parts.join('\n');
    }
    return '';
  }

  /// tool_calls 摘要（assistant 发起工具调用的消息）
  List<String> get _toolCallSummaries {
    final calls = message['tool_calls'];
    if (calls is! List) return const [];
    return [
      for (final c in calls)
        if (c is Map<String, dynamic>)
          if (c['function'] is Map<String, dynamic>)
            '${(c['function'] as Map<String, dynamic>)['name']}(${(c['function'] as Map<String, dynamic>)['arguments']})',
    ];
  }

  void _openFullText(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.heightOf(context) * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('消息 #${index + 1} 全文',
                    style: theme.textTheme.titleMedium),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SelectableText(
                    _preview.isEmpty ? '（无文本内容）' : _preview,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(height: 1.6, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (roleLabel, roleColor, roleIcon) = _role;
    final preview = _preview;
    final toolCalls = _toolCallSummaries;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => _openFullText(context),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: roleColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(roleIcon, size: 11, color: roleColor),
                        const SizedBox(width: 3),
                        Text(
                          roleLabel,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: roleColor),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '#${index + 1}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right,
                      size: 16, color: cs.onSurfaceVariant),
                ],
              ),
              if (preview.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurface, height: 1.5),
                ),
              ],
              for (final tc in toolCalls) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.call_made, size: 12, color: cs.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        tc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.primary, fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
