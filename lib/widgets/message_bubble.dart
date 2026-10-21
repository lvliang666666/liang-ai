import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../models/chat_message.dart';
import '../models/tool_call.dart';
import '../services/file_export_service.dart';
import '../utils/haptics.dart';
import 'attachment_thumbnail.dart';
import 'code_block_widget.dart';
import 'thinking_block.dart';
import 'tool_call_block.dart';

/// 消息气泡：用户右侧蓝色，助手左侧含思考块 + 工具卡片 + Markdown
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.thinkingSeconds = 0,
    this.toolResults = const [],
    this.toolExecuting = false,
  });

  final ChatMessage message;
  final bool isStreaming;
  final int thinkingSeconds;

  /// 本消息 tool_calls 对应的执行结果（UI 卡片展示）
  final List<ToolCallResult> toolResults;

  /// 工具是否正在执行（toolCalling 状态）
  final bool toolExecuting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (message.isUser) {
      final hasImages = message.attachments.any((a) => a.isImage);
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(left: 60, top: 4, bottom: 4),
          padding: EdgeInsets.fromLTRB(
              hasImages ? 6 : 14, hasImages ? 6 : 10, hasImages ? 6 : 14,
              hasImages ? 6 : 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.widthOf(context) * 0.78,
          ),
          decoration: BoxDecoration(
            color: colorScheme.primary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 附件区：图片缩略图 / 文件卡片
              if (message.hasAttachments)
                _UserAttachments(message: message),
              // 正文（有附件但无文字时不渲染空文本）
              if (message.content.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
                      top: message.hasAttachments ? 6 : 0,
                      left: hasImages ? 8 : 0,
                      right: hasImages ? 8 : 0),
                  child: SelectableText(
                    message.content,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onPrimary,
                      height: 1.6,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // 助手消息：DeepSeek 式视觉减重——浅灰底、大圆角、无小尾巴
    final thinkingStreaming = isStreaming && message.content.isEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(right: 40, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.widthOf(context) * 0.86,
        ),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(20),
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
              // 工具调用卡片（assistant 发起过调用时显示）
              if (message.toolCalls.isNotEmpty)
                ToolCallBlock(
                  calls: message.toolCalls,
                  results: toolResults,
                  executing: toolExecuting,
                ),
              // 正文 Markdown
              if (message.content.isNotEmpty)
                GptMarkdown(
                  message.content,
                  isStreaming: isStreaming,
                  // 打字机节奏：70 字/秒——长回答不拖沓，短回答仍有打字感
                  charactersPerSecond: 70,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(height: 1.6),
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
      Haptics.medium(); // 复制完成反馈（三档词汇表：medium）
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

/// 用户消息附件区：图片缩略图网格 + 豆包式文件卡片（可点开）
class _UserAttachments extends StatelessWidget {
  const _UserAttachments({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final images = message.attachments.where((a) => a.isImage).toList();
    final files = message.attachments.where((a) => a.isFile).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 图片缩略图（≤3 张，一行排开）
        if (images.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final img in images)
                GestureDetector(
                  onTap: () => _openImageViewer(context, images, img),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: AttachmentThumbnail(
                      base64: img.base64Data ?? '',
                      size: 96,
                    ),
                  ),
                ),
            ],
          ),
        // 豆包式文件卡片（点击打开原文件）
        for (final f in files)
          _FileCard(
            name: f.name,
            hasFile: f.hasFile,
            onTap: () => _openFile(context, f),
          ),
      ],
    );
  }

  void _openImageViewer(
      BuildContext context, List images, current) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => _ImageViewer(
          images: [for (final i in images) i.base64Data ?? ''],
          initialIndex: images.indexOf(current),
        ),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  /// 打开文件附件原文件（系统应用接管：PDF→阅读器等）
  Future<void> _openFile(BuildContext context, f) async {
    Haptics.light();
    if (!f.hasFile) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('旧版本消息未保存原文件，无法打开'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final result = await OpenFilex.open(f.filePath!);
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}

/// 豆包式文件卡片：图标 + 文件名 + 类型标签，点击打开
class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.name,
    required this.hasFile,
    required this.onTap,
  });

  final String name;
  final bool hasFile;
  final VoidCallback onTap;

  String get _extLabel {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '文件';
    return name.substring(dot + 1).toUpperCase();
  }

  IconData get _icon {
    final ext = _extLabel.toLowerCase();
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (ext == 'md') return Icons.article_outlined;
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 230),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(_icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasFile ? '$_extLabel 文件 · 点击打开' : '$_extLabel 文件',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全屏图片查看器（黑底，点击关闭，多图可左右滑动）
class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.images, required this.initialIndex});

  final List<String> images;
  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        color: Colors.black87,
        alignment: Alignment.center,
        child: images.length == 1
            ? InteractiveViewer(
                child: Image.memory(base64Decode(images.first)),
              )
            : PageView.builder(
                controller: PageController(initialPage: initialIndex),
                itemCount: images.length,
                itemBuilder: (_, i) => InteractiveViewer(
                  child: Image.memory(base64Decode(images[i])),
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
          final wave = 1 - (2 * t - 1).abs();
          final scale = 0.6 + 0.4 * wave;
          // 透明度与缩放同相位：跳动高点最实，低点最虚（DeepSeek 质感）
          final opacity = 0.35 + 0.65 * wave;
          return Opacity(
            opacity: opacity,
            child: Transform.scale(
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
