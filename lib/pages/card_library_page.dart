import 'package:flutter/material.dart';

// Card 与 Material 的 Card 组件重名：模型走前缀（KnowledgeCard 语义别名）
import '../models/card.dart' as card_model;
import '../services/database_service.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';

/// M5 卡片库：用户策展的知识卡片管理页
///
/// 嵌入设置页 PageView 作为独立 tag（与 MemoryPanel 同模式，无自带
/// Scaffold）：搜索 + 卡片列表 + 编辑/删除。
/// 卡片是用户资产（不参与淘汰），删除有确认弹窗防误删。
class CardLibraryPanel extends StatefulWidget {
  const CardLibraryPanel({super.key});

  @override
  State<CardLibraryPanel> createState() => _CardLibraryPanelState();
}

class _CardLibraryPanelState extends State<CardLibraryPanel> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _query = '';

  /// 全量卡片（页内过滤，无 Provider——卡片低频访问，不值得常驻订阅）
  List<card_model.Card> _cards = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final cards = await DatabaseService.instance.getAllCards();
    if (!mounted) return;
    setState(() {
      _cards = cards;
      _loading = false;
    });
  }

  void _unfocus() {
    if (_searchFocusNode.hasFocus) _searchFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _cards
        : _cards
            .where((c) =>
                c.title.toLowerCase().contains(query) ||
                c.content.toLowerCase().contains(query) ||
                (c.tags?.toLowerCase().contains(query) ?? false))
            .toList();

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // 搜索框 + 清空按钮（与记忆管理 tab 同布局）
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
                    hintText: '搜索标题 / 正文 / 标签',
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
                        const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              if (_cards.isNotEmpty)
                IconButton(
                  tooltip: '清空卡片',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _confirmDeleteAll,
                ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? _emptyView(theme, query.isNotEmpty)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) =>
                      _cardItem(theme, filtered[index]),
                ),
        ),
      ],
    );
  }

  Widget _emptyView(ThemeData theme, bool searched) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.style_outlined,
              size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            searched ? '没有匹配的卡片' : '还没有卡片',
            style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
          if (!searched) ...[
            const SizedBox(height: 6),
            Text(
              '聊天中长按消息 → 「沉淀为卡片」',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline),
            ),
          ],
        ],
      ),
    );
  }

  /// 单张卡片：标题 + 正文预览 + 标签行 + 编辑/删除
  Widget _cardItem(ThemeData theme, card_model.Card card) {
    final tagList = card.tagList;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    card.title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: '编辑',
                  onPressed: () {
                    Haptics.light();
                    _unfocus();
                    _showEditDialog(card);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '删除',
                  onPressed: () {
                    Haptics.medium();
                    _unfocus();
                    _confirmDelete(card);
                  },
                ),
              ],
            ),
            if (card.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  card.content,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (tagList.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in tagList)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          tag,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 编辑卡片弹窗（标题 + 正文 + 标签）
  Future<void> _showEditDialog(card_model.Card card) async {
    final result = await showDialog<_CardFormResult>(
      context: context,
      builder: (context) => _CardFormDialog(
        initialTitle: card.title,
        initialContent: card.content,
        initialTags: card.tags,
      ),
    );
    if (result == null || !mounted) return;
    final title = result.title.trim();
    await DatabaseService.instance.updateCard(card.copyWith(
      title: title,
      content: result.content.trim(),
      tags: result.tags,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await _reload();
    if (mounted) showAppToast(context, '已更新');
  }

  /// 删除单张卡片确认
  Future<void> _confirmDelete(card_model.Card card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除卡片'),
        content: Text('「${card.title}」将被删除，确定吗？'),
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
    if (confirmed != true || !mounted) return;
    await DatabaseService.instance.deleteCard(card.id);
    await _reload();
    if (mounted) showAppToast(context, '已删除');
  }

  /// 清空全部卡片确认
  Future<void> _confirmDeleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空卡片'),
        content: Text('将删除全部 ${_cards.length} 张卡片，确定清空吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DatabaseService.instance.deleteAllCards();
    await _reload();
    if (mounted) showAppToast(context, '已清空');
  }
}

/// 编辑卡片弹窗的返回值（标题 + 正文 + 标签）
class _CardFormResult {
  const _CardFormResult({
    required this.title,
    required this.content,
    this.tags,
  });
  final String title;
  final String content;
  final String? tags;
}

/// 编辑卡片弹窗：独立 StatefulWidget，控制器随弹窗销毁，
/// 避免退出动画期间外部提前 dispose 导致 "used after being disposed"
class _CardFormDialog extends StatefulWidget {
  const _CardFormDialog({
    required this.initialTitle,
    required this.initialContent,
    this.initialTags,
  });

  final String initialTitle;
  final String initialContent;
  final String? initialTags;

  @override
  State<_CardFormDialog> createState() => _CardFormDialogState();
}

class _CardFormDialogState extends State<_CardFormDialog> {
  late final _titleController =
      TextEditingController(text: widget.initialTitle);
  late final _contentController =
      TextEditingController(text: widget.initialContent);
  late final _tagsController =
      TextEditingController(text: widget.initialTags ?? '');

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑卡片'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '标题',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentController,
              maxLines: 6,
              minLines: 3,
              decoration: const InputDecoration(
                labelText: '正文',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tagsController,
              decoration: const InputDecoration(
                labelText: '标签（逗号分隔，可选）',
                hintText: '财务, 编程',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            // 空标题就地拦截：弹窗不关闭，用户可直接补标题再存
            if (_titleController.text.trim().isEmpty) {
              showAppToast(context, '标题不能为空');
              return;
            }
            Navigator.pop(
              context,
              _CardFormResult(
                title: _titleController.text,
                content: _contentController.text,
                tags: _tagsController.text.trim().isEmpty
                    ? null
                    : _tagsController.text
                        .split(',')
                        .map((t) => t.trim())
                        .where((t) => t.isNotEmpty)
                        .join(','),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
