import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/output_contract.dart';
import '../../utils/haptics.dart';
import 'app_toast.dart';

/// F10 输出契约专属卡片：Skill 声明 output 且回复含合法 yaml 块时，
/// 用字段行式布局替代 markdown 正文（结构化结果一眼可读）。
///
/// 降级语义：解析失败/未声明 → 调用方照常渲染 markdown，卡片是增强
/// 不是门槛，绝不丢内容。yaml 块仍在正文里（markdown 渲染为代码块），
/// 卡片是「额外视图」而非「替换」——正文保留完整上下文。
///
/// 布局：顶部「结构化结果」徽标 + 每字段一行（显示名 + 值，值可换行），
/// 底色 primaryContainer 微调与普通气泡区分。
class OutputContractCard extends StatelessWidget {
  const OutputContractCard({
    super.key,
    required this.contract,
    required this.values,
  });

  final OutputContract contract;
  final Map<String, String> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 只渲染契约声明且有值的字段（保序）
    final rows = [
      for (final f in contract.fields)
        if (values[f.name]?.trim().isNotEmpty ?? false)
          (field: f, value: values[f.name]!.trim()),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 徽标行：结构化结果（与来源徽标同款视觉语言）
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.fact_check_outlined,
                  size: 13, color: cs.primary),
              const SizedBox(width: 4),
              Text('结构化结果',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 6),
          // 字段行：显示名（固定宽）+ 值（可换行，长值可选中复制）
          for (final (i, row) in rows.indexed) ...[
            if (i > 0) const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _labelWidth(row.field.label),
                  child: Text(
                    row.field.label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onLongPress: () => _copyValue(context, row.value),
                    child: Text(
                      row.value,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 标签列宽：最长显示名 4 字内统一 4 字宽，超长自适应
  double _labelWidth(String label) {
    final len = label.characters.length;
    return len <= 4 ? 56 : 56 + (len - 4) * 14.0;
  }

  Future<void> _copyValue(BuildContext context, String value) async {
    Haptics.medium();
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      showAppToast(context, '已复制');
    }
  }
}
