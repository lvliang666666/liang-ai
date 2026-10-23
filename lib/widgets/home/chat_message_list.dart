import 'package:flutter/material.dart';

import '../../providers/chat_provider.dart';
import '../../utils/haptics.dart';
import '../message_bubble.dart';

/// 主页内嵌聊天区：消息列表（reverse 底部锚定）+ 错误提示 + 智能跟随
///
/// 切换会话过渡：外层 AnimatedSwitcher——新会话内容从右轻滑入 +
/// 淡入（240ms easeOutCubic），旧内容淡出。key 绑定会话 id，
/// 同会话流式重建不触发过渡。加载在数据就绪后才发生（_enterChat
/// 原子替换），过渡期间无空帧无加载态。
/// ScrollController 自持：每个会话实例独立控制器，随 State 销毁，
/// 避免跨会话复用同一控制器（旧列表 detach/新列表 attach 竞态）。
///
/// I1 流式智能跟随：
/// - 用户手指触摸列表（拖拽中）→ 暂停自动跟随，流式新内容不再拽回底部
/// - 用户滚离底部 → 右下角浮出「↓ 回到最新」胶囊（含未读条数）
/// - 点胶囊平滑滚回底部并恢复跟随；手动滚回底部同样恢复跟随
class ChatMessageList extends StatefulWidget {
  const ChatMessageList({
    super.key,
    required this.chatKey,
    required this.chat,
    required this.onDelete,
  });

  /// 会话身份 key：AnimatedSwitcher 据此判断是否播过渡
  /// （宿主持 GlobalKey，此 key 作为 child 身份挂在内部）
  final Key chatKey;
  final ChatProvider chat;
  final VoidCallback onDelete;

  @override
  State<ChatMessageList> createState() => ChatMessageListState();
}

class ChatMessageListState extends State<ChatMessageList> {
  final _scrollController = ScrollController();

  /// 宿主经 GlobalKey 取控制器做底部锚定（滚动跟随）
  ScrollController get scrollController => _scrollController;

  // ===== I1 智能跟随状态 =====

  /// 是否自动跟随最新消息（触摸列表/滚离底部 = false，回到底部 = true）
  bool _following = true;

  /// 用户正在拖拽列表（拖拽中即使还在底部也不强制跳底，松手后按位置判定）
  bool _dragging = false;

  /// 上一次渲染的消息数（新消息出现时若在跟随则跳底）
  int _lastDisplayCount = 0;

  /// 距底部多少像素内算「在底部」（reverse 列表 offset 0 = 底部）
  static const double _bottomThreshold = 60;

  /// 距底部还有多少条未读（胶囊 +N 显示用；0 = 在底部）
  int _unreadCount = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听：位置驱动跟随状态（唯一事实来源，触摸/惯性/点击胶囊都汇到这里）
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final atBottom = _scrollController.offset <= _bottomThreshold;
    if (atBottom != _following) {
      setState(() {
        _following = atBottom;
        if (atBottom) _unreadCount = 0;
      });
    }
  }

  /// 每帧渲染回调（ListenableBuilder 内）：跟随态下新消息/流式增长跳底
  void _maybeAutoScroll(int newCount) {
    if (!mounted) return;
    if (newCount != _lastDisplayCount) {
      final isNewMessage = newCount > _lastDisplayCount;
      _lastDisplayCount = newCount;
      // 新消息出现且正在跟随：跳底（流式首帧/新消息落库）
      if (isNewMessage && _following && !_dragging) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients && _following) {
            _scrollController.jumpTo(0);
          }
        });
      }
    } else if (_following && !_dragging && _scrollController.hasClients) {
      // 流式增长（消息数不变、内容变长）：在底部附近才持续贴底
      if (_scrollController.offset <= _bottomThreshold) {
        _scrollController.jumpTo(0);
      }
    }
    // 非跟随态：统计距底部的未读条数（胶囊 +N）。
    // build 期间不能 setState——变化延迟到帧末提交
    if (!_following) {
      _updateUnreadCount();
    }
  }

  /// 非跟随态下计算「回到最新」胶囊的未读条数：
  /// 按 offset 与平均行高估算，避免逐条布局测量。
  /// build 期间调用：只改字段，需要上屏的变化走 post-frame setState
  void _updateUnreadCount() {
    if (!_scrollController.hasClients) return;
    final total = widget.chat.displayMessages.length;
    if (total == 0) return;
    // reverse 列表：offset = 距底部滚出的像素。用视口高度估算可见条数，
    // 每条按 72px 粗估（气泡+间距），只用于胶囊提示，不要求精确
    final viewport = _scrollController.position.viewportDimension;
    final hiddenPx = _scrollController.offset;
    const avgItem = 72.0;
    final hidden = (hiddenPx / avgItem).round();
    final unread = hidden.clamp(0, total);
    if (unread != _unreadCount) {
      _unreadCount = unread;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// 点「回到最新」胶囊：平滑滚回底部并恢复跟随
  Future<void> scrollToBottom() async {
    if (!_scrollController.hasClients) return;
    Haptics.light();
    setState(() {
      _following = true;
      _unreadCount = 0;
    });
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
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
          _maybeAutoScroll(widget.chat.displayMessages.length);
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
        // 消息列表（reverse：底部锚定，内容置顶显示）+ 智能跟随
        Expanded(
          child: widget.chat.displayMessages.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollStartNotification &&
                            notification.dragDetails != null) {
                          // 手指按下开始拖拽：暂停跟随（流式不再拽回底部）
                          _dragging = true;
                          if (_following) {
                            setState(() => _following = false);
                          }
                        } else if (notification is ScrollEndNotification) {
                          _dragging = false;
                          // 松手后按位置恢复：滚回底部附近 = 恢复跟随
                          if (_scrollController.hasClients &&
                              _scrollController.offset <= _bottomThreshold &&
                              !_following) {
                            setState(() {
                              _following = true;
                              _unreadCount = 0;
                            });
                          }
                        }
                        return false;
                      },
                      child: ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
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
                                isStreaming:
                                    isLast && widget.chat.isStreaming,
                                thinkingSeconds:
                                    widget.chat.thinkingSeconds,
                                toolResults: msg.id ==
                                        widget.chat.lastToolCallMessageId
                                    ? widget.chat.toolResults
                                    : const [],
                                toolExecuting:
                                    msg.id == widget.chat.lastToolCallMessageId &&
                                        widget.chat.status ==
                                            ChatStatus.toolCalling,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    // 「回到最新」胶囊：非跟随态浮出（右下角，输入栏上方）
                    if (!_following)
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: _BackToLatestButton(
                          unread: _unreadCount,
                          isStreaming: widget.chat.isStreaming,
                          onTap: scrollToBottom,
                        ),
                      ),
                  ],
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

/// 「↓ 回到最新」胶囊按钮：非跟随态浮出，流式时带呼吸点提示仍在生成
class _BackToLatestButton extends StatelessWidget {
  const _BackToLatestButton({
    required this.unread,
    required this.isStreaming,
    required this.onTap,
  });

  /// 距底部未读条数（0 不显示 +N）
  final int unread;
  final bool isStreaming;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.3),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward_rounded,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                unread > 0 ? '回到最新（+$unread）' : '回到最新',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurface),
              ),
              // 流式中提示仍在生成（小呼吸点）
              if (isStreaming) ...[
                const SizedBox(width: 6),
                _BreathingDot(color: theme.colorScheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 呼吸点：流式生成中的轻量提示（透明度 0.4~1.0 循环）
class _BreathingDot extends StatefulWidget {
  const _BreathingDot({required this.color});

  final Color color;

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      )),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
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
