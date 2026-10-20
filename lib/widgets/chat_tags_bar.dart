import 'package:flutter/material.dart';

/// 聊天输入框上方的 tags 行：agent / model 等横向滚动胶囊标签。
///
/// DeepSeek 式——切换人格/模型的入口从 AppBar 移到这里，
/// 每个 tag 显示当前选中值，点击触发外部传入的回调（弹选择器）。
class ChatTagsBar extends StatelessWidget {
  const ChatTagsBar({super.key, required this.tags});

  /// tag 定义：图标 + 显示文本 + 点击回调
  final List<ChatTag> tags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: tags.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final tag = tags[index];
          return InkWell(
            onTap: tag.onTap,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tag.icon != null) ...[
                    Icon(tag.icon,
                        size: 15, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    tag.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.keyboard_arrow_down,
                      size: 14, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// tags 行的单个标签定义
class ChatTag {
  const ChatTag({this.icon, required this.label, required this.onTap});

  final IconData? icon;
  final String label;
  final VoidCallback onTap;
}
