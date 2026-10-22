import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/provider_profile.dart';
import '../providers/chat_provider.dart';
import '../providers/provider_provider.dart';
import '../utils/haptics.dart';
import 'app_toast.dart';

/// 模型/供应商选择弹窗（共享）：按供应商分组列出 + 自定义模型名输入。
///
/// 选中后调用 [chat].switchProvider 会话级切换；失败（生成中）提示 SnackBar。
Future<void> showModelSwitcher(
  BuildContext context,
  ChatProvider chat,
) async {
  Haptics.light();
  final providersProvider = context.read<ProviderProvider>();
  if (!providersProvider.loaded) await providersProvider.load();
  if (!context.mounted) return;

  // 自定义模型名输入（会话级临时模型）
  final customCtrl = TextEditingController(text: chat.model);
  final selected = await showModalBottomSheet<(ProviderProfile, String)>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child:
                Text('切换模型', style: Theme.of(context).textTheme.titleMedium),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in providersProvider.profiles) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                    child: Text(
                      p.name,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ),
                  if (p.defaultModel.isNotEmpty)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.model_training, size: 20),
                      title: Text(p.defaultModel),
                      trailing: chat.profile.id == p.id &&
                              chat.model == p.defaultModel
                          ? Icon(Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, (p, p.defaultModel)),
                    ),
                ],
                const Divider(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: customCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: '自定义模型名（当前供应商）',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check, size: 20),
                        onPressed: () => Navigator.pop(
                            context, (chat.profile, customCtrl.text.trim())),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;

  final (profile, model) = selected;
  if (model.isEmpty) return;
  final ok = await chat.switchProvider(profile, model);
  if (context.mounted && !ok) {
    showAppToast(context, '生成进行中，无法切换模型');
  }
}
