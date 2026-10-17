import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../providers/theme_provider.dart';
import 'code_block_widget.dart';
import 'thinking_block.dart';

/// 消息气泡：用户右侧蓝色，助手左侧含思考块 + Markdown
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.thinkingSeconds = 0,
  });

  final ChatMessage message;
  final bool isStreaming;
  final int thinkingSeconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final radius = context.read<ThemeProvider>().cornerRadius;

    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(left: 60, top: 4, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.widthOf(context) * 0.78,
          ),
          decoration: BoxDecoration(
            color: colorScheme.primary,
            borderRadius: BorderRadius.circular(radius).copyWith(
              bottomRight: Radius.circular(radius > 0 ? 4 : 0),
            ),
          ),
          child: SelectableText(
            message.content,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onPrimary,
              height: 1.5,
            ),
          ),
        ),
      );
    }

    // 助手消息
    final thinkingStreaming = isStreaming && message.content.isEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(right: 40, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.widthOf(context) * 0.86,
        ),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(radius).copyWith(
            bottomLeft: Radius.circular(radius > 0 ? 4 : 0),
          ),
        ),
        child: GestureDetector(
          onLongPress: () async {
            if (message.content.isNotEmpty) {
              await Clipboard.setData(ClipboardData(text: message.content));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 思考过程块
              if (message.reasoning.isNotEmpty || thinkingStreaming)
                ThinkingBlock(
                  reasoning: message.reasoning,
                  streaming: thinkingStreaming,
                  seconds: thinkingSeconds,
                ),
              // 正文 Markdown
              if (message.content.isNotEmpty)
                GptMarkdown(
                  message.content,
                  isStreaming: isStreaming,
                  charactersPerSecond: 40,
                  codeBuilder: (context, name, code, closed) =>
                      CodeBlockWidget(code: code, language: name),
                ),
              // 流式中正文还没来：显示光标动画占位
              if (isStreaming &&
                  message.content.isEmpty &&
                  message.reasoning.isEmpty)
                const _TypingIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 打字中指示器（三个跳动圆点）
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        Widget dot(int i) {
          final t = (_controller.value * 3 - i).clamp(0.0, 1.0);
          final scale = 0.6 + 0.4 * (1 - (2 * t - 1).abs());
          return Transform.scale(
            scale: scale,
            child: Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          );
        }

        return Row(mainAxisSize: MainAxisSize.min, children: [
          dot(0),
          dot(1),
          dot(2),
        ]);
      },
    );
  }
}
