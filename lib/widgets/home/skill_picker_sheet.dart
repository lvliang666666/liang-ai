import 'package:flutter/material.dart';

import '../../providers/skill_provider.dart';
import '../../utils/haptics.dart';
import '../../models/skill.dart' as skill_model;
import '../app_bottom_sheet.dart';

/// Skill 选择弹窗内容：搜索 + 最近使用 + 全部折叠
///
/// [includeDefault] = true 时（主页 agent tag 用）顶部多一个「默认助手」选项，
/// 返回哨兵 Skill（id='__default__'，isBuiltin=true）；回调改为传 Skill 对象。
class SkillPickerSheet extends StatefulWidget {
  const SkillPickerSheet({
    super.key,
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
  State<SkillPickerSheet> createState() => _SkillPickerSheetState();
}

/// 「默认助手」哨兵 Skill（includeDefault 模式下选中返回它）
skill_model.Skill get defaultAssistantSkill => skill_model.Skill(
      id: '__default__',
      name: '默认助手',
      prompt: '',
      isBuiltin: true,
    );

class _SkillPickerSheetState extends State<SkillPickerSheet> {
  String _query = '';
  bool _showAll = false;

  // 键盘适配：内容区滚动控制器（键盘弹出时自动滚到顶部，让搜索框可见）
  final ScrollController _listController = ScrollController();

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

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

    // 键盘适配：键盘弹出时内容区被压缩，自动滚到顶部让搜索框保持可见
    // （搜索框在 SheetScaffold 的固定 header 区，不随列表滚动）
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboardInset > 0 && _listController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_listController.hasClients && _listController.offset > 0) {
          _listController.animateTo(
            0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }

    return SheetKeyboardInset(
      child: SheetScaffold(
        title: '选择 Skill',
        onClose: () => Navigator.pop(context),
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: false,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索 Skill',
              prefixIcon: const Icon(Icons.search, size: 20),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
        child: ListView(
          controller: _listController,
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            // ===== 默认助手（主页 agent tag 模式） =====
            if (widget.includeDefault)
              ListTile(
                leading: const Text('🤖', style: TextStyle(fontSize: 24)),
                title: const Text('默认助手'),
                subtitle: const Text('无人格提示词，全部工具可用'),
                trailing: widget.selectedId == null
                    ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                    : null,
                onTap: () {
                  Haptics.selection();
                  widget.onSelected(defaultAssistantSkill);
                },
              ),
            // ===== 最近使用（搜索时隐藏） =====
            if (q.isEmpty && recent.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text('最近使用',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            children: [
                              Text(a.icon,
                                  style: const TextStyle(fontSize: 28)),
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
                  _showAll ? Icons.expand_less : Icons.expand_more,
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
                    leading:
                        Text(a.icon, style: const TextStyle(fontSize: 24)),
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
                        : (q.isEmpty && recentIdsInFiltered.contains(a.id)
                            ? Icon(Icons.circle,
                                size: 8, color: theme.colorScheme.primary)
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
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              ),
            // 空状态：无任何 Skill 时显示（需求：不出现空白面板）
            if (all.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text('暂无可用 Skill',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
