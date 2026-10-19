import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/agent.dart';
import '../models/chat_session.dart';
import '../models/provider_profile.dart';
import '../providers/agent_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/provider_provider.dart';
import '../providers/sessions_provider.dart';
import '../services/api_service.dart';
import '../services/database_service.dart';
import '../utils/haptics.dart';
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
  int _lastDisplayCount = 0;
  ChatSession? _session;
  ProviderProfile? _profile;

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  /// 加载会话与其绑定的供应商 profile（未绑定或已删除时回退默认）
  Future<void> _loadSession() async {
    final db = DatabaseService.instance;
    final s = await db.getSession(widget.sessionId);
    if (!mounted) return;
    final profiles = await db.getAllProviders();
    ProviderProfile profile;
    if (s?.providerId != null) {
      profile = profiles.firstWhere(
        (p) => p.id == s!.providerId,
        orElse: () => profiles.first,
      );
    } else {
      profile = profiles.first;
    }
    if (!mounted) return;
    setState(() {
      _session = s;
      _profile = profile;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(int newCount) {
    if (!_scrollController.hasClients) return;
    // reverse 列表：offset 0 即最新消息处。
    // 发送新消息（数量增加）时跳回底部；流式增长时若用户停在底部则跟随。
    if (newCount != _lastDisplayCount) {
      final isNewMessage = newCount > _lastDisplayCount;
      _lastDisplayCount = newCount;
      if (isNewMessage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(0);
          }
        });
      }
    } else if (_scrollController.offset <= 0.5) {
      // 用户正停在底部，流式输出时跟随滚动
      _scrollController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final profile = _profile;

    if (session == null || profile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return ChangeNotifierProvider(
      key: ValueKey(widget.sessionId),
      create: (_) {
        final agent = context.read<AgentProvider>().byId(session.agentId);
        final provider = ChatProvider(
          database: DatabaseService.instance,
          api: ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey),
          session: session,
          profile: profile,
          model: session.model?.isNotEmpty == true
              ? session.model!
              : profile.defaultModel,
          agent: agent,
        )..loadMessages();
        return provider;
      },
      child: _ChatPageView(
        scrollController: _scrollController,
        onCountChanged: _maybeAutoScroll,
      ),
    );
  }
}

class _ChatPageView extends StatelessWidget {
  const _ChatPageView({
    required this.scrollController,
    required this.onCountChanged,
  });

  final ScrollController scrollController;
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
          title: GestureDetector(
            onTap: () => _showAgentSwitcher(context, chat),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  chat.session.title,
                  style: const TextStyle(fontSize: 17),
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      chat.agent != null
                          ? '${chat.agent!.icon} ${chat.agent!.name}'
                          : '🤖 默认助手',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const Icon(Icons.keyboard_arrow_down, size: 14),
                  ],
                ),
              ],
            ),
          ),
          // 模型切换（会话级，仿豆包）
          actions: [
            _ModelSwitchButton(chat: chat),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除会话',
              onPressed: () {
                Haptics.light();
                _confirmDelete(context, chat, sessions);
              },
            ),
          ],
        ),
        body: Column(
          children: [
            // 错误提示条
            if (chat.status == ChatStatus.error)
              _ErrorBanner(message: chat.errorMessage),
            // 消息列表（reverse：底部锚定，天然显示最新消息）
            Expanded(
              child: chat.displayMessages.isEmpty
                  ? _EmptyHint(effort: chat.session.effort)
                  : ListView.builder(
                      controller: scrollController,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: chat.displayMessages.length,
                      itemBuilder: (context, index) {
                        // reverse 列表 index 0 = 列表末尾 = 最新消息
                        final msg = chat
                            .displayMessages[chat.displayMessages.length - 1 - index];
                        final isLast = index == 0;
                        return MessageBubble(
                          message: msg,
                          isStreaming: isLast && chat.isStreaming,
                          thinkingSeconds: chat.thinkingSeconds,
                        );
                      },
                    ),
            ),
            // 输入栏（按钮按供应商能力显隐）
            ChatInputBar(
              isStreaming: chat.isStreaming,
              effort: chat.session.effort,
              onSend: chat.sendMessage,
              onStop: chat.stopGeneration,
              onEffortChanged: chat.setEffort,
              showAttachmentButton: chat.supportsVision,
              showEffortButton: chat.supportsReasoning,
            ),
          ],
        ),
      ),
    );
  }

  /// 切换当前会话的 Agent
  Future<void> _showAgentSwitcher(
      BuildContext context, ChatProvider chat) async {
    Haptics.light();
    final agentsProvider = context.read<AgentProvider>();
    if (!agentsProvider.loaded) await agentsProvider.load();
    if (!context.mounted) return;

    final selected = await showModalBottomSheet<Agent?>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('切换 Agent',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // 默认助手（解绑 Agent）
                  ListTile(
                    leading: const Text('🤖',
                        style: TextStyle(fontSize: 24)),
                    title: const Text('默认助手'),
                    subtitle: const Text('无人格提示词，通用问答'),
                    trailing: chat.agent == null
                        ? Icon(Icons.check_circle,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () {
                      Haptics.selection();
                      Navigator.pop(context, null);
                    },
                  ),
                  for (final a in agentsProvider.agents)
                    ListTile(
                      leading: Text(a.icon,
                          style: const TextStyle(fontSize: 24)),
                      title: Text(a.name),
                      subtitle: a.description.isEmpty
                          ? null
                          : Text(
                              a.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: chat.agent?.id == a.id
                          ? Icon(Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary)
                          : null,
                      onTap: () {
                        Haptics.selection();
                        Navigator.pop(context, a);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    // 未选择（点击遮罩关闭）不改动
    if (!context.mounted) return;
    if (selected == null && chat.agent == null) return;
    if (selected?.id == chat.agent?.id) return;
    await chat.setAgent(selected);
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
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, true);
            },
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
            onTap: () {
              Haptics.light();
              context.read<ChatProvider>().clearError();
            },
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

/// AppBar 模型切换按钮：显示当前模型名，点击弹出供应商/模型选择
class _ModelSwitchButton extends StatelessWidget {
  const _ModelSwitchButton({required this.chat});

  final ChatProvider chat;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => _showModelSwitcher(context, chat),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 36),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tune,
              size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              chat.model,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 供应商/模型选择弹窗：按供应商分组列出，选中即切换（会话级）
  Future<void> _showModelSwitcher(
      BuildContext context, ChatProvider chat) async {
    Haptics.light();
    final providersProvider = context.read<ProviderProvider>();
    if (!providersProvider.loaded) await providersProvider.load();
    if (!context.mounted) return;

    // 自定义模型名输入（会话级临时模型）
    final customCtrl = TextEditingController(text: chat.model);
    final selected = await showModalBottomSheet<(ProviderProfile, String)>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('切换模型',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in providersProvider.profiles) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                      child: Text(
                        p.name,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                    if (p.defaultModel.isNotEmpty)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.model_training, size: 20),
                        title: Text(p.defaultModel),
                        trailing: chat.profile.id == p.id &&
                                chat.model == p.defaultModel
                            ? Icon(Icons.check_circle,
                                color: Theme.of(context).colorScheme.primary)
                            : null,
                        onTap: () => Navigator.pop(context, (p, p.defaultModel)),
                      ),
                  ],
                  const Divider(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: customCtrl,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: '自定义模型名（当前供应商）',
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.check, size: 20),
                          onPressed: () => Navigator.pop(
                              context, (chat.profile, customCtrl.text.trim())),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !context.mounted) return;

    final (profile, model) = selected;
    if (model.isEmpty) return;
    final ok = await chat.switchProvider(profile, model);
    if (context.mounted && !ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('生成进行中，无法切换模型'),
            duration: Duration(seconds: 2)),
      );
    }
  }
}
