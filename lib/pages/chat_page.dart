import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_session.dart';
import '../providers/chat_provider.dart';
import '../providers/sessions_provider.dart';
import '../services/api_service.dart';
import '../services/database_service.dart';
import '../services/settings_service.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/message_bubble.dart';

/// 聊天页
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scrollController = ScrollController();
  bool _autoScrollEnabled = true;
  int _lastDisplayCount = 0;
  ChatSession? _session;

  @override
  void initState() {
    super.initState();
    DatabaseService.instance
        .getSession(widget.sessionId)
        .then((s) => setState(() => _session = s));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(int newCount) {
    if (!_autoScrollEnabled || !_scrollController.hasClients) return;
    if (newCount != _lastDisplayCount) {
      final isFirstLoad = _lastDisplayCount == 0 && newCount > 0;
      _lastDisplayCount = newCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        if (isFirstLoad) {
          _jumpToBottomWithRetry(0);
        } else {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    } else if (_scrollController.position.maxScrollExtent > 0) {
      // 流式增长时跟随滚动
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  /// 首次加载时列表尚未完成布局，maxScrollExtent 可能为 0，
  /// 逐帧重试直到列表完成布局后跳到底部
  void _jumpToBottomWithRetry(int attempt) {
    if (attempt > 10) return; // 最多重试 10 帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (max > 0) {
        _scrollController.jumpTo(max);
      } else {
        _jumpToBottomWithRetry(attempt + 1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsService>();
    final session = _session;

    if (session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return ChangeNotifierProvider(
      key: ValueKey(widget.sessionId),
      create: (_) {
        final provider = ChatProvider(
          database: DatabaseService.instance,
          api: ApiService(baseUrl: settings.baseUrl, apiKey: settings.apiKey),
          session: session,
          model: settings.model,
        )..loadMessages();
        return provider;
      },
      child: _ChatPageView(
        scrollController: _scrollController,
        onScroll: (offset) {
          // 用户向上滚动时暂停自动滚动
          final max = _scrollController.position.maxScrollExtent;
          _autoScrollEnabled = offset >= max - 80;
        },
        onCountChanged: _maybeAutoScroll,
      ),
    );
  }
}

class _ChatPageView extends StatelessWidget {
  const _ChatPageView({
    required this.scrollController,
    required this.onScroll,
    required this.onCountChanged,
  });

  final ScrollController scrollController;
  final ValueChanged<double> onScroll;
  final void Function(int newCount) onCountChanged;

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final sessions = context.read<SessionsProvider>();

    onCountChanged(chat.displayMessages.length);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) sessions.refresh();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            chat.session.title,
            style: const TextStyle(fontSize: 17),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除会话',
              onPressed: () => _confirmDelete(context, chat, sessions),
            ),
          ],
        ),
        body: Column(
          children: [
            // 错误提示条
            if (chat.status == ChatStatus.error)
              _ErrorBanner(message: chat.errorMessage),
            // 消息列表
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n is ScrollUpdateNotification) {
                    onScroll(n.metrics.pixels);
                  }
                  return false;
                },
                child: chat.displayMessages.isEmpty
                    ? _EmptyHint(effort: chat.session.effort)
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        itemCount: chat.displayMessages.length,
                        itemBuilder: (context, index) {
                          final msg = chat.displayMessages[index];
                          final isLast =
                              index == chat.displayMessages.length - 1;
                          return MessageBubble(
                            message: msg,
                            isStreaming: isLast && chat.isStreaming,
                            thinkingSeconds: chat.thinkingSeconds,
                          );
                        },
                      ),
              ),
            ),
            // 输入栏
            ChatInputBar(
              isStreaming: chat.isStreaming,
              effort: chat.session.effort,
              onSend: chat.sendMessage,
              onStop: chat.stopGeneration,
              onEffortChanged: chat.setEffort,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ChatProvider chat,
    SessionsProvider sessions,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: const Text('删除后聊天记录无法恢复，确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      if (chat.isStreaming) chat.stopGeneration();
      await sessions.deleteSession(chat.session.id);
      if (context.mounted) Navigator.pop(context);
    }
  }
}

/// 错误提示条
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              size: 18, color: colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: 13, color: colorScheme.onErrorContainer),
            ),
          ),
          InkWell(
            onTap: () => context.read<ChatProvider>().clearError(),
            child: Icon(Icons.close,
                size: 16, color: colorScheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

/// 空会话提示
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.effort});

  final String effort;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effortText = switch (effort) {
      'max' => '深度推理',
      'high' => '均衡推理',
      'low' => '轻量推理',
      _ => effort,
    };
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.smart_toy_outlined,
              size: 56, color: theme.colorScheme.primary.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('开始你的第一次对话',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '当前推理深度：$effortText',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
