import 'package:flutter/material.dart';

import '../../services/settings_service.dart';
import '../../utils/haptics.dart';
import '../app_bottom_sheet.dart';

/// I12 斜杠命令面板：输入「/」唤起，快捷短语统一检索
///
/// - 短语项：点选回调 [onSelectPhrase]（宿主负责填入输入框）
/// - 长按短语项删除（[onDeletePhrase] 为空 = 不显示删除入口）
/// - 搜索框按短语全文过滤（不区分大小写）
/// - Agent 切换不进本面板（用户验收决策：输入栏 tag 已有 Agent 入口，
///   面板职责收窄为「短语快捷填入」单一功能）
class SlashCommandSheet extends StatefulWidget {
  const SlashCommandSheet({
    super.key,
    required this.settings,
    required this.onSelectPhrase,
    this.onDeletePhrase,
  });

  final SettingsService settings;
  final ValueChanged<String> onSelectPhrase;

  /// 删除短语回调（null = 隐藏删除入口）
  final ValueChanged<String>? onDeletePhrase;

  /// 搜索过滤：短语按全文（不区分大小写）
  @visibleForTesting
  static List<String> filter(
    List<String> phrases,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return phrases;
    return [for (final p in phrases) if (p.toLowerCase().contains(q)) p];
  }

  @override
  State<SlashCommandSheet> createState() => _SlashCommandSheetState();
}

class _SlashCommandSheetState extends State<SlashCommandSheet>
    with SingleTickerProviderStateMixin {
  String _query = '';

  /// 入场动画：面板骨架由 showModalBottomSheet 滑入，内容再叠加
  /// 淡入+6px 上滑（180ms easeOutCubic）——消除「骨架先到、内容
  /// 瞬间拍上去」的生硬感（用户验收反馈：弹出动画不自然）
  late final AnimationController _enter;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _fade = CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.02),
      end: Offset.zero,
    ).animate(_fade);
    _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ListenableBuilder 订阅 SettingsService：删除短语后条目即时消失
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: _slide,
          child: _buildContent(context),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final phrases = SlashCommandSheet.filter(
        widget.settings.slashPhrases, _query);
    final empty = phrases.isEmpty;

    return SheetKeyboardInset(
      child: SheetScaffold(
        title: '快捷短语',
        onClose: () => Navigator.pop(context),
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: false,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索短语',
              prefixIcon: const Icon(Icons.search, size: 20),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
            ),
          ),
        ),
        child: empty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    _query.isEmpty ? '暂无快捷短语' : '没有找到「$_query」',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  for (final p in phrases)
                    ListTile(
                      key: ValueKey('slash-phrase-$p'),
                      leading: Icon(Icons.bolt,
                          size: 20, color: cs.onSurfaceVariant),
                      title: Text(p, maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      trailing: widget.onDeletePhrase == null
                          ? null
                          : IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.close,
                                  size: 16, color: cs.onSurfaceVariant),
                              tooltip: '删除短语',
                              onPressed: () {
                                Haptics.medium();
                                widget.onDeletePhrase!(p);
                              },
                            ),
                      onTap: () {
                        Haptics.selection();
                        widget.onSelectPhrase(p);
                      },
                    ),
                ],
              ),
      ),
    );
  }
}
