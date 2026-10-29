import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../utils/haptics.dart';
import '../app_bottom_sheet.dart';

/// 大纲目录项预览截断长度（首行前 N 字符）
const int kOutlinePreviewLength = 40;

/// 打开「消息大纲」浮层（I8：点击 header 会话标题）
///
/// 以会话内每条 user 提问为目录项（首行截断，离线零成本，无需模型
/// 生成短标题），点击条目 pop 浮层并回调 [onSelect]（宿主负责滚动
/// 定位——复用 I7 的 scrollToMessage 管线）。
///
/// [messages] 传 `chat.displayMessages`（含流式中消息）；内部过滤出
/// 有实际内容的 user 消息（工具结果/空内容跳过）。
Future<ChatMessage?> showMessageOutlineSheet(
  BuildContext context,
  List<ChatMessage> messages,
) {
  return showAppBottomSheet<ChatMessage>(
    context: context,
    builder: (context) => MessageOutlineSheet(
      messages: messages,
      onSelect: (msg) => Navigator.pop(context, msg),
    ),
  );
}

/// 消息大纲浮层内容：目录条目列表（提问序号 + 首行预览 + 时间）
class MessageOutlineSheet extends StatelessWidget {
  const MessageOutlineSheet({
    super.key,
    required this.messages,
    required this.onSelect,
  });

  /// 会话消息（含流式中消息；内部过滤 user 提问）
  final List<ChatMessage> messages;

  /// 选中目录项回调（pop 由外层 [showMessageOutlineSheet] 处理）
  final ValueChanged<ChatMessage> onSelect;

  /// 大纲数据源：有实际内容的 user 消息（工具结果/空内容跳过）
  static List<ChatMessage> outlineEntries(List<ChatMessage> messages) => [
        for (final m in messages)
          if (m.isUser && m.content.trim().isNotEmpty) m,
      ];

  /// 目录项预览：首行截断（多行提问只取第一行；超长截断加省略号）
  @visibleForTesting
  static String previewOf(ChatMessage message) {
    final firstLine =
        message.content.trim().split('\n').first.trim();
    if (firstLine.length <= kOutlinePreviewLength) return firstLine;
    return '${firstLine.substring(0, kOutlinePreviewLength)}…';
  }

  /// 微信式时间：今天显示时分，昨天显示「昨天 时分」，更早显示日期
  @visibleForTesting
  static String timeLabel(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final hm = '$hh:$mm';
    final diffDays = today.difference(msgDay).inDays;
    if (diffDays == 0) return hm;
    if (diffDays == 1) return '昨天 $hm';
    if (dt.year == now.year) return '${dt.month}月${dt.day}日 $hm';
    return '${dt.year}年${dt.month}月${dt.day}日 $hm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = outlineEntries(messages);

    return SheetScaffold(
      title: '消息大纲',
      onClose: () => Navigator.pop(context),
      child: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '还没有提问',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final msg = entries[index];
                return ListTile(
                  key: ValueKey('outline-${msg.id}'),
                  leading: Text(
                    '${index + 1}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  title: Text(
                    previewOf(msg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    timeLabel(msg.createdAt),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  onTap: () {
                    Haptics.light();
                    onSelect(msg);
                  },
                );
              },
            ),
    );
  }
}
