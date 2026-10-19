import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../utils/haptics.dart';

/// 仿 DeepSeek 可折叠"深度思考"区域
///
/// [reasoning] 思考内容；[streaming] 是否正在流式思考；[seconds] 思考用时。
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({
    super.key,
    required this.reasoning,
    required this.streaming,
    this.seconds = 0,
  });

  final String reasoning;
  final bool streaming;
  final int seconds;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  // 流式中默认展开，完成后折叠
  late bool _expanded = widget.streaming;
  bool _userToggled = false;
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant ThinkingBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 流式→完成时自动折叠（用户未手动操作过）
    if (!_userToggled && oldWidget.streaming && !widget.streaming) {
      _expanded = false;
    }
    // 流式中自动滚到底部
    if (widget.streaming && _expanded && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final radius = context.read<ThemeProvider>().cornerRadius;

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
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(radius),
            ),
            onTap: () {
              Haptics.light();
              _userToggled = true;
              setState(() => _expanded = !_expanded);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    widget.streaming
                        ? Icons.psychology_alt_outlined
                        : Icons.psychology_outlined,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.streaming
                          ? '深度思考中…'
                          : '已深度思考（用时 ${widget.seconds} 秒）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.primary,
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
            firstChild: Container(
              constraints: const BoxConstraints(maxHeight: 260),
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Text(
                  widget.reasoning.isEmpty ? ' ' : widget.reasoning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ),
            ),
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
