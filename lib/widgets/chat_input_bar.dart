import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/message_attachment.dart';
import '../providers/chat_provider.dart';
import '../providers/theme_provider.dart';
import '../services/attachment_service.dart';
import '../utils/haptics.dart';

/// 聊天输入栏：附件按钮 + 推理档位选择 + 输入框 + 发送/停止按钮
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
  final _picker = ImagePicker();
  final _attachmentService = const AttachmentService();

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
    _focusNode.requestFocus();
  }

  /// 附件来源选择：拍照 / 相册 / 文件
  Future<void> _pickAttachment() async {
    Haptics.light();
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

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(
            top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 附件预览条
            if (pending.isNotEmpty) _AttachmentPreview(pending: pending),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 附件按钮
                IconButton(
                  onPressed: widget.isStreaming ? null : _pickAttachment,
                  icon: Icon(Icons.add_circle_outline,
                      color: colorScheme.primary),
                  tooltip: '添加附件',
                ),
                // 推理档位按钮
                InkWell(
                  onTap: _pickEffort,
                  borderRadius: BorderRadius.circular(radius + 2),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color:
                          colorScheme.primaryContainer.withValues(alpha: 0.6),
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
                const SizedBox(width: 8),
                // 发送 / 停止按钮
                widget.isStreaming
                    ? IconButton.filled(
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
                    : IconButton.filled(
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
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          base64Decode(att.base64Data ?? ''),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                              Icons.broken_image_outlined,
                              size: 28),
                        ),
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
