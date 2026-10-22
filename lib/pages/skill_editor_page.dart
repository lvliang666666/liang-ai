import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/skill.dart';
import '../providers/skill_provider.dart';
import '../services/tools/builtin_tools.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';
import '../widgets/tag_bar.dart';

/// Skill 新建/编辑整页（复用设置页 TagBar + PageView 布局）
///
/// 分区：基本信息（图标/名称/描述/档位）/ 提示词 / 可用工具。
/// 内置 Skill 只读查看（字段禁用、无保存按钮）。
///
/// 工具子集编辑：toolNames null 视为「全部勾选」；保存时写显式列表。
class SkillEditorPage extends StatefulWidget {
  const SkillEditorPage({super.key, this.skill});

  /// null = 新建；非 null = 编辑（内置则只读查看）
  final Skill? skill;

  @override
  State<SkillEditorPage> createState() => _SkillEditorPageState();
}

class _SkillEditorPageState extends State<SkillEditorPage> {
  static const _tabs = ['基本信息', '提示词', '可用工具'];

  late final bool _isBuiltin;
  late final TextEditingController _iconCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _promptCtrl;
  String? _effort;
  // 工具勾选状态：key = 工具名
  late final Map<String, bool> _toolChecked;

  late final PageController _pageController;
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    final skill = widget.skill;
    _isBuiltin = skill?.isBuiltin ?? false;
    _iconCtrl = TextEditingController(text: skill?.icon ?? '🤖');
    _nameCtrl = TextEditingController(text: skill?.name ?? '');
    _descCtrl = TextEditingController(text: skill?.description ?? '');
    _promptCtrl = TextEditingController(text: skill?.prompt ?? '');
    _effort = skill?.effort;
    // 工具勾选初始值：null（全部）展开为全部工具名
    final declaredTools = skill?.toolNames;
    _toolChecked = {
      for (final t in builtinTools)
        t.name: declaredTools == null || declaredTools.contains(t.name),
    };
    _pageController = PageController();
  }

  @override
  void dispose() {
    _iconCtrl.dispose();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _promptCtrl.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _goToTab(int index) {
    if (index == _currentTab) return;
    Haptics.selection();
    // 切页收起焦点：PageView 页面保活，焦点残留会导致键盘自动弹出
    FocusManager.instance.primaryFocus?.unfocus();
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final prompt = _promptCtrl.text.trim();

    // 校验失败：提示 + 自动跳到出错分区
    if (name.isEmpty) {
      _goToTab(0);
      showAppToast(context, '名称不能为空');
      return;
    }
    if (prompt.isEmpty) {
      _goToTab(1);
      showAppToast(context, '提示词不能为空');
      return;
    }

    // 勾选结果转 toolNames：全勾 = null（全部，语义等价且便于后续加新工具）
    final checkedNames = [
      for (final t in builtinTools)
        if (_toolChecked[t.name] == true) t.name,
    ];
    final toolNames =
        checkedNames.length == builtinTools.length ? null : checkedNames;

    final provider = context.read<SkillProvider>();
    final original = widget.skill;
    if (original == null) {
      await provider.create(
        name: name,
        prompt: prompt,
        icon: _iconCtrl.text.trim().isEmpty ? '🤖' : _iconCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        effort: _effort,
        toolNames: toolNames,
      );
    } else {
      await provider.update(Skill(
        id: original.id,
        name: name,
        icon: _iconCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        prompt: prompt,
        temperature: original.temperature,
        effort: _effort,
        toolNames: toolNames,
      ));
    }

    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.skill == null
            ? '新建 Skill'
            : (_isBuiltin ? '查看 Skill' : '编辑 Skill')),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, false);
            },
            child: const Text('取消'),
          ),
          if (!_isBuiltin)
            FilledButton(
              onPressed: () {
                Haptics.light();
                _save();
              },
              child: const Text('保存'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // ===== 顶部 Tags 栏（可横向滑动） =====
          TagBar(
            tabs: _tabs,
            current: _currentTab,
            onTap: _goToTab,
          ),
          // ===== 分区内容 =====
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) {
                Haptics.selection();
                // 滑动切页同样收起焦点，避免键盘残留
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => _currentTab = index);
              },
              children: [
                _buildBasicTab(theme),
                _buildPromptTab(theme),
                _buildToolsTab(theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== Tag 1：基本信息 =====
  Widget _buildBasicTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Row(children: [
          SizedBox(
            width: 64,
            child: TextField(
              controller: _iconCtrl,
              enabled: !_isBuiltin,
              textAlign: TextAlign.center,
              maxLength: 2,
              decoration: const InputDecoration(
                  counterText: '', labelText: '图标'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _nameCtrl,
              enabled: !_isBuiltin,
              maxLength: 20,
              decoration: const InputDecoration(
                  labelText: '名称', counterText: ''),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _descCtrl,
          enabled: !_isBuiltin,
          maxLength: 50,
          decoration: const InputDecoration(
              labelText: '一句话描述', counterText: ''),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _effort,
          decoration: const InputDecoration(labelText: '推理档位（可选）'),
          items: const [
            DropdownMenuItem(value: 'max', child: Text('深度（max）')),
            DropdownMenuItem(value: 'high', child: Text('均衡（high）')),
            DropdownMenuItem(value: 'low', child: Text('轻量（low）')),
            DropdownMenuItem(child: Text('不指定')),
          ],
          onChanged: _isBuiltin
              ? null
              : (v) => setState(() => _effort = v),
        ),
      ],
    );
  }

  // ===== Tag 2：提示词 =====
  Widget _buildPromptTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        TextField(
          controller: _promptCtrl,
          enabled: !_isBuiltin,
          maxLines: 14,
          minLines: 10,
          decoration: const InputDecoration(
            labelText: '系统提示词（System Prompt）',
            alignLabelWithHint: true,
            hintText: '定义这个 Skill 的身份、语气、行为准则…',
          ),
        ),
      ],
    );
  }

  // ===== Tag 3：可用工具 =====
  Widget _buildToolsTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Text('可用工具', style: theme.textTheme.titleSmall),
        Text(
          '勾选该 Skill 允许模型调用的工具（全不勾 = 无工具）',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        for (final t in builtinTools)
          CheckboxListTile(
            value: _toolChecked[t.name],
            onChanged: _isBuiltin
                ? null
                : (v) => setState(() => _toolChecked[t.name] = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(t.name,
                style: const TextStyle(
                    fontSize: 13, fontFamily: 'Monocraft')),
            subtitle: Text(
              t.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
