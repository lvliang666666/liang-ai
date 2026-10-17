import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';

/// 聊天输入栏：推理档位选择 + 输入框 + 发送/停止按钮
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.isStreaming,
    required this.effort,
    required this.onSend,
    required this.onStop,
    required this.onEffortChanged,
  });

  final bool isStreaming;
  final String effort;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final ValueChanged<String> onEffortChanged;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  static const _effortLabels = {
    'max': ('深度', '复杂编码 · 最强推理'),
    'high': ('均衡', '日常问答 · 平衡速度'),
    'low': ('轻量', '简单任务 · 响应最快'),
  };

  bool get _canSend =>
      !widget.isStreaming && _controller.text.trim().isNotEmpty;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    _focusNode.requestFocus();
  }

  Future<void> _pickEffort() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '推理深度',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final entry in _effortLabels.entries)
              ListTile(
                leading: Icon(
                  widget.effort == entry.key
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(entry.value.$1),
                subtitle: Text(entry.value.$2),
                onTap: () => Navigator.pop(context, entry.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null && selected != widget.effort) {
      widget.onEffortChanged(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effortLabel = _effortLabels[widget.effort]?.$1 ?? widget.effort;
    final radius = context.read<ThemeProvider>().cornerRadius;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(
            top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 推理档位按钮
            InkWell(
              onTap: _pickEffort,
              borderRadius: BorderRadius.circular(radius + 2),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(radius + 2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bolt,
                        size: 16, color: colorScheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      effortLabel,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 输入框
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: null,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '输入消息…',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(radius + 6),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 发送 / 停止按钮
            widget.isStreaming
                ? IconButton.filled(
                    onPressed: widget.onStop,
                    style: IconButton.styleFrom(
                      backgroundColor: colorScheme.errorContainer,
                    ),
                    icon: Icon(Icons.stop_rounded,
                        color: colorScheme.onErrorContainer),
                  )
                : IconButton.filled(
                    onPressed: _canSend ? _send : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
          ],
        ),
      ),
    );
  }
}
