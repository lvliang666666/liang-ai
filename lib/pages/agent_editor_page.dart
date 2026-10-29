import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/agent.dart';
import '../providers/http_tool_provider.dart';
import '../providers/agent_provider.dart';
import '../services/tools/builtin_tools.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';
import '../widgets/tag_bar.dart';

/// Agent 新建/编辑整页（复用设置页 TagBar + PageView 布局）
///
/// 分区：基本信息（图标/名称/描述/档位）/ 提示词 / 可用工具。
/// 内置 Agent 只读查看（字段禁用、无保存按钮）。
///
/// 工具子集编辑：toolNames null 视为「全部勾选」；保存时写显式列表。
class AgentEditorPage extends StatefulWidget {
  const AgentEditorPage({super.key, this.agent});

  /// null = 新建；非 null = 编辑（内置则只读查看）
  final Agent? agent;

  @override
  State<AgentEditorPage> createState() => _AgentEditorPageState();
}

class _AgentEditorPageState extends State<AgentEditorPage> {
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
    final agent = widget.agent;
    _isBuiltin = agent?.isBuiltin ?? false;
    _iconCtrl = TextEditingController(text: agent?.icon ?? '🤖');
    _nameCtrl = TextEditingController(text: agent?.name ?? '');
    _descCtrl = TextEditingController(text: agent?.description ?? '');
    _promptCtrl = TextEditingController(text: agent?.prompt ?? '');
    _effort = agent?.effort;
    // 工具勾选初始值：null（全部）展开为全部工具名（内置 + 自定义 HTTP 工具）
    final declaredTools = agent?.toolNames;
    final allNames = [
      ...builtinTools.map((t) => t.name),
      ...context.read<HttpToolProvider>().enabledTools.map((t) => t.name),
    ];
    _toolChecked = {
      for (final name in allNames)
        name: declaredTools == null || declaredTools.contains(name),
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
    final allNames = [
      ...builtinTools.map((t) => t.name),
      ...context.read<HttpToolProvider>().enabledTools.map((t) => t.name),
    ];
    final checkedNames = [
      for (final name in allNames)
        if (_toolChecked[name] == true) name,
    ];
    final toolNames =
        checkedNames.length == allNames.length ? null : checkedNames;

    final provider = context.read<AgentProvider>();
    final original = widget.agent;
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
      await provider.update(Agent(
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
        title: Text(widget.agent == null
            ? '新建 Agent'
            : (_isBuiltin ? '查看 Agent' : '编辑 Agent')),
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
            hintText: '定义这个 Agent 的身份、语气、行为准则…',
          ),
        ),
      ],
    );
  }

  // ===== Tag 3：可用工具 =====
  Widget _buildToolsTab(ThemeData theme) {
    final httpTools = context.watch<HttpToolProvider>().enabledTools;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Text('可用工具', style: theme.textTheme.titleSmall),
        Text(
          '勾选该 Agent 允许模型调用的工具（全不勾 = 无工具）',
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
        // T1：自定义 HTTP 工具（设置页配置，白名单同样纳管）
        if (httpTools.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('自定义 HTTP 工具', style: theme.textTheme.titleSmall),
          Text(
            '在设置 → HTTP 工具中配置（URL/方法/参数模板）',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          for (final t in httpTools)
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
                t.description.isEmpty ? t.urlTemplate : t.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}
