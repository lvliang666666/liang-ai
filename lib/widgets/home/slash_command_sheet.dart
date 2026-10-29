import 'package:flutter/material.dart';

import '../../models/skill.dart' as skill_model;
import '../../services/settings_service.dart';
import '../../utils/haptics.dart';
import '../app_bottom_sheet.dart';

/// I12 斜杠命令面板：输入「/」唤起，Skill + 自定义短语统一检索
///
/// - Skill 项：点选回调 [onSelectSkill]（宿主负责切换会话 Skill）
/// - 短语项：点选回调 [onSelectPhrase]（宿主负责填入输入框）
/// - 长按短语项删除（[onDeletePhrase] 为空 = 不显示删除入口）
/// - 搜索框按名称/内容过滤（Skill 名 + 短语全文，不区分大小写）
class SlashCommandSheet extends StatefulWidget {
  const SlashCommandSheet({
    super.key,
    required this.skills,
    required this.settings,
    required this.onSelectSkill,
    required this.onSelectPhrase,
    this.onDeletePhrase,
  });

  final List<skill_model.Skill> skills;
  final SettingsService settings;
  final ValueChanged<skill_model.Skill> onSelectSkill;
  final ValueChanged<String> onSelectPhrase;

  /// 删除短语回调（null = 隐藏删除入口）
  final ValueChanged<String>? onDeletePhrase;

  /// 搜索过滤：Skill 按名称/描述，短语按全文（不区分大小写）
  @visibleForTesting
  static (List<skill_model.Skill>, List<String>) filter(
    List<skill_model.Skill> skills,
    List<String> phrases,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return (skills, phrases);
    return (
      [
        for (final s in skills)
          if (s.name.toLowerCase().contains(q) ||
              s.description.toLowerCase().contains(q))
            s,
      ],
      [for (final p in phrases) if (p.toLowerCase().contains(q)) p],
    );
  }

  @override
  State<SlashCommandSheet> createState() => _SlashCommandSheetState();
}

class _SlashCommandSheetState extends State<SlashCommandSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    // ListenableBuilder 订阅 SettingsService：删除短语后条目即时消失
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (skills, phrases) = SlashCommandSheet.filter(
        widget.skills, widget.settings.slashPhrases, _query);
    final empty = skills.isEmpty && phrases.isEmpty;

    return SheetKeyboardInset(
      child: SheetScaffold(
        title: '斜杠命令',
        onClose: () => Navigator.pop(context),
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: false,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索 Skill 或短语',
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
                    _query.isEmpty ? '暂无可用 Skill 或短语' : '没有找到「$_query」',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  // ===== Skill 分组 =====
                  if (skills.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text('Skill',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                    for (final s in skills)
                      ListTile(
                        key: ValueKey('slash-skill-${s.id}'),
                        leading: Text(s.icon,
                            style: const TextStyle(fontSize: 22)),
                        title: Text(s.name),
                        subtitle: s.description.isEmpty
                            ? null
                            : Text(s.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                        trailing:
                            const Icon(Icons.smart_toy_outlined, size: 16),
                        onTap: () {
                          Haptics.selection();
                          widget.onSelectSkill(s);
                        },
                      ),
                  ],
                  // ===== 自定义短语分组 =====
                  if (phrases.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('快捷短语',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ),
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
                ],
              ),
      ),
    );
  }
}
