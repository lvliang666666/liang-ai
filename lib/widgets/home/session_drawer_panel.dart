import 'package:flutter/material.dart';

import '../../models/chat_session.dart';
import '../../providers/skill_provider.dart';
import '../../utils/haptics.dart';
import '../pressable.dart';

/// 侧滑抽屉：完整会话列表按时间分组（今天 / 7 天内 / 更早）+ 搜索 + 批量管理
class SessionDrawerPanel extends StatefulWidget {
  const SessionDrawerPanel({
    super.key,
    required this.sessions,
    required this.skillsProvider,
    required this.loaded,
    required this.batchMode,
    required this.removingIds,
    required this.onClose,
    required this.onDeleteSelected,
    required this.onOpenChat,
    required this.onOpenSettings,
    required this.onShowActions,
  });

  final List<ChatSession> sessions;
  final SkillProvider skillsProvider;
  final bool loaded;

  /// 批量管理模式开关（主页长按菜单触发进入）
  final ValueNotifier<bool> batchMode;

  /// 正在播离场动画的会话 id（卡片收缩淡出中，动画完由宿主真删）
  final Set<String> removingIds;

  /// 关闭抽屉（打开会话/设置前调用）
  final VoidCallback onClose;

  /// 批量删除选中的会话
  final Future<void> Function(List<String> ids) onDeleteSelected;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onOpenSettings;
  final void Function(
      BuildContext, String, String, Offset pressPosition) onShowActions;

  @override
  State<SessionDrawerPanel> createState() => _SessionDrawerPanelState();
}

class _SessionDrawerPanelState extends State<SessionDrawerPanel>
    with SingleTickerProviderStateMixin {
  bool _searching = false;
  String _query = '';
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  /// 抽屉内容入场动画：整体淡入 + 轻微右滑（每次打开抽屉重播）
  late final AnimationController _appearController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _appear = CurvedAnimation(
    parent: _appearController,
    curve: Curves.easeOutCubic,
  );

  // 批量管理模式状态
  bool _batchMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    // 抽屉内容随 DrawerController 打开动画交错入场
    _appearController.forward();
    // 主页长按菜单「批量管理」→ 进入多选模式
    widget.batchMode.addListener(_onBatchModeChanged);
  }

  @override
  void didUpdateWidget(covariant SessionDrawerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.batchMode != widget.batchMode) {
      oldWidget.batchMode.removeListener(_onBatchModeChanged);
      widget.batchMode.addListener(_onBatchModeChanged);
    }
  }

  void _onBatchModeChanged() {
    if (!mounted) return;
    setState(() {
      _batchMode = widget.batchMode.value;
      if (_batchMode) {
        _searching = false; // 批量模式与搜索互斥
        _selectedIds.clear();
      }
    });
  }

  @override
  void dispose() {
    widget.batchMode.removeListener(_onBatchModeChanged);
    _appearController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 退出批量模式
  void _exitBatchMode() {
    setState(() {
      _batchMode = false;
      _selectedIds.clear();
    });
    widget.batchMode.value = false;
  }

  /// 批量删除确认 + 执行
  Future<void> _confirmBatchDelete() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定删除选中的 ${_selectedIds.length} 个会话吗？删除后无法恢复。'),
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
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onDeleteSelected(_selectedIds.toList());
    if (!mounted) return;
    _exitBatchMode();
  }

  /// 过滤后的会话（搜索时按标题匹配）
  List<ChatSession> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.sessions;
    return widget.sessions
        .where((s) => s.title.toLowerCase().contains(q))
        .toList();
  }

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
    for (final s in _filtered) {
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
    final sessions = widget.sessions;
    final filteredEmpty = _filtered.isEmpty;
    final allFilteredIds = _filtered.map((s) => s.id).toSet();
    final allSelected =
        allFilteredIds.isNotEmpty && allFilteredIds.every(_selectedIds.contains);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: FadeTransition(
          opacity: _appear,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.02, 0),
              end: Offset.zero,
            ).animate(_appear),
            child: Column(
          children: [
            // 抽屉头部：批量模式操作栏 / 常规 Logo + 搜索 + 设置
            if (_batchMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '退出批量管理',
                      onPressed: () {
                        Haptics.light();
                        _exitBatchMode();
                      },
                    ),
                    Expanded(
                      child: Text(
                        '已选 ${_selectedIds.length} 项',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    // 全选/取消全选
                    IconButton(
                      icon: Icon(
                        allSelected
                            ? Icons.deselect
                            : Icons.select_all,
                        size: 22,
                      ),
                      tooltip: allSelected ? '取消全选' : '全选',
                      onPressed: () {
                        Haptics.light();
                        setState(() {
                          if (allSelected) {
                            _selectedIds.removeAll(allFilteredIds);
                          } else {
                            _selectedIds.addAll(allFilteredIds);
                          }
                        });
                      },
                    ),
                    // 批量删除
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 22,
                        color: _selectedIds.isEmpty
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                      tooltip: '删除选中',
                      onPressed:
                          _selectedIds.isEmpty ? null : _confirmBatchDelete,
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Row(
                  children: [
                    Text('Liang AI',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    // 搜索历史对话
                    IconButton(
                      icon: Icon(
                        _searching ? Icons.search_off : Icons.search,
                        size: 22,
                      ),
                      tooltip: _searching ? '关闭搜索' : '搜索会话',
                      onPressed: () {
                        Haptics.light();
                        setState(() {
                          _searching = !_searching;
                          if (!_searching) {
                            _query = '';
                            _searchController.clear();
                            _searchFocusNode.unfocus();
                          }
                        });
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined, size: 22),
                      tooltip: '设置',
                      onPressed: widget.onOpenSettings,
                    ),
                  ],
                ),
              ),
            // 搜索框（点放大镜展开）
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索会话标题',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              setState(() {
                                _query = '';
                                _searchController.clear();
                              });
                            },
                          ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
            const Divider(height: 1),
            // 会话列表（按时间分组，搜索时按匹配过滤；批量模式多选）
            Expanded(
              child: !widget.loaded
                  ? const Center(child: CircularProgressIndicator())
                  : sessions.isEmpty
                      ? Center(
                          child: Text('暂无会话',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color:
                                      theme.colorScheme.onSurfaceVariant)),
                        )
                      : filteredEmpty
                          ? Center(
                              child: Text(
                                  _batchMode ? '没有可管理的会话' : '没有找到「$_query」',
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant)),
                            )
                          : ListView(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
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
                                      // 离场动画：删除确认后卡片收缩淡出
                                      //（200ms），动画完宿主才真删，其余
                                      // 卡片随列表重建平滑上移补位
                                      AnimatedOpacity(
                                        duration: const Duration(
                                            milliseconds: 200),
                                        curve: Curves.easeOutCubic,
                                        opacity: widget.removingIds
                                                .contains(s.id)
                                            ? 0.0
                                            : 1.0,
                                        child: AnimatedSize(
                                          duration: const Duration(
                                              milliseconds: 200),
                                          curve: Curves.easeOutCubic,
                                          alignment: Alignment.topCenter,
                                          child: AnimatedScale(
                                            duration: const Duration(
                                                milliseconds: 200),
                                            curve: Curves.easeOutCubic,
                                            scale: widget.removingIds
                                                    .contains(s.id)
                                                ? 0.9
                                                : 1.0,
                                            // GestureDetector 包 ListTile：
                                            // ListTile 无 onLongPressStart，
                                            // 外包一层拿长按点全局坐标（锚点菜单用）
                                            child: PressableScale(
                                              child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onLongPressStart: _batchMode
                                            ? null
                                            : (details) => widget.onShowActions(
                                                context,
                                                s.id,
                                                s.title,
                                                details.globalPosition),
                                        child: ListTile(
                                          dense: true,
                                          leading: _batchMode
                                              ? Icon(
                                                  _selectedIds.contains(s.id)
                                                      ? Icons.check_circle
                                                      : Icons
                                                          .radio_button_unchecked,
                                                  size: 22,
                                                  color: _selectedIds
                                                          .contains(s.id)
                                                      ? theme
                                                          .colorScheme.primary
                                                      : theme.colorScheme
                                                          .onSurfaceVariant,
                                                )
                                              : Text(
                                                  widget.skillsProvider
                                                          .byId(s.skillId)
                                                          ?.icon ??
                                                      '💬',
                                                  style: const TextStyle(
                                                      fontSize: 18),
                                                ),
                                          title: Text(
                                            s.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                          onTap: () {
                                            if (_batchMode) {
                                              Haptics.selection();
                                              setState(() {
                                                if (_selectedIds
                                                    .contains(s.id)) {
                                                  _selectedIds.remove(s.id);
                                                } else {
                                                  _selectedIds.add(s.id);
                                                }
                                              });
                                            } else {
                                              widget.onOpenChat(s.id);
                                            }
                                          },
                                        ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                              ],
                            ),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}
