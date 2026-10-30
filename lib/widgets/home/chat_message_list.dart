import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../models/doc_chunk.dart';
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
/// - 用户滚离底部 → 右下角浮出「↓ 回到最新」胶囊
/// - 点胶囊平滑滚回底部并恢复跟随；手动滚回底部同样恢复跟随
class ChatMessageList extends StatefulWidget {
  const ChatMessageList({
    super.key,
    required this.chatKey,
    required this.chat,
    required this.onDelete,
    this.onEditMessage,
    this.onQuoteMessage,
    this.onRegenerateMessage,
    this.onSaveAsCard,
    this.onChooseDualMessage,
    this.resolveChunk,
  });

  /// 会话身份 key：AnimatedSwitcher 据此判断是否播过渡
  /// （宿主持 GlobalKey，此 key 作为 child 身份挂在内部）
  final Key chatKey;
  final ChatProvider chat;
  final VoidCallback onDelete;

  /// 编辑重发（I4：user 消息长按菜单「编辑重发」入口；null = 无编辑能力）
  final ValueChanged<ChatMessage>? onEditMessage;

  /// 引用追问（I5：assistant 消息长按菜单「引用」入口；null = 无引用能力）
  final ValueChanged<ChatMessage>? onQuoteMessage;

  /// 重答（I3：assistant 消息长按菜单「重答」入口；null = 无重答能力）
  final ValueChanged<ChatMessage>? onRegenerateMessage;

  /// 沉淀为卡片（M5：user/assistant 消息长按菜单「沉淀为卡片」入口；
  /// null = 无沉淀能力）
  final ValueChanged<ChatMessage>? onSaveAsCard;

  /// F6 同问双答「用这个继续」（待选择态 assistant 气泡按钮入口；
  /// null = 无选择能力）
  final ValueChanged<ChatMessage>? onChooseDualMessage;

  /// F8 引用溯源：按 (docName, page) 查回 doc_chunks 原文块（null =
  /// 无检索能力，引用 chips 纯展示不可点）
  final Future<DocChunk?> Function(String docName, int page)? resolveChunk;

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

  // ===== I9 胶囊行滚动收纳 =====

  /// tags 胶囊行收纳信号（true = 收起）。
  /// 微信顶栏思路：下滑看历史（offset 增大）收起、上滑回底部（offset
  /// 减小）展开。ValueNotifier 让宿主（HomeInputBar）精准订阅，
  /// 不牵动消息列表整树重建。
  final ValueNotifier<bool> capsuleCollapsed = ValueNotifier(false);

  /// 上一次滚动位置（方向判定基准）
  double _lastScrollOffset = 0;

  /// 收纳判定：距底部超过该距离才允许收起（在底部附近来回微滚不收纳，
  /// 避免流式贴底跳动时胶囊闪烁）
  static const double _collapseDistance = 120;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    capsuleCollapsed.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ===== I7 搜索定位（FTS 命中跳转）=====

  /// 消息 id → 气泡锚点（itemBuilder 登记宿主回调，定位时取用）
  final Map<String, GlobalKey> _bubbleKeys = {};

  /// 当前高亮的消息 id（scrollToMessage 设置，2s 后自动清除）
  String? _highlightMessageId;

  /// 高亮渐隐定时器（重复定位时先取消旧的）
  Timer? _highlightTimer;

  /// itemBuilder 登记气泡锚点（GlobalKey 挂 MessageBubble）
  GlobalKey _bubbleKey(String messageId) =>
      _bubbleKeys.putIfAbsent(messageId, () => GlobalKey());

  /// FTS 命中跳转（I7）：滚动定位到目标消息并临时高亮
  ///
  /// [messageId] 目标消息 id；[highlight] 命中词（透传气泡做词级高亮，
  /// null = 只做气泡级高亮）。
  /// 定位策略：目标在渲染缓存内 → Scrollable.ensureVisible 平滑滚到
  /// 锚点；在缓存外（长会话深处）→ 先按索引估算 offset 跳过去，等
  /// 气泡构建出来再 ensureVisible 精修。高亮 2s 后渐隐清除。
  Future<void> scrollToMessage(String messageId, {String? highlight}) async {
    if (!_scrollController.hasClients) return;
    final msgs = widget.chat.displayMessages;
    final index = msgs.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    // reverse 列表：列表第 0 项 = 最后一条消息
    final listIndex = msgs.length - 1 - index;

    Haptics.light();
    // 暂停跟随：定位到历史消息后流式增长不得拽回底部
    _following = false;

    final key = _bubbleKey(messageId);
    final ctx = key.currentContext;
    if (ctx != null) {
      // 已构建：直接平滑滚到可见
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.35, // 目标偏列表上部一点，上下文可见
      );
    } else {
      // 未构建（缓存外）：估算 offset 跳过去，下一帧气泡出现后精修。
      // 估算：平均每条消息 ~120px（气泡+间距），误差由二段定位兜住
      final estimate = listIndex * 120.0;
      _scrollController.jumpTo(
        math.min(estimate, _scrollController.position.maxScrollExtent),
      );
      // 等目标气泡构建出来再精确滚到可见
      await WidgetsBinding.instance.endOfFrame;
      final ctx2 = key.currentContext;
      if (ctx2 != null && mounted) {
        await Scrollable.ensureVisible(
          ctx2,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: 0.35,
        );
      }
    }

    if (!mounted) return;
    setState(() => _highlightMessageId = messageId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightMessageId = null);
    });
  }

  /// 气泡是否处于高亮态（itemBuilder 透传 MessageBubble）
  bool _isHighlighted(String messageId) =>
      _highlightMessageId == messageId;

  /// 滚动监听：位置驱动跟随状态（唯一事实来源，触摸/惯性/点击胶囊都汇到这里）
  ///
  /// I9 收纳：方向驱动胶囊行——下滑看历史（offset 增大且离底部够远）
  /// 收起，上滑（offset 减小）或回到底部附近展开。流式贴底跳转
  /// （jumpTo(0)）offset 只减不增，天然不触发收起。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    final atBottom = offset <= _bottomThreshold;
    if (atBottom != _following) {
      setState(() {
        _following = atBottom;
      });
    }

    // I9 方向判定（reverse 列表：offset 增大 = 向更早的历史滚）
    final delta = offset - _lastScrollOffset;
    _lastScrollOffset = offset;
    if (delta > 1) {
      // 下滑看历史：离底部够远才收起（底部附近微滚不收纳）
      final collapsed = offset > _collapseDistance;
      if (collapsed != capsuleCollapsed.value) {
        capsuleCollapsed.value = collapsed;
      }
    } else if (delta < -1) {
      // 上滑回底部：立即展开
      if (capsuleCollapsed.value) {
        capsuleCollapsed.value = false;
      }
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
  }

  /// 点「回到最新」胶囊：平滑滚回底部并恢复跟随
  Future<void> scrollToBottom() async {
    if (!_scrollController.hasClients) return;
    Haptics.light();
    setState(() {
      _following = true;
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
                          // F6 双答：两条流式占位都在列表尾部（倒数第一/二
                          // 条 assistant），都按流式渲染（打字机 + 光标）。
                          // 普通单流时只有最后一条是流式
                          final isStreamingMsg = widget.chat.isStreaming &&
                              (isLast ||
                                  (widget.chat.isDualRunning &&
                                      index == 1 &&
                                      msg.role == 'assistant'));
                          // 微信式时间戳：首条必显，之后与上一条间隔 >5 分钟才显示
                          final showTime = _shouldShowTime(index);
                          return Column(
                            key: ValueKey('col-${msg.id}'),
                            children: [
                              if (showTime)
                                MessageTimeLabel(timestamp: msg.createdAt),
                              MessageBubble(
                                // I7：GlobalKey 供 scrollToMessage 定位
                                //（ValueKey 保流式重建时的元素身份）
                                key: _bubbleKey(msg.id),
                                message: msg,
                                isStreaming: isStreamingMsg,
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
                                // I10 断流续传：最后一条 assistant 消息 +
                                // 中断态 → 尾部「连接中断 · 点击续传」胶囊
                                interrupted: isLast &&
                                    !widget.chat.isStreaming &&
                                    widget.chat.lastRoundInterrupted &&
                                    msg.role == 'assistant',
                                onResume: () =>
                                    widget.chat.resumeLastGeneration(),
                                // I7 搜索定位：命中气泡临时高亮（2s 渐隐）
                                highlight: _isHighlighted(msg.id),
                                // F2 钉住：钉住消息所在轮永不压缩进前情摘要
                                onTogglePin: (pinned) =>
                                    widget.chat.setMessagePinned(msg, pinned),
                                // I4 编辑重发：仅 user 消息且宿主有编辑能力
                                onEdit: msg.isUser && widget.onEditMessage != null
                                    ? () => widget.onEditMessage!(msg)
                                    : null,
                                // I5 引用追问：仅 assistant 消息且宿主有引用能力
                                onQuote: !msg.isUser && widget.onQuoteMessage != null
                                    ? () => widget.onQuoteMessage!(msg)
                                    : null,
                                // I3 重答：仅 assistant 消息且宿主有重答能力
                                onRegenerate: !msg.isUser &&
                                        widget.onRegenerateMessage != null
                                    ? () => widget.onRegenerateMessage!(msg)
                                    : null,
                                // M5 沉淀为卡片：user/assistant 消息均可
                                onSaveAsCard: widget.onSaveAsCard != null
                                    ? () => widget.onSaveAsCard!(msg)
                                    : null,
                                // F6 同问双答「用这个继续」：待选择态 assistant 气泡
                                onChooseDual: !msg.isUser &&
                                        msg.dualOf != null &&
                                        widget.onChooseDualMessage != null
                                    ? () => widget.onChooseDualMessage!(msg)
                                    : null,
                                // F8 引用溯源：assistant 气泡引用 chips 点击查原文
                                resolveChunk: widget.resolveChunk,
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
    required this.isStreaming,
    required this.onTap,
  });

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
                '回到最新',
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
