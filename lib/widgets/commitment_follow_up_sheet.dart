import 'package:flutter/material.dart';

import '../models/commitment.dart';
import '../services/commitment_service.dart';
import '../services/database_service.dart';
import '../utils/haptics.dart';
import 'app_bottom_sheet.dart';
import 'app_toast.dart';

/// P3 承诺跟进 Sheet：展示到期未完成的承诺，逐条处理
///
/// 结构：说明行（到期扫描语义）→ 承诺卡片列表（跟进语 + 承诺内容 +
/// 到期日 + 三个操作按钮）。
/// 操作语义（防打扰是生命线）：
/// - 继续聊：跳回来源会话（会话已删则提示）
/// - 已完成：状态置 done（不再提醒）
/// - 忽略：状态置 dismissed（用户明确不想被跟进，永不提醒）
/// 全部处理完自动关闭；点遮罩关闭 = 剩余承诺保持待跟进（明天再问）。
/// [onSettle] 落库回调（null = 默认写 DatabaseService；测试注入假实现）。
Future<Commitment?> showCommitmentFollowUpSheet(
  BuildContext context,
  List<Commitment> commitments,
) {
  return showAppBottomSheet<Commitment>(
    context: context,
    builder: (context) => CommitmentFollowUpSheet(commitments: commitments),
  );
}

class CommitmentFollowUpSheet extends StatefulWidget {
  const CommitmentFollowUpSheet({
    super.key,
    required this.commitments,
    this.onSettle,
  });

  final List<Commitment> commitments;

  /// 状态落库回调（commitment, status）；null = 写 DatabaseService 单例
  final Future<void> Function(Commitment, String)? onSettle;

  @override
  State<CommitmentFollowUpSheet> createState() =>
      _CommitmentFollowUpSheetState();
}

class _CommitmentFollowUpSheetState extends State<CommitmentFollowUpSheet> {
  late final List<Commitment> _remaining;

  @override
  void initState() {
    super.initState();
    _remaining = List.of(widget.commitments);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SheetScaffold(
      title: '承诺跟进',
      child: _remaining.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.task_alt, size: 40, color: cs.primary),
                  const SizedBox(height: 12),
                  Text('都处理完了，没有待跟进的承诺',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                Text(
                  '这些事到日子了，看看进展？',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                for (final c in _remaining) ...[
                  _CommitmentCard(
                    commitment: c,
                    onContinue: () => _continueChat(c),
                    onDone: () => _settle(c, Commitment.statusDone),
                    onDismiss: () => _settle(c, Commitment.statusDismissed),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }

  /// 继续聊：跳回来源会话（由宿主经 onContinueChat 处理；这里只关 Sheet）
  void _continueChat(Commitment c) {
    Haptics.light();
    Navigator.pop(context, c);
  }

  /// 已完成/忽略：落库 + 从列表移除；全部处理完自动关闭
  Future<void> _settle(Commitment c, String status) async {
    Haptics.light();
    final updated = c.copyWith(
      status: status,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final settle = widget.onSettle;
    if (settle != null) {
      await settle(updated, status);
    } else {
      await DatabaseService.instance.updateCommitment(updated);
    }
    if (!mounted) return;
    setState(() => _remaining.remove(c));
    showAppToast(context, status == Commitment.statusDone ? '已完成' : '已忽略');
    if (_remaining.isEmpty && mounted) {
      Navigator.pop(context);
    }
  }
}

/// 单条承诺卡片：跟进语突出 + 承诺内容 + 到期日 + 操作按钮行
class _CommitmentCard extends StatelessWidget {
  const _CommitmentCard({
    required this.commitment,
    required this.onContinue,
    required this.onDone,
    required this.onDismiss,
  });

  final Commitment commitment;
  final VoidCallback onContinue;
  final VoidCallback onDone;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 跟进语（LLM 生成或本地模板，突出显示）
          Text(
            commitment.followUp ??
                CommitmentService.localFollowUp(commitment),
            key: ValueKey('follow-up-${commitment.id}'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          // 承诺原文 + 到期日
          Text(
            [
              commitment.content,
              if (commitment.dueDate != null) '到期：${commitment.dueDate}',
            ].join(' · '),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          // 操作行：继续聊（主操作）+ 已完成 + 忽略
          Row(
            children: [
              FilledButton.icon(
                key: ValueKey('continue-${commitment.id}'),
                onPressed: onContinue,
                icon: const Icon(Icons.chat_bubble_outline, size: 16),
                label: const Text('继续聊'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: ValueKey('done-${commitment.id}'),
                onPressed: onDone,
                child: const Text('已完成'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const Spacer(),
              TextButton(
                key: ValueKey('dismiss-${commitment.id}'),
                onPressed: onDismiss,
                child: Text('忽略',
                    style: TextStyle(color: cs.onSurfaceVariant)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
