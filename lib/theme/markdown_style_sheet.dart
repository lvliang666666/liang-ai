import 'dart:math';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Markdown 渲染令牌（主题可覆盖的元素色，全部可空 = 从 scheme 派生）
///
/// 曜石主题传入用户指定色值（obsidian_theme.dart 的 md* 常量）；
/// 其他主题传 null 走 scheme 派生。字段与 GptMarkdownStyleSheet 对应。
class MarkdownTokens {
  const MarkdownTokens({
    this.heading,
    this.tableHeaderBg,
    this.tableHeaderText,
    this.tableCell,
    this.tableBorder,
  });

  /// 章节标题（H1-H6 统一）
  final Color? heading;

  /// 表头底色
  final Color? tableHeaderBg;

  /// 表头文字
  final Color? tableHeaderText;

  /// 单元格文字
  final Color? tableCell;

  /// 表格边框
  final Color? tableBorder;
}

/// Markdown 渲染样式令牌化工厂（2026-11-05 对比度批次）
///
/// 背景：GptMarkdown 默认样式部分不走主题——h1-h6 取 Typography.tall2021
/// （Material 亮色排版，黑色），深色主题下标题深底深字不可读；表格表头
/// 文字未显式给色。本工厂把全部元素颜色从 [ColorScheme] 令牌派生，
/// 经 [GptMarkdownThemeData] 注册进 ThemeData.extensions 后全局生效
/// （消息气泡 + 卡片详情两处 GptMarkdown 自动继承）。
///
/// 对比度契约（WCAG AA ≥4.5:1）：每个派生色对其所在底色的对比度由
/// app_theme_registry_test 的矩阵断言锁死，五主题 × 明暗全覆盖。
/// 链接色若 primary 对气泡底不足 4.5:1，自动回退 onSurface（下划线
/// 语义保留——链接可辨识性靠下划线 + 高对比文字双保险）。
GptMarkdownThemeData markdownThemeData(
  ColorScheme scheme, {
  MarkdownTokens tokens = const MarkdownTokens(),
}) {
  // 气泡底（AI 回复正文所在）：surfaceContainerHighest@45% 叠 surface
  // ——与 message_bubble.dart 的气泡底色公式一致，对比度计算基准
  final bubbleBg = Color.lerp(
    scheme.surfaceContainerHighest,
    scheme.surface,
    0.55,
  )!;
  double contrastOf(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
  }

  // 链接色：primary 达标用 primary，不足回退 onSurface（下划线保语义）
  final linkColor = contrastOf(scheme.primary, bubbleBg) >= 4.5
      ? scheme.primary
      : scheme.onSurface;
  // 标题：优先主题令牌，回退 onSurface（深色主题下即亮白，不再吃
  // Typography.tall2021 的黑）
  final headingColor = tokens.heading ?? scheme.onSurface;
  TextStyle headingStyle(double size) => TextStyle(
        color: headingColor,
        fontSize: size,
        fontWeight: FontWeight.w700,
        height: 1.4,
      );

  final tableBorder = tokens.tableBorder ?? scheme.outline;
  final headerBg = tokens.tableHeaderBg ?? scheme.surfaceContainerHighest;
  final headerText = tokens.tableHeaderText ?? scheme.onSurface;
  final cellColor = tokens.tableCell ?? scheme.onSurface;

  return GptMarkdownThemeData(
    brightness: scheme.brightness,
    h1: headingStyle(24),
    h2: headingStyle(21),
    h3: headingStyle(18),
    h4: headingStyle(16),
    h5: headingStyle(15),
    h6: headingStyle(14),
    styleSheet: GptMarkdownStyleSheet(
      heading: HeadingStyle(
        // 标题文字色显式钉死（styleSheet 层 win over theme per field）
        textStyle: TextStyle(color: headingColor),
      ),
      table: TableStyle(
        borderColor: tableBorder,
        headerBackground: headerBg,
        headerTextStyle: TextStyle(
          color: headerText,
          fontWeight: FontWeight.w700,
        ),
      ),
      blockQuote: BlockQuoteStyle(
        barColor: scheme.primary,
        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      link: LinkStyle(
        color: linkColor,
        hoverColor: scheme.tertiary,
      ),
      inlineCode: InlineCodeStyle(
        color: cellColor,
        backgroundColor:
            scheme.onSurfaceVariant.withValues(alpha: 0.18),
      ),
      list: ListStyle(
        bulletColor: scheme.primary,
      ),
    ),
  );
}
