import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/sessions_provider.dart';
import '../services/settings_service.dart';
import 'chat_page.dart';
import 'settings_page.dart';

/// 首页：会话列表（仿豆包）
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    context.read<SessionsProvider>().loadSessions();
  }

  Future<void> _newChat() async {
    final settings = context.read<SettingsService>();
    final sessions = context.read<SessionsProvider>();
    final session = await sessions.createSession(settings.defaultEffortValue);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatPage(sessionId: session.id)),
    );
    sessions.refresh();
  }

  Future<void> _openChat(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatPage(sessionId: id)),
    );
    if (mounted) context.read<SessionsProvider>().refresh();
  }

  Future<void> _renameSession(BuildContext context, String id, String current) async {
    final controller = TextEditingController(text: current);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(hintText: '会话名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newTitle != null && newTitle.isNotEmpty && newTitle != current) {
      if (context.mounted) {
        context.read<SessionsProvider>().renameSession(id, newTitle);
      }
    }
  }

  Future<void> _deleteSession(BuildContext context, String id) async {
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
      context.read<SessionsProvider>().deleteSession(id);
    }
  }

  /// 长按会话卡片：弹出操作菜单（重命名/删除）
  Future<void> _showSessionActions(
      BuildContext context, String id, String title) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'rename') {
      _renameSession(context, id, title);
    } else if (action == 'delete') {
      _deleteSession(context, id);
    }
  }

  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.year}/${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = context.watch<SessionsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Liang AI'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newChat,
        icon: const Icon(Icons.add),
        label: const Text('新对话'),
      ),
      body: !sessions.loaded
          ? const Center(child: CircularProgressIndicator())
          : sessions.sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 64,
                          color: theme.colorScheme.primary.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      Text('暂无会话', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        '点击右下角「新对话」开始',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                  itemCount: sessions.sessions.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 2),
                  itemBuilder: (context, index) {
                    final s = sessions.sessions[index];
                    final effortText = switch (s.effort) {
                      'max' => '深度',
                      'high' => '均衡',
                      'low' => '轻量',
                      _ => s.effort,
                    };
                    return Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        leading: Icon(
                          Icons.chat_bubble_outline,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '$effortText · ${_formatTime(s.updatedAt)}',
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: PopupMenuButton<String>(
                          icon: Icon(Icons.more_vert,
                              color: theme.colorScheme.onSurfaceVariant),
                          onSelected: (value) {
                            if (value == 'rename') {
                              _renameSession(context, s.id, s.title);
                            } else if (value == 'delete') {
                              _deleteSession(context, s.id);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'rename',
                                child: Row(children: [
                                  Icon(Icons.edit_outlined, size: 18),
                                  SizedBox(width: 8),
                                  Text('重命名'),
                                ])),
                            PopupMenuItem(
                                value: 'delete',
                                child: Row(children: [
                                  Icon(Icons.delete_outline, size: 18),
                                  SizedBox(width: 8),
                                  Text('删除'),
                                ])),
                          ],
                        ),
                        onTap: () => _openChat(s.id),
                        onLongPress: () => _showSessionActions(context, s.id, s.title),
                      ),
                    );
                  },
                ),
    );
  }
}
