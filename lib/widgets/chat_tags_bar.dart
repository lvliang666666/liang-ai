import 'package:flutter/material.dart';

/// 聊天输入框上方的 tags 行：agent / model 等横向滚动胶囊标签。
///
/// DeepSeek 式——切换人格/模型的入口从 AppBar 移到这里，
/// 每个 tag 显示当前选中值，点击触发外部传入的回调（弹选择器）。
/// 选中值变化时文字淡出下移/淡入上移过渡（AnimatedSwitcher）。
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
            onLongPress: tag.onLongPress,
            borderRadius: BorderRadius.circular(18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // emoji 图标（具体 agent 的 icon）优先于内置 IconData
                  if (tag.emoji != null) ...[
                    Text(tag.emoji!, style: const TextStyle(fontSize: 14)),
                    const SizedBox(width: 4),
                  ] else if (tag.icon != null) ...[
                    Icon(tag.icon,
                        size: 15, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                  ],
                  // 选中值变化：旧文字淡出下移、新文字淡入上移
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.5),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        ...previousChildren,
                        ?currentChild,
                      ],
                    ),
                    child: Text(
                      tag.label,
                      // key 绑定文字内容：label 变化才触发过渡
                      key: ValueKey(tag.label),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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
  const ChatTag({
    this.icon,
    this.emoji,
    required this.label,
    required this.onTap,
    this.onLongPress,
  });

  /// 内置图标（无 emoji 时使用）
  final IconData? icon;

  /// emoji 图标（具体 agent 的 icon，优先于 [icon]）
  final String? emoji;
  final String label;
  final VoidCallback onTap;

  /// 长按回调（F10：agent tag 长按 = 重开变量/预设配置表单；null = 无）
  final VoidCallback? onLongPress;
}
