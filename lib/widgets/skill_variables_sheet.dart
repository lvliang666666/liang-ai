import 'package:flutter/material.dart';

import '../models/agent.dart' as agent_model;
import '../services/skill_variables.dart';
import '../utils/haptics.dart';
import 'app_bottom_sheet.dart';

/// 从 prompt 提取自定义变量（顶层函数，避免 Agent 扩展依赖）
List<String> _extractVars(String prompt) =>
    SkillVariables.extractCustom(prompt);

/// F10 Skill 变量填写表单 + 人格预设（选 Skill 后弹出）
///
/// - 自定义变量（prompt 里的 `{{x}}`）：每变量一个输入框，预填上次值
/// - 人格预设（front matter personas 声明）：单选 chips，选中即写入
///   persona 变量（预设建立在变量系统上，零特殊路径）
/// - 确认返回变量值 map；点遮罩关闭返回 null（调用方按取消处理）
///
/// 内置变量（date/weekday/time）自动填充，不出现在表单里。
Future<Map<String, String>?> showSkillVariablesSheet(
  BuildContext context, {
  required agent_model.Agent agent,
  Map<String, String> initial = const {},
}) {
  return showAppBottomSheet<Map<String, String>>(
    context: context,
    builder: (context) => SkillVariablesSheet(
      agent: agent,
      initial: initial,
    ),
  );
}

class SkillVariablesSheet extends StatefulWidget {
  const SkillVariablesSheet({
    super.key,
    required this.agent,
    this.initial = const {},
  });

  final agent_model.Agent agent;
  final Map<String, String> initial;

  @override
  State<SkillVariablesSheet> createState() => _SkillVariablesSheetState();
}

class _SkillVariablesSheetState extends State<SkillVariablesSheet> {
  late final List<String> _vars = _extractVars(widget.agent.prompt);
  late final Map<String, TextEditingController> _controllers = {
    for (final v in _vars)
      v: TextEditingController(text: widget.initial[v] ?? ''),
  };

  /// 当前选中的预设名（null = 未选）
  String? _selectedPersona;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final personas = widget.agent.personas;

    // v2.30.3：SheetKeyboardInset 已下沉到 showAppBottomSheet 入口
    // 统一施加，组件内不再手动包裹
    return SheetScaffold(
      title: '配置「${widget.agent.name}」',
      onClose: () => Navigator.pop(context),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
            // ===== 人格预设（声明了才显示） =====
            if (personas.isNotEmpty) ...[
              Text('人格预设', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                '一键切换语气与风格（可随时在聊天页 tags 改）',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in personas)
                    FilterChip(
                      label: Text(p.name),
                      selected: _selectedPersona == p.name,
                      onSelected: (sel) {
                        Haptics.selection();
                        setState(() => _selectedPersona = sel ? p.name : null);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            // ===== 自定义变量表单 =====
            if (_vars.isNotEmpty) ...[
              Text('变量填写', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                '这些值会填进该助手的提示词（本会话内有效）',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              for (final v in _vars) ...[
                TextField(
                  controller: _controllers[v],
                  decoration: InputDecoration(
                    labelText: v,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
            if (_vars.isEmpty && personas.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('该助手没有可配置的变量',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                Haptics.medium();
                final values = <String, String>{
                  for (final e in _controllers.entries) e.key: e.value.text,
                };
                // 人格预设：选中即写入 persona 变量（预设=变量值）
                final persona = personas
                    .where((p) => p.name == _selectedPersona)
                    .firstOrNull;
                if (persona != null) values['persona'] = persona.value;
                Navigator.pop(context, values);
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('开始对话'),
              ),
            ),
          ],
        ),
      );
  }
}
