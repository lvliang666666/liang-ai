import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models/card.dart' as card_model;
import '../services/card_image_service.dart';
import '../utils/haptics.dart';
import '../utils/transitions.dart';
import '../widgets/app_toast.dart';
import '../widgets/code_block_widget.dart';

/// 卡片详情页（打磨批次 W2）：点开真的是一张卡片
///
/// 用户反馈：卡片库点开之后，展示的应该是一张真正的卡片，并且能
/// 直接把这张卡片以图片形式分享出去。整页替代原详情 Sheet：
/// - 卡片视觉：圆角容器 + 阴影 + 标题/标签/正文分区，像一张实体卡
/// - 正文 GptMarkdown 渲染（代码块高亮 + 复制按钮，与聊天页同款）
/// - AppBar「分享」按钮：卡片本体（RepaintBoundary 包裹）渲染成
///   PNG 图片走系统分享面板——所见即所得，QQ/微信收到的就是一张
///   卡片图，不是一段文本
class CardDetailPage extends StatefulWidget {
  const CardDetailPage({super.key, required this.card});

  final card_model.Card card;

  /// 打开卡片详情页（统一入口，slideUpRoute 转场）
  static void open(BuildContext context, card_model.Card card) {
    Navigator.push(context, slideUpRoute(CardDetailPage(card: card)));
  }

  @override
  State<CardDetailPage> createState() => _CardDetailPageState();
}

class _CardDetailPageState extends State<CardDetailPage> {
  /// 卡片本体截图锚点（分享时取 RenderRepaintBoundary 渲染 PNG）
  final _cardBoundaryKey = GlobalKey();

  bool _sharing = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('卡片详情'),
        actions: [
          IconButton(
            tooltip: '分享卡片',
            icon: _sharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            onPressed: _sharing ? null : () => _share(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: RepaintBoundary(
          key: _cardBoundaryKey,
          child: CardClip(card: widget.card, theme: theme),
        ),
      ),
    );
  }

  Future<void> _share(BuildContext context) async {
    Haptics.medium();
    setState(() => _sharing = true);
    final ok = await CardImageService.shareCardImage(
      _cardBoundaryKey,
      widget.card,
    );
    if (!mounted) return;
    setState(() => _sharing = false);
    if (ok == null) {
      showAppToast(context, '已取消分享');
    } else if (ok) {
      showAppToast(context, '卡片图片已生成，去分享吧');
    } else {
      showAppToast(context, '分享失败，请重试');
    }
  }
}

/// 卡片本体（真卡片视觉）——独立组件供截图复用
///
/// 详情页把它包在 RepaintBoundary 里；截图服务直接取该 boundary
/// 渲染，所见即所得。不依赖 Scaffold 环境，只依赖传入的 [theme]。
class CardClip extends StatelessWidget {
  const CardClip({
    super.key,
    required this.card,
    required this.theme,
  });

  final card_model.Card card;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final tagList = card.tagList;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 卡头：品牌色条 + 标题 + 标签
            Container(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.style_outlined,
                          size: 18,
                          color: theme.colorScheme.onPrimaryContainer),
                      const SizedBox(width: 6),
                      Text(
                        'Liang AI 知识卡片',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    card.title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      height: 1.3,
                    ),
                  ),
                  if (tagList.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final tag in tagList)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              tag,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // 卡身：Markdown 正文
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: card.content.isEmpty
                  ? Text(
                      '（无正文）',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    )
                  : GptMarkdown(
                      card.content,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(height: 1.6),
                      codeBuilder: (context, name, code, closed) =>
                          CodeBlockWidget(code: code, language: name),
                    ),
            ),
            // 卡脚：沉淀时间
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text(
                _footnote(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _footnote() {
    final t = DateTime.fromMillisecondsSinceEpoch(card.updatedAt);
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '沉淀于 $y-$m-$d';
  }
}
