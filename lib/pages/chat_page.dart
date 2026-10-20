import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_session.dart';
import '../models/provider_profile.dart';
import '../models/skill.dart';
import '../providers/chat_provider.dart';
import '../providers/sessions_provider.dart';
import '../providers/skill_provider.dart';
import '../services/api_service.dart';
import '../services/database_service.dart';
import '../utils/haptics.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/chat_tags_bar.dart';
import '../widgets/message_bubble.dart';
import '../widgets/model_picker_sheet.dart';

/// 聊天页
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.sessionId, this.initialMessage});

  final String sessionId;

  /// 进入后自动发送的首条消息（主页打开即聊：发送时才创建会话）
  final String? initialMessage;

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
    // CustomScrollView（非 reverse）：offset 0 = 顶部 = 最新消息处
    // （reverse 消息列表填满视口，外层滚动 0 即消息底部）。
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
        final skill = context.read<SkillProvider>().byId(session.skillId);
        final provider = ChatProvider(
          database: DatabaseService.instance,
          api: ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey),
          session: session,
          profile: profile,
          model: session.model?.isNotEmpty == true
              ? session.model!
              : profile.defaultModel,
          skill: skill,
        )..loadMessages();
        // 主页打开即聊：进入后自动发送首条消息（等首帧完成再发）
        final initial = widget.initialMessage;
        if (initial != null && initial.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            provider.sendMessage(initial);
          });
        }
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
        // DeepSeek 式沉浸：CustomScrollView + SliverAppBar，消息上滑时 AppBar 收起
        body: CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverAppBar(
              pinned: true,
              floating: false,
              snap: false,
              // 上滑收起、下滑立即出现（沉浸阅读，回滑即导航）
              expandedHeight: 0,
              toolbarHeight: kToolbarHeight,
              // 标题不再承担切换入口（agent/model 移到输入框上方 tags）
              title: Text(
                chat.session.title,
                style: const TextStyle(fontSize: 17),
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
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
            // 错误提示条
            if (chat.status == ChatStatus.error)
              SliverToBoxAdapter(
                  child: _ErrorBanner(message: chat.errorMessage)),
            // 消息列表（reverse：底部锚定，天然显示最新消息）
            SliverFillRemaining(
              hasScrollBody: true,
              child: chat.displayMessages.isEmpty
                  ? _EmptyHint(effort: chat.session.effort)
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: chat.displayMessages.length,
                      itemBuilder: (context, index) {
                        // reverse 列表 index 0 = 列表末尾 = 最新消息
                        final msg = chat
                            .displayMessages[chat.displayMessages.length - 1 - index];
                        // tool 结果消息不单独渲染（存档上下文用，
                        // 结果展示在对应 assistant 消息的工具卡片内）
                        if (msg.isToolResult) return const SizedBox.shrink();
                        final isLast = index == 0;
                        return MessageBubble(
                          message: msg,
                          isStreaming: isLast && chat.isStreaming,
                          thinkingSeconds: chat.thinkingSeconds,
                          toolResults:
                              msg.id == chat.lastToolCallMessageId
                                  ? chat.toolResults
                                  : const [],
                          toolExecuting:
                              msg.id == chat.lastToolCallMessageId &&
                                  chat.status == ChatStatus.toolCalling,
                        );
                      },
                    ),
            ),
          ],
        ),
        // 输入栏固定在底部（不随 AppBar 收起，按钮按供应商能力显隐）
        // tags 行：agent/model 切换入口（DeepSeek 式，从 AppBar 移来）
        bottomNavigationBar: ChatInputBar(
          isStreaming: chat.isStreaming,
          effort: chat.session.effort,
          onSend: chat.sendMessage,
          onStop: chat.stopGeneration,
          onEffortChanged: chat.setEffort,
          showAttachmentButton: chat.supportsVision,
          showEffortButton: chat.supportsReasoning,
          tags: [
            ChatTag(
              icon: Icons.smart_toy_outlined,
              label: chat.skill != null
                  ? '${chat.skill!.icon} ${chat.skill!.name}'
                  : '默认助手',
              onTap: () => _showSkillSwitcher(context, chat),
            ),
            ChatTag(
              icon: Icons.tune,
              label: chat.model,
              onTap: () => showModelSwitcher(context, chat),
            ),
          ],
        ),
      ),
    );
  }

  /// 切换当前会话的 Skill
  Future<void> _showSkillSwitcher(
      BuildContext context, ChatProvider chat) async {
    Haptics.light();
    final skillsProvider = context.read<SkillProvider>();
    if (!skillsProvider.loaded) await skillsProvider.load();
    if (!context.mounted) return;

    final selected = await showModalBottomSheet<Skill?>(
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
              child: Text('切换 Skill',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // 默认助手（解绑 Skill）
                  ListTile(
                    leading: const Text('🤖',
                        style: TextStyle(fontSize: 24)),
                    title: const Text('默认助手'),
                    subtitle: const Text('无人格提示词，全部工具可用'),
                    trailing: chat.skill == null
                        ? Icon(Icons.check_circle,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () {
                      Haptics.selection();
                      Navigator.pop(context, null);
                    },
                  ),
                  for (final s in skillsProvider.skills)
                    ListTile(
                      leading: Text(s.icon,
                          style: const TextStyle(fontSize: 24)),
                      title: Text(s.name),
                      subtitle: s.description.isEmpty
                          ? null
                          : Text(
                              s.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: chat.skill?.id == s.id
                          ? Icon(Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary)
                          : null,
                      onTap: () {
                        Haptics.selection();
                        Navigator.pop(context, s);
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
    if (selected == null && chat.skill == null) return;
    if (selected?.id == chat.skill?.id) return;
    await chat.setSkill(selected);
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

