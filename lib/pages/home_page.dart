import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_session.dart';
import '../models/provider_profile.dart';
import '../models/skill.dart' as skill_model;
import '../providers/provider_provider.dart';
import '../providers/sessions_provider.dart';
import '../providers/skill_provider.dart';
import '../services/settings_service.dart';
import '../utils/haptics.dart';
import '../widgets/chat_tags_bar.dart';
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
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();

  // 打开即聊的预选状态（tags 行展示与切换）
  skill_model.Skill? _selectedSkill; // null = 默认助手
  (ProviderProfile, String)? _selectedModel; // null = 用默认供应商默认模型

  @override
  void initState() {
    super.initState();
    context.read<SessionsProvider>().loadSessions();
    // 启动即加载 Skill 列表：否则 tags 行的 Skill 图标在首次懒加载前显示兜底 emoji
    context.read<SkillProvider>().load();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
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

  /// 打开即聊：发送首条消息时才创建会话（DeepSeek 式）
  ///
  /// [text] 首条消息文本；[skillId]/[model] 为输入框上方 tags 预选值。
  Future<void> _startChat(String text,
      {String? skillId, (ProviderProfile, String)? modelPick}) async {
    Haptics.light();
    _unfocus();

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
      providerId: modelPick?.$1.id,
      model: modelPick?.$2,
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          sessionId: session.id,
          initialMessage: text,
        ),
      ),
    );
    sessions.refresh();
  }

  /// 抽屉「新对话」：仍走选 Skill 流程（历史入口保持原行为）
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

  /// Skill 选择弹窗（抽屉「新对话」用）：搜索 + 最近使用 + 全部折叠
  /// 返回 skillId（null = 默认助手），取消返回哨兵值
  static const _skillPickerCancelled = '__cancelled__';

  Future<String?> _showSkillPicker() async {
    final skills = context.read<SkillProvider>();
    if (!skills.loaded) await skills.load();

    if (!mounted) return _skillPickerCancelled;
    final result = await showModalBottomSheet<skill_model.Skill?>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SkillPickerSheet(
        skills: skills,
        recentIds: context.read<SettingsService>().recentSkillIds,
        onSelected: (s) => Navigator.pop(context, s),
      ),
    );
    if (result == null) return _skillPickerCancelled;
    return result.id == '__default__' ? null : result.id;
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
      // 圆形新对话按钮已移除：主页即聊天入口，历史对话走抽屉
      body: !sessions.loaded
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  // ===== 顶栏：抽屉入口（设置收进抽屉） =====
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
                      ],
                    ),
                  ),
                  // ===== 主页主体：问候语（居中） =====
                  Expanded(
                    child: Center(
                      child: Text(
                        '${_greeting()}，\n想聊点什么？',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ),
                  // ===== 底部：tags 行 + 真输入框（打开即聊） =====
                  _HomeInputBar(
                    controller: _inputController,
                    focusNode: _inputFocusNode,
                    selectedSkill: _selectedSkill,
                    selectedModel: _selectedModel,
                    onSend: _startChat,
                    onPickSkill: _pickSkillForHome,
                    onPickModel: _pickModelForHome,
                  ),
                ],
              ),
            ),
    );
  }

  /// 主页 agent tag：选择 Skill（含默认助手选项）
  Future<void> _pickSkillForHome() async {
    Haptics.light();
    final skills = context.read<SkillProvider>();
    if (!skills.loaded) await skills.load();
    if (!mounted) return;

    final result = await showModalBottomSheet<skill_model.Skill?>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SkillPickerSheet(
        skills: skills,
        recentIds: context.read<SettingsService>().recentSkillIds,
        includeDefault: true,
        selectedId: _selectedSkill?.id,
        onSelected: (s) => Navigator.pop(context, s),
      ),
    );
    if (result == null || !mounted) return; // 点遮罩关闭不改动
    // 哨兵 Skill（id='__default__'）= 默认助手 = null
    setState(() => _selectedSkill = result.id == '__default__' ? null : result);
  }

  /// 主页 model tag：选择供应商/模型（预选，创建会话时带上）
  Future<void> _pickModelForHome() async {
    Haptics.light();
    final providersProvider = context.read<ProviderProvider>();
    if (!providersProvider.loaded) await providersProvider.load();
    if (!mounted) return;

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
              child:
                  Text('切换模型', style: Theme.of(context).textTheme.titleMedium),
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
                        style:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                ),
                      ),
                    ),
                    if (p.defaultModel.isNotEmpty)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.model_training, size: 20),
                        title: Text(p.defaultModel),
                        trailing: _selectedModel != null &&
                                _selectedModel!.$1.id == p.id &&
                                _selectedModel!.$2 == p.defaultModel
                            ? Icon(Icons.check_circle,
                                color:
                                    Theme.of(context).colorScheme.primary)
                            : null,
                        onTap: () =>
                            Navigator.pop(context, (p, p.defaultModel)),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _selectedModel = selected);
  }
}

/// 主页底部输入区：tags 行（agent/model）+ 真输入框 + 发送键
///
/// DeepSeek 式打开即聊：文字可正常输入，发送时才创建会话并跳转聊天页。
class _HomeInputBar extends StatelessWidget {
  const _HomeInputBar({
    required this.controller,
    required this.focusNode,
    required this.selectedSkill,
    required this.selectedModel,
    required this.onSend,
    required this.onPickSkill,
    required this.onPickModel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final skill_model.Skill? selectedSkill;
  final (ProviderProfile, String)? selectedModel;
  final void Function(String text,
      {String? skillId, (ProviderProfile, String)? modelPick}) onSend;
  final VoidCallback onPickSkill;
  final VoidCallback onPickModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // tags 行：agent / model（与聊天页一致的切换入口）
            ChatTagsBar(tags: [
              ChatTag(
                icon: Icons.smart_toy_outlined,
                label: selectedSkill != null
                    ? '${selectedSkill!.icon} ${selectedSkill!.name}'
                    : '默认助手',
                onTap: onPickSkill,
              ),
              ChatTag(
                icon: Icons.tune,
                label: selectedModel?.$2 ?? '默认模型',
                onTap: onPickModel,
              ),
            ]),
            const SizedBox(height: 6),
            // 输入行
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    maxLines: null,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(context),
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                    decoration: InputDecoration(
                      hintText: '给 Liang AI 发送消息',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                ValueListenableBuilder(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final hasText = value.text.trim().isNotEmpty;
                    return IconButton.filled(
                      onPressed: hasText ? () => _send(context) : null,
                      icon: const Icon(Icons.arrow_upward_rounded),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _send(BuildContext context) {
    final text = controller.text.trim();
    if (text.isEmpty) return;
    onSend(
      text,
      skillId: selectedSkill?.id,
      modelPick: selectedModel,
    );
    controller.clear();
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
///
/// [includeDefault] = true 时（主页 agent tag 用）顶部多一个「默认助手」选项，
/// 返回哨兵 Skill（id='__default__'，isBuiltin=true）；回调改为传 Skill 对象。
class _SkillPickerSheet extends StatefulWidget {
  const _SkillPickerSheet({
    required this.skills,
    required this.recentIds,
    required this.onSelected,
    this.includeDefault = false,
    this.selectedId,
  });

  final SkillProvider skills;

  /// 最近使用的 skillId（index 0 = 最近）
  final List<String> recentIds;
  final ValueChanged<skill_model.Skill?> onSelected;

  /// 主页 agent tag 模式：顶部显示「默认助手」选项
  final bool includeDefault;

  /// 当前选中的 skillId（主页 agent tag 回显用）
  final String? selectedId;

  @override
  State<_SkillPickerSheet> createState() => _SkillPickerSheetState();
}

/// 「默认助手」哨兵 Skill（includeDefault 模式下选中返回它）
skill_model.Skill get _defaultAssistantSkill => skill_model.Skill(
      id: '__default__',
      name: '默认助手',
      prompt: '',
      isBuiltin: true,
    );

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
                // ===== 默认助手（主页 agent tag 模式） =====
                if (widget.includeDefault)
                  ListTile(
                    leading: const Text('🤖',
                        style: TextStyle(fontSize: 24)),
                    title: const Text('默认助手'),
                    subtitle: const Text('无人格提示词，全部工具可用'),
                    trailing: widget.selectedId == null
                        ? Icon(Icons.check_circle,
                            color: theme.colorScheme.primary)
                        : null,
                    onTap: () {
                      Haptics.selection();
                      widget.onSelected(_defaultAssistantSkill);
                    },
                  ),
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
                              widget.onSelected(a);
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
                        // 当前选中 / 最近使用过的标记
                        trailing: widget.selectedId == a.id
                            ? Icon(Icons.check_circle,
                                color: theme.colorScheme.primary)
                            : (q.isEmpty &&
                                    recentIdsInFiltered.contains(a.id)
                                ? Icon(Icons.circle,
                                    size: 8,
                                    color: theme.colorScheme.primary)
                                : null),
                        onTap: () {
                          Haptics.selection();
                          widget.onSelected(a);
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
