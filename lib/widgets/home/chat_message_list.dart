import 'package:flutter/material.dart';

import '../../providers/chat_provider.dart';
import '../../utils/haptics.dart';
import '../message_bubble.dart';

/// 主页内嵌聊天区：消息列表（reverse 底部锚定）+ 错误提示
///
/// 切换会话过渡：外层 AnimatedSwitcher——新会话内容从右轻滑入 +
/// 淡入（240ms easeOutCubic），旧内容淡出。key 绑定会话 id，
/// 同会话流式重建不触发过渡。加载在数据就绪后才发生（_enterChat
/// 原子替换），过渡期间无空帧无加载态。
/// ScrollController 自持：每个会话实例独立控制器，随 State 销毁，
/// 避免跨会话复用同一控制器（旧列表 detach/新列表 attach 竞态）。
class ChatMessageList extends StatefulWidget {
  const ChatMessageList({
    super.key,
    required this.chatKey,
    required this.chat,
    required this.onCountChanged,
    required this.onDelete,
  });

  /// 会话身份 key：AnimatedSwitcher 据此判断是否播过渡
  /// （宿主持 GlobalKey，此 key 作为 child 身份挂在内部）
  final Key chatKey;
  final ChatProvider chat;
  final void Function(int newCount) onCountChanged;
  final VoidCallback onDelete;

  @override
  State<ChatMessageList> createState() => ChatMessageListState();
}

class ChatMessageListState extends State<ChatMessageList> {
  final _scrollController = ScrollController();

  /// 宿主经 GlobalKey 取控制器做底部锚定（滚动跟随）
  ScrollController get scrollController => _scrollController;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 订阅 ChatProvider 重建（流式/状态变化）。
    // 单页架构下 ChatProvider 不在 Provider 树中，必须用 ListenableBuilder。
    // KeyedSubtree 挂会话身份 key：AnimatedSwitcher 的过渡判定依据
    return KeyedSubtree(
      key: widget.chatKey,
      child: ListenableBuilder(
        listenable: widget.chat,
        builder: (context, _) {
          widget.onCountChanged(widget.chat.displayMessages.length);
          return _buildList(context, theme);
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, ThemeData theme) {
    return Column(
      children: [
        // 错误提示条
        if (widget.chat.status == ChatStatus.error)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline,
                    size: 18, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.chat.errorMessage,
                    style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                InkWell(
                  onTap: () {
                    Haptics.light();
                    widget.chat.clearError();
                  },
                  child: Icon(Icons.close,
                      size: 16, color: theme.colorScheme.onErrorContainer),
                ),
              ],
            ),
          ),
        // 消息列表（reverse：底部锚定，内容置顶显示）
        Expanded(
          child: widget.chat.displayMessages.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: widget.chat.displayMessages.length,
                  itemBuilder: (context, index) {
                    final msg = widget.chat.displayMessages[
                        widget.chat.displayMessages.length - 1 - index];
                    if (msg.isToolResult) return const SizedBox.shrink();
                    final isLast = index == 0;
                    // 微信式时间戳：首条必显，之后与上一条间隔 >5 分钟才显示
                    final showTime = _shouldShowTime(index);
                    return Column(
                      children: [
                        if (showTime)
                          MessageTimeLabel(timestamp: msg.createdAt),
                        MessageBubble(
                          key: ValueKey(msg.id),
                          message: msg,
                          isStreaming: isLast && widget.chat.isStreaming,
                          thinkingSeconds: widget.chat.thinkingSeconds,
                          toolResults: msg.id == widget.chat.lastToolCallMessageId
                              ? widget.chat.toolResults
                              : const [],
                          toolExecuting:
                              msg.id == widget.chat.lastToolCallMessageId &&
                                  widget.chat.status == ChatStatus.toolCalling,
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 是否在该消息上方显示时间标签（微信规则：首条必显 + 间隔超 5 分钟）
  bool _shouldShowTime(int index) {
    final msgs = widget.chat.displayMessages;
    if (index >= msgs.length) return false;
    final msg = msgs[msgs.length - 1 - index];
    if (msg.isToolResult) return false;
    // 首条消息必显
    if (index == msgs.length - 1) return true;
    // 找上一条非 tool 结果消息比较间隔
    for (var i = index + 1; i < msgs.length; i++) {
      final prev = msgs[msgs.length - 1 - i];
      if (prev.isToolResult) continue;
      return msg.createdAt - prev.createdAt > 5 * 60 * 1000;
    }
    return true;
  }
}

/// 微信式消息时间标签：居中灰色小字
class MessageTimeLabel extends StatelessWidget {
  const MessageTimeLabel({super.key, required this.timestamp});

  final int timestamp;

  /// 微信样式时间文本：今天显示时分，昨天显示「昨天 时分」，更早显示日期
  String get _label {
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
    if (dt.year == now.year) {
      return '${dt.month}月${dt.day}日 $hm';
    }
    return '${dt.year}年${dt.month}月${dt.day}日 $hm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        _label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
