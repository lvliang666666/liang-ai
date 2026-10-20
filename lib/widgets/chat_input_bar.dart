import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/message_attachment.dart';
import '../providers/chat_provider.dart';
import '../providers/theme_provider.dart';
import '../services/attachment_service.dart';
import '../utils/haptics.dart';
import 'attachment_thumbnail.dart';
import 'chat_tags_bar.dart';

/// 聊天输入栏：tags 行（可选）+ 附件按钮 + 推理档位选择 + 输入框 + 发送/停止按钮
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.isStreaming,
    required this.effort,
    required this.onSend,
    required this.onStop,
    required this.onEffortChanged,
    this.showAttachmentButton = true,
    this.showEffortButton = true,
    this.tags = const [],
  });

  final bool isStreaming;
  final String effort;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final ValueChanged<String> onEffortChanged;

  /// 供应商能力开关：不支持时隐藏对应按钮
  final bool showAttachmentButton;
  final bool showEffortButton;

  /// 输入框上方 tags 行（agent/model 切换入口，空 = 不显示）
  final List<ChatTag> tags;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _picker = ImagePicker();
  // 文件附件沙箱目录异步初始化（就绪前选取的文件不保存原文件）
  AttachmentService _attachmentService = const AttachmentService();

  @override
  void initState() {
    super.initState();
    _initAttachmentStorage();
  }

  /// 文件附件沙箱目录（应用文档目录/attachments）
  Future<void> _initAttachmentStorage() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      if (mounted) {
        setState(() {
          _attachmentService = AttachmentService(
            storageDir: Directory(p.join(docs.path, 'attachments')),
          );
        });
      }
    } catch (_) {
      // 目录不可用时保持默认（不保存原文件，仅提取文本）
    }
  }

  static const _effortLabels = {
    'max': ('深度', '复杂编码 · 最强推理'),
    'high': ('均衡', '日常问答 · 平衡速度'),
    'low': ('轻量', '简单任务 · 响应最快'),
  };

  bool get _canSend =>
      !widget.isStreaming &&
      (_controller.text.trim().isNotEmpty ||
          context.read<ChatProvider>().hasPendingAttachments);

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    final chat = context.read<ChatProvider>();
    if (text.isEmpty && !chat.hasPendingAttachments) return;
    Haptics.light();
    widget.onSend(text);
    _controller.clear();
    // 不主动聚焦：键盘只在用户主动点输入框时弹出
  }

  /// 附件来源选择：拍照 / 相册 / 文件
  Future<void> _pickAttachment() async {
    Haptics.light();
    // 打开弹层前收起键盘，避免弹层关闭时焦点自动回到输入框
    FocusManager.instance.primaryFocus?.unfocus();
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('添加附件'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('相册（最多 3 张）'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('文件（txt / md / pdf，最多 3 个）'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    final chat = context.read<ChatProvider>();
    try {
      switch (action) {
        case 'camera':
          final xfile = await _picker.pickImage(
            source: ImageSource.camera,
            maxWidth: 1024,
            maxHeight: 1024,
            imageQuality: 85,
          );
          if (xfile == null) return;
          final bytes = await xfile.readAsBytes();
          _addOrWarn(chat, _attachmentService.imageAttachment(xfile.name, bytes));
        case 'gallery':
          final xfile = await _picker.pickImage(
            source: ImageSource.gallery,
            maxWidth: 1024,
            maxHeight: 1024,
            imageQuality: 85,
          );
          if (xfile == null) return;
          final bytes = await xfile.readAsBytes();
          _addOrWarn(chat, _attachmentService.imageAttachment(xfile.name, bytes));
        case 'file':
          final result = await _pickFileWithFallback();
          if (result == null) return;
          final (name, bytes) = result;
          _addOrWarn(chat, await _attachmentService.fileAttachment(name, bytes));
      }
    } on AttachmentException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), duration: const Duration(seconds: 2)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('添加附件失败'), duration: Duration(seconds: 2)),
        );
      }
    }
  }

  void _addOrWarn(ChatProvider chat, attachment) {
    final ok = chat.addAttachment(attachment);
    if (!ok && mounted) {
      Haptics.medium();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('图片最多 3 张、文件最多 3 个'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// 文件选取：file_picker 13.x 静态 API（真机）；测试环境抛 MissingPluginException 时静默
  Future<(String, Uint8List)?> _pickFileWithFallback() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'md', 'pdf'],
      );
      if (result.isEmpty) return null;
      final f = result.single;
      final bytes = await f.readAsBytes();
      return (f.name, bytes);
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('当前环境不支持文件选择'), duration: Duration(seconds: 2)),
        );
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effortLabel = _effortLabels[widget.effort]?.$1 ?? widget.effort;
    final radius = context.read<ThemeProvider>().cornerRadius;
    final chat = context.watch<ChatProvider>();
    final pending = chat.pendingAttachments;

    // 豆包式右侧动作区逻辑：
    // - 流式中：显示停止键
    // - 输入文字或有待发附件：显示发送键（覆盖 +）
    // - 否则（含聚焦未输入）：只显示 +
    final hasText = _controller.text.trim().isNotEmpty;
    final showSend =
        widget.isStreaming || hasText || pending.isNotEmpty;
    final showPlus = !widget.isStreaming && !hasText;

    return SafeArea(
      // DeepSeek 式浮起输入栏：离底 8px、圆角胶囊、带阴影、无顶部分隔线
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // tags 行（agent/model 切换，DeepSeek 式）
            if (widget.tags.isNotEmpty) ...[
              ChatTagsBar(tags: widget.tags),
              const SizedBox(height: 6),
            ],
            // 附件预览条
            if (pending.isNotEmpty) _AttachmentPreview(pending: pending),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 推理档位按钮（左侧，垂直居中；供应商不支持思考流时隐藏）
                if (widget.showEffortButton) ...[
                  InkWell(
                    onTap: _pickEffort,
                    borderRadius: BorderRadius.circular(radius + 2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer
                            .withValues(alpha: 0.6),
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
                ],
                // 输入框
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    maxLines: null,
                    minLines: 1,
                    textInputAction: TextInputAction.newline,
                    onChanged: (_) => setState(() {}),
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(height: 1.6),
                    decoration: InputDecoration(
                      hintText: pending.isEmpty ? '输入消息…' : '补充说明（可空）…',
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
                const SizedBox(width: 4),
                // 右侧动作区：+ 与 发送/停止（供应商不支持视觉时隐藏 +）
                if (showPlus && widget.showAttachmentButton)
                  IconButton(
                    onPressed: _pickAttachment,
                    icon: Icon(Icons.add_circle_outline,
                        size: 28, color: colorScheme.onSurfaceVariant),
                    tooltip: '添加附件',
                  ),
                if (widget.isStreaming)
                  IconButton.filled(
                    onPressed: () {
                      Haptics.medium();
                      widget.onStop();
                    },
                    style: IconButton.styleFrom(
                      backgroundColor: colorScheme.errorContainer,
                    ),
                    icon: Icon(Icons.stop_rounded,
                        color: colorScheme.onErrorContainer),
                  )
                else if (showSend)
                  IconButton.filled(
                    onPressed: _canSend ? _send : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickEffort() async {
    Haptics.light();
    // 打开弹层前收起键盘，避免弹层关闭时焦点自动回到输入框
    FocusManager.instance.primaryFocus?.unfocus();
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
                onTap: () {
                  Haptics.selection();
                  Navigator.pop(context, entry.key);
                },
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
}

/// 待发送附件预览条（横向滚动缩略图 + 文件卡片）
class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.pending});

  final List<MessageAttachment> pending;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pending.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final att = pending[index];
          return Stack(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: colorScheme.outlineVariant, width: 0.5),
                ),
                child: att.isImage
                    ? AttachmentThumbnail(
                        base64: att.base64Data ?? '',
                        size: 72,
                        borderRadius: 10,
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.description_outlined,
                              size: 26, color: colorScheme.primary),
                          const SizedBox(height: 4),
                          Text(
                            att.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 9),
                          ),
                        ],
                      ),
              ),
              // 移除按钮
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () {
                    Haptics.light();
                    context.read<ChatProvider>().removeAttachment(att);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: colorScheme.outlineVariant, width: 0.5),
                    ),
                    child: Icon(Icons.close,
                        size: 14, color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
