import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../models/chat_session.dart';
import '../../providers/agent_provider.dart';
import '../../services/database_service.dart';
import '../../utils/haptics.dart';
import '../pressable.dart';

/// 侧滑抽屉：完整会话列表按时间分组（今天 / 7 天内 / 更早）+ 搜索 + 批量管理
///
/// I7 全文搜索：搜索框输入 ≥1 字时除标题过滤外，同时走 FTS5 检索
/// 全部会话的消息正文（防抖 300ms），命中结果以「会话名 + 命中缩略」
/// 列表展示在会话结果上方；点命中项跳转该会话并定位高亮（宿主
/// onOpenMessage 回调）。
class SessionDrawerPanel extends StatefulWidget {
  const SessionDrawerPanel({
    super.key,
    required this.sessions,
    required this.agentsProvider,
    required this.loaded,
    required this.batchMode,
    required this.removingIds,
    required this.onClose,
    required this.onDeleteSelected,
    required this.onOpenChat,
    required this.onOpenMessage,
    required this.onOpenSettings,
    required this.onShowActions,
  });

  final List<ChatSession> sessions;
  final AgentProvider agentsProvider;
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

  /// I7：点全文搜索命中项（宿主负责切会话 + 滚动定位 + 高亮）
  final void Function(ChatMessage hit, String query) onOpenMessage;
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

  // ===== I7 全文搜索（FTS5）=====

  /// 防抖定时器（300ms 内连续输入只发最后一次查询）
  Timer? _debounce;

  /// FTS 命中的消息（按时间倒序，最多 20 条）
  List<ChatMessage> _messageHits = [];

  /// FTS 查询进行中（结果区显示轻量 loading）
  bool _searchingMessages = false;

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

  // ===== E11 ② 会话列表游标分页 =====
  // 全量列表已在内存（个人规模千级会话 ≈ 百 KB 级，DB 游标分页反而
  // 破坏备份全量导出与主页 id 直查两个不变量），分页只裁剪「构建范围」：
  // 常规列表首屏 50 条，底部「加载更多」按步进追加；搜索态不受限
  // （搜索必须命中全部，FTS 消息命中本身有 20 条上限）。
  static const int _pageStep = 50;
  int _displayLimit = _pageStep;

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
    _debounce?.cancel();
    widget.batchMode.removeListener(_onBatchModeChanged);
    _appearController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 搜索框输入：标题过滤即时生效，FTS 正文检索防抖 300ms
  void _onSearchChanged(String v) {
    setState(() {
      _query = v;
      // 搜索态不裁剪（必须命中全部）；回到常规态重置游标
      if (v.trim().isNotEmpty) {
        _displayLimit = _filteredAllCount;
      }
    });
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) {
      setState(() {
        _messageHits = [];
        _searchingMessages = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _searchingMessages = true);
      try {
        // FTS5 不可用的真机（系统 SQLite 无该模块）：ftsOrNull 为 null，
        // searchMessagesLike 全量 LIKE 兜底（功能降级不崩溃）
        final hits = await DatabaseService.instance.ftsOrNull
                ?.searchMessages(q, limit: 20) ??
            await DatabaseService.instance.searchMessagesLike(q, limit: 20);
        if (!mounted) return;
        setState(() {
          _messageHits = hits;
          _searchingMessages = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _searchingMessages = false);
      }
    });
  }

  /// 关闭搜索：清查询 + 清 FTS 结果
  void _closeSearch() {
    _debounce?.cancel();
    setState(() {
      _searching = false;
      _query = '';
      _messageHits = [];
      _searchingMessages = false;
      _displayLimit = _pageStep; // 回常规态重置游标（E11 ②）
      _searchController.clear();
      _searchFocusNode.unfocus();
    });
  }

  /// 命中缩略：截取命中词前后各 ~24 字符，命中词用「」不可行（正文
  /// 可能自带），高亮由 UI 层 TextSpan 处理，这里只裁剪窗口
  String _snippet(ChatMessage hit, String query) {
    final content = hit.content.replaceAll('\n', ' ');
    final idx = content.indexOf(query);
    if (idx < 0) {
      return content.length <= 50 ? content : '${content.substring(0, 50)}…';
    }
    final start = (idx - 24).clamp(0, content.length);
    final end = (idx + query.length + 24).clamp(0, content.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < content.length ? '…' : '';
    return '$prefix${content.substring(start, end)}$suffix';
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

  /// 全量会话数（搜索态展开游标用：搜索必须命中全部）
  int get _filteredAllCount => widget.sessions.length;

  /// 分组展示：置顶组恒在时间分组之上（I7），其余按时间分组
  /// （今天 / 7 天内 / 更早）。置顶会话不再进时间分组。
  ///
  /// E11 ②：常规列表走游标分页——只取 _filtered 前 _displayLimit 条
  /// 参与分组构建（搜索态不裁剪，见 _displayLimit 语义）。
  Map<String, List<ChatSession>> get _grouped {
    final now = DateTime.now();
    final startOfToday =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final sevenDaysAgo = startOfToday - 7 * 24 * 3600 * 1000;
    final groups = <String, List<ChatSession>>{
      '置顶': [],
      '今天': [],
      '7 天内': [],
      '更早': [],
    };
    final source = _searching ? _filtered : _filtered.take(_displayLimit);
    for (final s in source) {
      if (s.pinned) {
        groups['置顶']!.add(s);
      } else if (s.updatedAt >= startOfToday) {
        groups['今天']!.add(s);
      } else if (s.updatedAt >= sevenDaysAgo) {
        groups['7 天内']!.add(s);
      } else {
        groups['更早']!.add(s);
      }
    }
    return groups;
  }

  /// 常规列表是否还有未展示的会话（「加载更多」入口显隐）
  bool get _hasMore =>
      !_searching && _filtered.length > _displayLimit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = widget.sessions;
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
                    // 搜索历史对话（标题过滤 + FTS 正文全文检索）
                    IconButton(
                      icon: Icon(
                        _searching ? Icons.search_off : Icons.search,
                        size: 22,
                      ),
                      tooltip: _searching ? '关闭搜索' : '搜索会话',
                      onPressed: () {
                        Haptics.light();
                        if (_searching) {
                          _closeSearch();
                        } else {
                          setState(() => _searching = true);
                        }
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
            // 搜索框（点放大镜展开）：标题即时过滤 + 正文 FTS 防抖检索
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索会话与消息',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              setState(() {
                                _query = '';
                                _messageHits = [];
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
            // 会话列表（按时间分组，搜索时按匹配过滤；批量模式多选）。
            // I7：搜索态下 FTS 正文命中结果以独立分组展示在会话结果上方
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
                      : _buildListBody(theme),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }

  /// 列表主体：搜索态 = FTS 命中消息组 + 会话结果组（单 ListView 滚动）；
  /// 常规态 = 时间分组会话列表
  Widget _buildListBody(ThemeData theme) {
    final filteredEmpty = _filtered.isEmpty;
    final searching = _searching && _query.trim().isNotEmpty;

    // 搜索态：消息命中 + 会话命中合并一个滚动视图
    if (searching && !_batchMode) {
      final sessionHits = _filtered;
      if (_searchingMessages && _messageHits.isEmpty) {
        return const Center(
            child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ));
      }
      if (_messageHits.isEmpty && sessionHits.isEmpty) {
        return Center(
          child: Text('没有找到「$_query」',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        );
      }
      // E11 ②：搜索结果同样走 builder 惰性构建（会话命中 + 消息命中
      // 展平为单序列；搜索态不裁剪——必须命中全部）
      final searchRows = <_DrawerRow>[
        if (sessionHits.isNotEmpty) ...[
          _DrawerRow.header('会话'),
          for (final s in sessionHits) _DrawerRow.session(s),
        ],
        if (_messageHits.isNotEmpty) ...[
          _DrawerRow.header('消息内容'),
          for (final hit in _messageHits) _DrawerRow.message(hit),
        ],
      ];
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: searchRows.length,
        itemBuilder: (context, index) {
          final row = searchRows[index];
          if (row.isHeader) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(row.header!,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            );
          }
          if (row.message != null) {
            final hit = row.message!;
            return _MessageHitTile(
              hit: hit,
              sessionTitle: widget.sessions
                      .where((s) => s.id == hit.sessionId)
                      .firstOrNull
                      ?.title ??
                  '已删除的会话',
              query: _query.trim(),
              snippet: _snippet(hit, _query.trim()),
              onTap: () {
                Haptics.light();
                widget.onOpenMessage(hit, _query.trim());
              },
            );
          }
          final s = row.session!;
          return ListTile(
            dense: true,
            leading: Text(
              widget.agentsProvider.byId(s.agentId)?.icon ?? '💬',
              style: const TextStyle(fontSize: 18),
            ),
            title: Text(
              s.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            trailing: s.pinned
                ? Icon(Icons.push_pin,
                    size: 14, color: theme.colorScheme.primary)
                : null,
            onTap: () {
              Haptics.light();
              widget.onOpenChat(s.id);
            },
          );
        },
      );
    }

    // 常规态：原时间分组列表（含批量模式）
    if (filteredEmpty) {
      return Center(
        child: Text(_batchMode ? '没有可管理的会话' : '没有找到「$_query」',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    // E11 ②：ListView.builder 惰性构建（只构建可见子树）+ 游标分页
    // （_grouped 已按 _displayLimit 裁剪，末尾挂「加载更多」行）
    final grouped = _grouped;
    // 展平为 (groupHeader?, session) 序列：偶数位可能是分组标题
    final rows = <_DrawerRow>[];
    for (final entry in grouped.entries) {
      if (entry.value.isEmpty) continue;
      rows.add(_DrawerRow.header(entry.key));
      for (final s in entry.value) {
        rows.add(_DrawerRow.session(s));
      }
    }
    final totalRows = rows.length + (_hasMore ? 1 : 0);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: totalRows,
      itemBuilder: (context, index) {
        if (index >= rows.length) {
          return _buildLoadMoreTile(theme);
        }
        final row = rows[index];
        if (row.isHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(row.header!,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          );
        }
        return _buildSessionTile(theme, row.session!);
      },
    );
  }

  /// 「加载更多」行：追加一个步进页并重建（E11 ②）
  Widget _buildLoadMoreTile(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: TextButton.icon(
          onPressed: () {
            Haptics.light();
            setState(() => _displayLimit += _pageStep);
          },
          icon: const Icon(Icons.expand_more, size: 18),
          label: Text('加载更多',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
        ),
      ),
    );
  }

  /// 单条会话 tile（离场动画 + 长按锚点菜单 + 批量多选，E11 ② 抽出复用）
  Widget _buildSessionTile(ThemeData theme, ChatSession s) {
    // 离场动画：删除确认后卡片收缩淡出（200ms），动画完宿主
    // 才真删，其余卡片随列表重建平滑上移补位
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      opacity: widget.removingIds.contains(s.id) ? 0.0 : 1.0,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          scale: widget.removingIds.contains(s.id) ? 0.9 : 1.0,
          // GestureDetector 包 ListTile：ListTile 无
          // onLongPressStart，外包一层拿长按点全局坐标（锚点菜单用）
          child: PressableScale(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onLongPressStart: _batchMode
                  ? null
                  : (details) => widget.onShowActions(
                      context, s.id, s.title, details.globalPosition),
              child: ListTile(
                key: ValueKey('session-tile-${s.id}'),
                dense: true,
                leading: _batchMode
                    ? Icon(
                        _selectedIds.contains(s.id)
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 22,
                        color: _selectedIds.contains(s.id)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      )
                    : Text(
                        widget.agentsProvider.byId(s.agentId)?.icon ?? '💬',
                        style: const TextStyle(fontSize: 18),
                      ),
                title: Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                // 置顶标记（I7）：图钉小图标
                trailing: s.pinned
                    ? Icon(Icons.push_pin,
                        size: 14, color: theme.colorScheme.primary)
                    : null,
                onTap: () {
                  if (_batchMode) {
                    Haptics.selection();
                    setState(() {
                      if (_selectedIds.contains(s.id)) {
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
    );
  }
}

/// E11 ②：抽屉列表展平行——分组标题 / 会话条目 / FTS 消息命中
class _DrawerRow {
  const _DrawerRow._(this.header, this.session, this.message);

  final String? header;
  final ChatSession? session;
  final ChatMessage? message;

  bool get isHeader => header != null;

  factory _DrawerRow.header(String text) => _DrawerRow._(text, null, null);
  factory _DrawerRow.session(ChatSession s) => _DrawerRow._(null, s, null);
  factory _DrawerRow.message(ChatMessage m) => _DrawerRow._(null, null, m);
}

/// I7：FTS 命中消息条目——会话名 + 命中缩略（命中词高亮）
class _MessageHitTile extends StatelessWidget {
  const _MessageHitTile({
    required this.hit,
    required this.sessionTitle,
    required this.query,
    required this.snippet,
    required this.onTap,
  });

  final ChatMessage hit;
  final String sessionTitle;
  final String query;
  final String snippet;
  final VoidCallback onTap;

  /// 缩略文本按命中词切段，命中段上色加粗（TextSpan 高亮）
  List<TextSpan> _buildSpans(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall!;
    final highlightStyle = base.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = snippet.indexOf(query, start);
      if (idx < 0) {
        spans.add(TextSpan(text: snippet.substring(start), style: base));
        break;
      }
      if (idx > start) {
        spans.add(
            TextSpan(text: snippet.substring(start, idx), style: base));
      }
      spans.add(TextSpan(
          text: snippet.substring(idx, idx + query.length),
          style: highlightStyle));
      start = idx + query.length;
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: Icon(Icons.chat_bubble_outline,
          size: 18, color: theme.colorScheme.onSurfaceVariant),
      title: Text(
        sessionTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text.rich(
          TextSpan(children: _buildSpans(context)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      onTap: onTap,
    );
  }
}
