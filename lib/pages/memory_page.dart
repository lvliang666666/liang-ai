import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/memory_provider.dart';
import '../utils/haptics.dart';

/// 记忆管理页：查看/搜索/删除/手动添加 AI 长期记忆
///
/// 记忆为全局共享池（所有 Skill 共用），跨会话生效。
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _query = '';
  bool _loadRequested = false;

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
      return Scaffold(
        appBar: AppBar(title: const Text('记忆管理')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 搜索过滤（不区分大小写）
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? provider.memories
        : provider.memories
            .where((m) =>
                m.content.toLowerCase().contains(query) ||
                (m.tag?.toLowerCase().contains(query) ?? false))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆管理'),
        actions: [
          if (provider.memories.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空全部',
              onPressed: () {
                Haptics.medium();
                _unfocus();
                _confirmDeleteAll(context);
              },
            ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '手动添加',
            onPressed: () {
              Haptics.light();
              _unfocus();
              _showAddDialog(context);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
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
                      ...filtered.map((m) => Card(
                            elevation: 0,
                            color: theme
                                .colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            child: ListTile(
                              title: Text(m.content),
                              subtitle: (m.tag != null || m.sourceSkill != null)
                                  ? Text(
                                      [
                                        if (m.tag != null) m.tag!,
                                        if (m.sourceSkill != null)
                                          '来自 ${m.sourceSkill}',
                                      ].join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : null,
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 20),
                                tooltip: '删除',
                                onPressed: () {
                                  Haptics.medium();
                                  _unfocus();
                                  provider.delete(m.id);
                                },
                              ),
                            ),
                          )),
                      const SizedBox(height: 8),
                      Text(
                        '· 记忆全局共享：所有 Skill 的对话都会注入最近 20 条\n'
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
      ),
    );
  }

  /// 手动添加记忆弹窗
  Future<void> _showAddDialog(BuildContext context) async {
    final content = await showDialog<String>(
      context: context,
      builder: (context) => const _AddMemoryDialog(),
    );

    final trimmed = content?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    await context.read<MemoryProvider>().add(trimmed);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加'), duration: Duration(seconds: 1)),
      );
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
              Haptics.light();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清空'), duration: Duration(seconds: 1)),
      );
    }
  }
}

/// 手动添加记忆弹窗：独立 StatefulWidget，控制器随弹窗销毁，
/// 避免退出动画期间外部提前 dispose 导致 "used after being disposed"
class _AddMemoryDialog extends StatefulWidget {
  const _AddMemoryDialog();

  @override
  State<_AddMemoryDialog> createState() => _AddMemoryDialogState();
}

class _AddMemoryDialogState extends State<_AddMemoryDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加记忆'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        minLines: 1,
        decoration: const InputDecoration(
          hintText: '例如：用户喜欢简洁回答',
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
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
            Navigator.pop(context, _controller.text);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
