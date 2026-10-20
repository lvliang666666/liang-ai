import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_session.dart';
import '../models/skill.dart' as skill_model;
import '../providers/sessions_provider.dart';
import '../providers/skill_provider.dart';
import '../services/settings_service.dart';
import '../utils/haptics.dart';
import 'chat_page.dart';
import 'settings_page.dart';

/// 首页：DeepSeek 风格——问候语 + 居中大输入框 + 最近会话流 + 侧滑抽屉
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    context.read<SessionsProvider>().loadSessions();
    // 启动即加载 Skill 列表：否则会话卡片的 Skill 图标在首次懒加载前显示兜底 emoji
    context.read<SkillProvider>().load();
  }

  /// 导航前收起键盘，避免返回主页时自动弹键盘
  void _unfocus() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 按时段问候语
  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5) return '夜深了';
    if (hour < 11) return '早上好';
    if (hour < 13) return '中午好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  Future<void> _newChat() async {
    Haptics.light();
    _unfocus();
    // 选 Skill + 确认（null = 默认助手）
    final skillId = await _showSkillPicker();
    if (skillId == _skillPickerCancelled || !mounted) return;

    final settings = context.read<SettingsService>();
    // 记录最近使用（LRU），供下次选择页展示
    if (skillId != null) {
      await settings.touchRecentSkill(skillId);
      if (!mounted) return;
    }
    final sessions = context.read<SessionsProvider>();
    final session = await sessions.createSession(
      settings.defaultEffortValue,
      skillId: skillId,
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatPage(sessionId: session.id)),
    );
    sessions.refresh();
  }

  /// Skill 选择弹窗：搜索 + 最近使用（3 个）+ 全部折叠；返回 skillId，取消返回哨兵值
  static const _skillPickerCancelled = '__cancelled__';

  Future<String?> _showSkillPicker() async {
    final skills = context.read<SkillProvider>();
    if (!skills.loaded) await skills.load();

    if (!mounted) return _skillPickerCancelled;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SkillPickerSheet(
        skills: skills,
        recentIds: context.read<SettingsService>().recentSkillIds,
        onSelected: (id) => Navigator.pop(context, id),
      ),
    );
    return result ?? _skillPickerCancelled;
  }

  Future<void> _openChat(String id) async {
    Haptics.light();
    _unfocus();
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
            onPressed: () {
              Haptics.light();
              Navigator.pop(context);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, controller.text.trim());
            },
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
      context.read<SessionsProvider>().deleteSession(id);
    }
  }

  /// 长按会话卡片：弹出操作菜单（重命名/删除）
  Future<void> _showSessionActions(
      BuildContext context, String id, String title) async {
    Haptics.medium();
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
              onTap: () {
                Haptics.light();
                Navigator.pop(context, 'rename');
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Haptics.light();
                Navigator.pop(context, 'delete');
              },
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = context.watch<SessionsProvider>();
    final skillsProvider = context.watch<SkillProvider>();

    final allSessions = sessions.sessions;

    return Scaffold(
      key: _scaffoldKey,
      // 侧滑抽屉：完整会话列表（DeepSeek 式）
      drawer: _SessionDrawer(
        sessions: allSessions,
        skillsProvider: skillsProvider,
        loaded: sessions.loaded,
        onOpenChat: (id) {
          Navigator.pop(context); // 先关抽屉
          _openChat(id);
        },
        onNewChat: () {
          Navigator.pop(context);
          _newChat();
        },
        onOpenSettings: () {
          Navigator.pop(context);
          Haptics.light();
          _unfocus();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsPage()),
          );
        },
        onRename: (ctx, id, title) => _renameSession(ctx, id, title),
        onDelete: (ctx, id) => _deleteSession(ctx, id),
        onShowActions: (ctx, id, title) =>
            _showSessionActions(ctx, id, title),
      ),
      // 圆形新对话按钮：64px + 28px 加号，位置略向左上偏移（仍在右下角）
      floatingActionButton: Container(
        margin: const EdgeInsets.only(right: 12, bottom: 12),
        width: 64,
        height: 64,
        child: FloatingActionButton(
          onPressed: _newChat,
          shape: const CircleBorder(),
          child: const Icon(Icons.add, size: 28),
        ),
      ),
      body: !sessions.loaded
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  // ===== 顶栏：抽屉入口 + 新建（设置收进抽屉） =====
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.menu),
                          tooltip: '会话列表',
                          onPressed: () {
                            Haptics.light();
                            _scaffoldKey.currentState?.openDrawer();
                          },
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: '新对话',
                          onPressed: _newChat,
                        ),
                      ],
                    ),
                  ),
                  // ===== 主页主体：仅问候语 + 大输入框（居中） =====
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${_greeting()}，\n想聊点什么？',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 32),
                          // 大输入框（点击即新建会话）
                          _HeroInput(onTap: _newChat),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// 首页大输入框：点击即新建会话（DeepSeek 式入口）
class _HeroInput extends StatelessWidget {
  const _HeroInput({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () {
        Haptics.selection();
        onTap();
      },
      borderRadius: BorderRadius.circular(28),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.edit_note_outlined,
                size: 22, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '给 Liang AI 发送消息',
                style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Icon(Icons.arrow_upward_rounded,
                size: 22, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

/// 侧滑抽屉：完整会话列表按时间分组（今天 / 7 天内 / 更早）
class _SessionDrawer extends StatelessWidget {
  const _SessionDrawer({
    required this.sessions,
    required this.skillsProvider,
    required this.loaded,
    required this.onOpenChat,
    required this.onNewChat,
    required this.onOpenSettings,
    required this.onRename,
    required this.onDelete,
    required this.onShowActions,
  });

  final List<ChatSession> sessions;
  final SkillProvider skillsProvider;
  final bool loaded;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onNewChat;
  final VoidCallback onOpenSettings;
  final void Function(BuildContext, String, String) onRename;
  final void Function(BuildContext, String) onDelete;
  final void Function(BuildContext, String, String) onShowActions;

  /// 按时间分组：今天 / 7 天内 / 更早
  Map<String, List<ChatSession>> get _grouped {
    final now = DateTime.now();
    final startOfToday =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final sevenDaysAgo = startOfToday - 7 * 24 * 3600 * 1000;
    final groups = <String, List<ChatSession>>{
      '今天': [],
      '7 天内': [],
      '更早': [],
    };
    for (final s in sessions) {
      if (s.updatedAt >= startOfToday) {
        groups['今天']!.add(s);
      } else if (s.updatedAt >= sevenDaysAgo) {
        groups['7 天内']!.add(s);
      } else {
        groups['更早']!.add(s);
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // 抽屉头部：Logo + 新对话 + 设置
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(
                children: [
                  Text('Liang AI',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add, size: 22),
                    tooltip: '新对话',
                    onPressed: onNewChat,
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 22),
                    tooltip: '设置',
                    onPressed: onOpenSettings,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 会话列表（按时间分组）
            Expanded(
              child: !loaded
                  ? const Center(child: CircularProgressIndicator())
                  : sessions.isEmpty
                      ? Center(
                          child: Text('暂无会话',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color:
                                      theme.colorScheme.onSurfaceVariant)),
                        )
                      : ListView(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          children: [
                            for (final entry in _grouped.entries)
                              if (entry.value.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 12, 16, 4),
                                  child: Text(entry.key,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                              color: theme.colorScheme
                                                  .onSurfaceVariant)),
                                ),
                                for (final s in entry.value)
                                  ListTile(
                                    dense: true,
                                    leading: Text(
                                      skillsProvider.byId(s.skillId)?.icon ??
                                          '💬',
                                      style:
                                          const TextStyle(fontSize: 18),
                                    ),
                                    title: Text(
                                      s.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                    onTap: () => onOpenChat(s.id),
                                    onLongPress: () =>
                                        onShowActions(context, s.id, s.title),
                                  ),
                              ],
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Skill 选择弹窗内容：搜索 + 最近使用 + 全部折叠
class _SkillPickerSheet extends StatefulWidget {
  const _SkillPickerSheet({
    required this.skills,
    required this.recentIds,
    required this.onSelected,
  });

  final SkillProvider skills;

  /// 最近使用的 skillId（index 0 = 最近）
  final List<String> recentIds;
  final ValueChanged<String> onSelected;

  @override
  State<_SkillPickerSheet> createState() => _SkillPickerSheetState();
}

class _SkillPickerSheetState extends State<_SkillPickerSheet> {
  String _query = '';
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = widget.skills.skills;

    // 搜索过滤
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? all
        : all
            .where((a) =>
                a.name.toLowerCase().contains(q) ||
                a.description.toLowerCase().contains(q))
            .toList();

    // 最近使用：按 LRU 顺序取存在的 Skill；无历史时随机取 3 个
    final recent = <skill_model.Skill>[];
    if (widget.recentIds.isEmpty) {
      recent.addAll(all);
      recent.shuffle();
      if (recent.length > 3) recent.length = 3;
    } else {
      for (final id in widget.recentIds) {
        final a = widget.skills.byId(id);
        if (a != null) recent.add(a);
      }
    }
    final recentIdsInFiltered = recent.map((a) => a.id).toSet();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('选择 Skill 开始新对话',
                style: theme.textTheme.titleMedium),
          ),
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索 Skill',
                prefixIcon: const Icon(Icons.search, size: 20),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                // ===== 最近使用（搜索时隐藏） =====
                if (q.isEmpty && recent.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text('最近使用',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  Row(
                    children: [
                      for (final a in recent)
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              Haptics.selection();
                              widget.onSelected(a.id);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8),
                              child: Column(
                                children: [
                                  Text(a.icon,
                                      style: const TextStyle(
                                          fontSize: 28)),
                                  const SizedBox(height: 4),
                                  Text(
                                    a.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // 不足 3 个时占位对齐
                      for (var i = recent.length; i < 3; i++)
                        const Expanded(child: SizedBox()),
                    ],
                  ),
                  const Divider(height: 16),
                ],
                // ===== 全部 Skill =====
                if (q.isEmpty)
                  ListTile(
                    leading: Icon(
                      _showAll
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text('全部 Skill（${all.length}）',
                        style: theme.textTheme.titleSmall),
                    onTap: () {
                      Haptics.light();
                      setState(() => _showAll = !_showAll);
                    },
                  ),
                // 搜索时直接展示全部结果；未搜索时按折叠状态
                if (q.isNotEmpty || _showAll)
                  ...filtered.map((a) => ListTile(
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
                        // 最近使用过的标记小圆点
                        trailing: q.isEmpty &&
                                recentIdsInFiltered.contains(a.id)
                            ? Icon(Icons.circle,
                                size: 8,
                                color: theme.colorScheme.primary)
                            : null,
                        onTap: () {
                          Haptics.selection();
                          widget.onSelected(a.id);
                        },
                      )),
                if (q.isNotEmpty && filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text('没有找到「$_query」',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color:
                                  theme.colorScheme.onSurfaceVariant)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
