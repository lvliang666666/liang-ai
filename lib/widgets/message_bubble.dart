import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/chat_message.dart';
import '../providers/theme_provider.dart';
import '../services/file_export_service.dart';
import '../utils/haptics.dart';
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
          onLongPress: () {
            if (message.content.isNotEmpty) {
              Haptics.medium();
              _showMessageActions(context, message);
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

  /// 助手消息长按菜单：复制 / 导出为文档
  Future<void> _showMessageActions(
      BuildContext context, ChatMessage message) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制全文'),
              onTap: () {
                Haptics.light();
                Navigator.pop(context, 'copy');
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出并分享'),
              subtitle: const Text('Markdown / HTML / 纯文本，分享到 QQ、微信等'),
              onTap: () {
                Haptics.light();
                Navigator.pop(context, 'export');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;

    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.content));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('已复制'), duration: Duration(seconds: 1)),
        );
      }
      return;
    }

    if (action == 'export') {
      await _pickExportFormat(context, message);
    }
  }

  /// 选择导出格式并落盘
  Future<void> _pickExportFormat(
      BuildContext context, ChatMessage message) async {
    final format = await showModalBottomSheet<ExportFormat>(
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
              child: Text('选择分享格式',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Markdown（.md）'),
              subtitle: const Text('保留全部格式，适合再次编辑'),
              onTap: () {
                Haptics.selection();
                Navigator.pop(context, ExportFormat.markdown);
              },
            ),
            ListTile(
              leading: const Icon(Icons.html_outlined),
              title: const Text('HTML（.html）'),
              subtitle: const Text('带样式排版，浏览器/WPS 直接打开'),
              onTap: () {
                Haptics.selection();
                Navigator.pop(context, ExportFormat.html);
              },
            ),
            ListTile(
              leading: const Icon(Icons.text_snippet_outlined),
              title: const Text('纯文本（.txt）'),
              subtitle: const Text('去掉格式标记，任何地方可读'),
              onTap: () {
                Haptics.selection();
                Navigator.pop(context, ExportFormat.plainText);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || format == null) return;

    try {
      final fileNameBase =
          'LiangAI_${DateTime.now().toIso8601String().substring(0, 10)}';
      final result = await FileExportService.share(
        content: message.content,
        fileNameBase: fileNameBase,
        format: format,
      );
      if (!context.mounted) return;
      // 用户在分享面板点了取消：静默即可，不打扰
      if (result == null || result.status == ShareResultStatus.dismissed) {
        return;
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
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
