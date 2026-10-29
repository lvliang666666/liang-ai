import 'package:flutter/material.dart';

import '../../models/provider_profile.dart';
import '../../models/agent.dart' as agent_model;
import '../../providers/provider_provider.dart';
import '../../providers/agent_provider.dart';
import '../../utils/haptics.dart';
import '../app_bottom_sheet.dart';
import 'agent_picker_sheet.dart';

/// 新对话预设弹窗：预选本次对话的 Agent 与模型（力度走 tags 预选，不在此设置）
///
/// 确认返回 (Agent?, (ProviderProfile, String)?)——Agent 为哨兵
/// （id='__default__'）表示默认助手；点遮罩关闭返回 null（不改动预选）。
class NewChatPresetSheet extends StatefulWidget {
  const NewChatPresetSheet({
    super.key,
    required this.agents,
    required this.providers,
    required this.recentIds,
    required this.initialAgent,
    required this.initialModel,
  });

  final AgentProvider agents;
  final ProviderProvider providers;
  final List<String> recentIds;
  final agent_model.Agent? initialAgent;
  final (ProviderProfile, String)? initialModel;

  @override
  State<NewChatPresetSheet> createState() => _NewChatPresetSheetState();
}

class _NewChatPresetSheetState extends State<NewChatPresetSheet> {
  // 非空：初始为哨兵（默认助手），选择器只返回非空 Agent
  late agent_model.Agent _agent = widget.initialAgent ?? defaultAssistantAgent;
  late (ProviderProfile, String)? _model = widget.initialModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final agentLabel = _agent.id == '__default__' ? '默认助手' : _agent.name;
    final modelLabel = _model?.$2 ?? '默认模型';

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('新对话', style: theme.textTheme.titleMedium),
          ),
          // Agent 预选
          ListTile(
            leading: Text(_agent.icon, style: const TextStyle(fontSize: 24)),
            title: const Text('助手'),
            subtitle: Text(agentLabel),
            trailing: const Icon(Icons.keyboard_arrow_down),
            onTap: () async {
              Haptics.light();
              final picked = await showAppBottomSheet<agent_model.Agent?>(
                context: context,
                builder: (context) => AgentPickerSheet(
                  agents: widget.agents,
                  recentIds: widget.recentIds,
                  includeDefault: true,
                  selectedId: _agent.id == '__default__' ? null : _agent.id,
                  onSelected: (s) => Navigator.pop(context, s),
                ),
              );
              if (picked != null) {
                setState(() => _agent = picked);
              }
            },
          ),
          // Model 预选
          ListTile(
            leading: const Icon(Icons.tune, size: 24),
            title: const Text('模型'),
            subtitle: Text(modelLabel),
            trailing: const Icon(Icons.keyboard_arrow_down),
            onTap: () async {
              Haptics.light();
              final picked =
                  await showModalBottomSheet<(ProviderProfile, String)>(
                context: context,
                isScrollControlled: true,
                shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (context) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('选择模型',
                            style: theme.textTheme.titleMedium),
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final p in widget.providers.profiles) ...[
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 8, 16, 2),
                                child: Text(
                                  p.name,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                              if (p.defaultModel.isNotEmpty)
                                ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.model_training,
                                      size: 20),
                                  title: Text(p.defaultModel),
                                  trailing: _model?.$2 == p.defaultModel &&
                                          _model?.$1.id == p.id
                                      ? Icon(Icons.check_circle,
                                          color: theme.colorScheme.primary)
                                      : null,
                                  onTap: () => Navigator.pop(
                                      context, (p, p.defaultModel)),
                                ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              );
              if (picked != null) {
                setState(() => _model = picked);
              }
            },
          ),
          // 确认按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Haptics.medium();
                  Navigator.pop(context, (_agent, _model));
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('开始新对话'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
