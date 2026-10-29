import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/memory.dart';
import '../providers/memory_provider.dart';
import '../services/settings_service.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';

/// 记忆管理面板：查看/搜索/删除/手动添加 AI 长期记忆
///
/// 记忆为全局共享池（所有 Skill 共用），跨会话生效。
/// 嵌入设置页 PageView 作为独立 tag，无自带 Scaffold。
class MemoryPanel extends StatefulWidget {
  const MemoryPanel({super.key});

  @override
  State<MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<MemoryPanel> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _query = '';
  bool _loadRequested = false;

  /// 当前选中的 tag 筛选（null = 全部）
  String? _tagFilter;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _unfocus() {
    if (_searchFocusNode.hasFocus) _searchFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<MemoryProvider>();

    // 首帧后触发加载（build 期间同步调 load + notifyListeners 会抛
    // markNeedsBuild during build，widget 测试必崩）
    if (!provider.loaded && !_loadRequested) {
      _loadRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) provider.load();
      });
    }

    if (!provider.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    // 搜索过滤（不区分大小写）
    final query = _query.trim().toLowerCase();
    var filtered = query.isEmpty
        ? provider.memories
        : provider.memories
            .where((m) =>
                m.content.toLowerCase().contains(query) ||
                (m.tag?.toLowerCase().contains(query) ?? false))
            .toList();

    // tag 筛选（与搜索叠加）
    if (_tagFilter != null) {
      filtered = filtered.where((m) => m.tag == _tagFilter).toList();
    }

    // 置顶组恒在列表最前（组内按更新时间倒序，与全量排序一致）
    final pinnedList = filtered.where((m) => m.pinned).toList();
    final normalList = filtered.where((m) => !m.pinned).toList();

    // 动态 tag 集合（出现过的 tag 都可筛选；归档摘要也算一类）
    final tags = <String>{
      for (final m in provider.memories)
        if (m.tag != null) m.tag!,
    }.toList()..sort();

    return Column(
      children: [
        // 搜索框 + 手动添加/清空按钮（与 Skill 管理 tab 同布局）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索记忆',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              Haptics.light();
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (provider.memories.isNotEmpty)
                IconButton.outlined(
                  tooltip: '清空全部',
                  onPressed: () {
                    Haptics.medium();
                    _unfocus();
                    _confirmDeleteAll(context);
                  },
                  icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () {
                  Haptics.light();
                  _unfocus();
                  _showAddDialog(context);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加'),
              ),
            ],
          ),
        ),
        // M2 自动记忆沉淀开关（会话结束自动提取记忆入库）
        SwitchListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          title: const Text('自动记忆沉淀'),
          subtitle: const Text(
            '会话结束后自动提取值得记住的信息入库（静默进行，'
            '可在此删除）；关闭后仅手动「记住xxx」生效',
          ),
          value: context.watch<SettingsService>().autoMemory,
          onChanged: (v) {
            Haptics.selection();
            context.read<SettingsService>().setAutoMemory(v);
          },
        ),
        // M4 情景记忆层开关（会话结束生成摘要，模型可检索历史会话）
        SwitchListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          title: const Text('情景记忆'),
          subtitle: const Text(
            '会话结束后自动生成标题与摘要入库，模型可经 search_history '
            '工具回顾「之前聊过什么」（静默进行）；关闭后不生成不检索',
          ),
          value: context.watch<SettingsService>().episodicMemory,
          onChanged: (v) {
            Haptics.selection();
            context.read<SettingsService>().setEpisodicMemory(v);
          },
        ),
        // tag 筛选 chips（横向滚动；无 tag 时隐藏）
        if (tags.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('全部'),
                    selected: _tagFilter == null,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) {
                      Haptics.selection();
                      setState(() => _tagFilter = null);
                    },
                  ),
                ),
                for (final tag in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(tag),
                      selected: _tagFilter == tag,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        Haptics.selection();
                        setState(() {
                          _tagFilter = _tagFilter == tag ? null : tag;
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      provider.memories.isEmpty
                          ? 'AI 还没有记住任何东西\n聊天中让它「记住xxx」即可'
                          : '没有找到「$_query」',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.6),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    // 置顶组（永久记忆）
                    if (pinnedList.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
                        child: Text('📌 置顶（永久记忆，注入不占名额）',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ),
                      ...pinnedList.map((m) => _memoryCard(theme, provider, m)),
                      const SizedBox(height: 8),
                    ],
                    // 普通组
                    ...normalList.map((m) => _memoryCard(theme, provider, m)),
                    const SizedBox(height: 8),
                    Text(
                      '· 记忆全局共享：所有 Skill 的对话都会注入最近 20 条\n'
                      '· 置顶记忆永久注入且不参与滚动压缩淘汰\n'
                      '· 聊天中说「记住xxx」AI 会自动保存，「忘掉xxx」会删除\n'
                      '· 记忆仅存本机数据库，不会上传',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.6),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 单条记忆卡片：置顶标记 + 编辑/置顶/删除操作
  Widget _memoryCard(
      ThemeData theme, MemoryProvider provider, Memory m) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: ListTile(
        title: Text(m.content),
        subtitle: (m.tag != null || m.sourceSkill != null)
            ? Text(
                [
                  if (m.tag != null) m.tag!,
                  if (m.sourceSkill != null) '来自 ${m.sourceSkill}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 置顶/取消置顶
            IconButton(
              icon: Icon(
                m.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 20,
                color: m.pinned ? theme.colorScheme.primary : null,
              ),
              tooltip: m.pinned ? '取消置顶' : '置顶',
              onPressed: () {
                Haptics.light();
                provider.setPinned(m.id, !m.pinned);
              },
            ),
            // 编辑（归档摘要行是系统产物，不允许编辑）
            if (!m.isArchived)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: '编辑',
                onPressed: () {
                  Haptics.light();
                  _unfocus();
                  _showEditDialog(context, m);
                },
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '删除',
              onPressed: () {
                Haptics.medium();
                _unfocus();
                provider.delete(m.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 手动添加记忆弹窗
  Future<void> _showAddDialog(BuildContext context) async {
    final result = await showDialog<_MemoryFormResult>(
      context: context,
      builder: (context) => const _MemoryFormDialog(),
    );

    if (result == null || !mounted) return;
    final trimmed = result.content.trim();
    if (trimmed.isEmpty) return;
    await context.read<MemoryProvider>().add(
          trimmed,
          tag: result.tag,
        );
    if (mounted) {
      showAppToast(context, '已添加');
    }
  }

  /// 编辑记忆弹窗（内容 + 标签）
  Future<void> _showEditDialog(BuildContext context, Memory memory) async {
    final result = await showDialog<_MemoryFormResult>(
      context: context,
      builder: (context) => _MemoryFormDialog(
        initialContent: memory.content,
        initialTag: memory.tag,
        title: '编辑记忆',
      ),
    );

    if (result == null || !mounted) return;
    final trimmed = result.content.trim();
    if (trimmed.isEmpty) return;
    await context.read<MemoryProvider>().update(
          memory.id,
          content: trimmed,
          tag: result.tag,
        );
    if (mounted) {
      showAppToast(context, '已更新');
    }
  }

  /// 清空全部确认弹窗
  Future<void> _confirmDeleteAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空记忆'),
        content: const Text('将删除全部记忆，AI 会彻底忘记这些内容。确定清空吗？'),
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
              Haptics.heavy();
              Navigator.pop(context, true);
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<MemoryProvider>().deleteAll();
    if (mounted) {
      showAppToast(context, '已清空');
    }
  }
}

/// 添加/编辑记忆弹窗的返回值（内容 + 标签）
class _MemoryFormResult {
  const _MemoryFormResult({required this.content, this.tag});
  final String content;
  final String? tag;
}

/// 添加/编辑记忆弹窗：独立 StatefulWidget，控制器随弹窗销毁，
/// 避免退出动画期间外部提前 dispose 导致 "used after being disposed"
class _MemoryFormDialog extends StatefulWidget {
  const _MemoryFormDialog({
    this.initialContent,
    this.initialTag,
    this.title = '添加记忆',
  });

  final String? initialContent;
  final String? initialTag;
  final String title;

  @override
  State<_MemoryFormDialog> createState() => _MemoryFormDialogState();
}

class _MemoryFormDialogState extends State<_MemoryFormDialog> {
  late final _controller =
      TextEditingController(text: widget.initialContent ?? '');
  late final _tagController =
      TextEditingController(text: widget.initialTag ?? '');

  @override
  void dispose() {
    _controller.dispose();
    _tagController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              hintText: '例如：用户喜欢简洁回答',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tagController,
            decoration: const InputDecoration(
              labelText: '分类标签（可选）',
              hintText: '偏好 / 背景 / 习惯 / 其他',
              isDense: true,
            ),
          ),
        ],
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
            final tag = _tagController.text.trim();
            Navigator.pop(
              context,
              _MemoryFormResult(
                content: _controller.text,
                tag: tag.isEmpty ? null : tag,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
