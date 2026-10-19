import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/tool_call.dart';
import '../providers/theme_provider.dart';
import '../utils/haptics.dart';

/// 工具调用折叠卡片（仿 ThinkingBlock 模式）
///
/// 展示一次 agentic 轮中的全部工具调用与结果：
/// - 执行中：旋转图标 + 「正在调用 xxx…」，默认展开
/// - 完成：✓/✗ + 工具名摘要，默认折叠，点击展开看参数/结果
/// - 失败：✗ + 红色调错误摘要
class ToolCallBlock extends StatefulWidget {
  const ToolCallBlock({
    super.key,
    required this.calls,
    required this.results,
    required this.executing,
  });

  /// 本轮模型发起的工具调用
  final List<ToolCall> calls;

  /// 已完成的执行结果（与 [calls] 按 callId 对应；执行中可能为空）
  final List<ToolCallResult> results;

  /// 是否正在执行工具（toolCalling 状态）
  final bool executing;

  @override
  State<ToolCallBlock> createState() => _ToolCallBlockState();
}

class _ToolCallBlockState extends State<ToolCallBlock> {
  // 执行中默认展开，完成后折叠
  late bool _expanded = widget.executing;
  bool _userToggled = false;

  @override
  void didUpdateWidget(covariant ToolCallBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 执行→完成时自动折叠（用户未手动操作过）
    if (!_userToggled && oldWidget.executing && !widget.executing) {
      _expanded = false;
    }
  }

  /// 按调用 ID 索引结果
  ToolCallResult? _resultFor(ToolCall call) {
    for (final r in widget.results) {
      if (r.callId == call.id) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final radius = context.read<ThemeProvider>().cornerRadius;

    // 摘要行文案：执行中 / 完成（含失败数）
    final failedCount =
        widget.results.where((r) => r.isError).length;
    final headerText = widget.executing
        ? '正在调用工具…'
        : failedCount > 0
            ? '已调用工具（$failedCount 项失败）'
            : '已调用工具（${widget.calls.length} 项）';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
            onTap: () {
              Haptics.light();
              _userToggled = true;
              setState(() => _expanded = !_expanded);
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  if (widget.executing)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        failedCount > 0
                            ? Icons.error_outline
                            : Icons.build_outlined,
                        size: 18,
                        color: failedCount > 0
                            ? colorScheme.error
                            : colorScheme.primary,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      headerText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: failedCount > 0
                            ? colorScheme.error
                            : colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _expanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final call in widget.calls)
                    _ToolCallRow(
                      call: call,
                      result: _resultFor(call),
                    ),
                ],
              ),
            ),
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// 单个工具调用行：名称 + 参数摘要；展开后显示完整参数与结果
class _ToolCallRow extends StatelessWidget {
  const _ToolCallRow({required this.call, this.result});

  final ToolCall call;
  final ToolCallResult? result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isError = result?.isError ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result == null
                    ? Icons.schedule
                    : isError
                        ? Icons.close
                        : Icons.check,
                size: 14,
                color: result == null
                    ? colorScheme.onSurfaceVariant
                    : isError
                        ? colorScheme.error
                        : colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  call.name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
              if (call.argumentsPreview.isNotEmpty)
                Flexible(
                  child: Text(
                    call.argumentsPreview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
          // 结果文本（失败红色调）
          if (result != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                result!.content,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isError
                      ? colorScheme.error
                      : colorScheme.onSurfaceVariant,
                  height: 1.5,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
