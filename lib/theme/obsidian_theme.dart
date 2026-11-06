import 'package:flutter/material.dart';

/// 曜石（Obsidian）风格配色与主题
///
/// 视觉语言：架构级深色主题——明暗两套都以深色为本体设计（亮色版 =
/// 深灰蓝底，不是白底），系统明暗切换只影响对比度微调，不改变「暗」
/// 的气质。纯黑基底（OLED 省电）+ 电光青主色 + 高对比文字，赛博感
/// 但克制：无渐变、无发光、靠色彩对比与紧凑圆角表达科技感。
class ObsidianTheme {
  ObsidianTheme._();

  // ===== 调色板 =====
  static const electricCyan = Color(0xFF00D4FF); // 电光青（暗色主色）
  // 亮色版主色：#0090B8 → #007A9E（2026-11-05 对比度修复：白字 4.91:1
  // 达 AA；旧值 #0090B8 + 深字 4.85:1 数学过线但深字在彩底上观感差，
  // 是全 app 唯一深色 onPrimary——用户气泡文字"黑色看不清"根因）
  static const cyanDeep = Color(0xFF007A9E);
  static const cyanContainerDark = Color(0xFF00303F); // 暗色主容器
  static const cyanContainerLight = Color(0xFF123A46); // 亮色版主容器（仍深色）
  static const bgBlack = Color(0xFF0D0F14); // 暗色基底（纯黑偏蓝）
  static const panelDark = Color(0xFF171A21); // 暗色面板/气泡
  static const panelDarkHigh = Color(0xFF1E222B); // 暗色气泡（比面板亮一档）
  static const bgSlate = Color(0xFF16181F); // 亮色版背景（深灰蓝，非白）
  static const panelSlate = Color(0xFF1E222B); // 亮色版面板
  static const panelSlateHigh = Color(0xFF262B36); // 亮色版气泡
  static const inkBright = Color(0xFFE8ECF2); // 暗色正文（高对比）
  static const inkDim = Color(0xFF8A93A6); // 次要文字
  static const inkOnLight = Color(0xFFD5DAE4); // 亮色版正文（深底浅字）
  static const magenta = Color(0xFFE0409A); // 品红（思考/双答态点缀）
  static const amber = Color(0xFFFFB454); // 琥珀（权限/警告）
  static const dangerRed = Color(0xFFFF5C5C); // 错误

  // ===== Markdown 渲染令牌（2026-11-05 对比度批次，用户指定色值） =====
  // 经 markdown_style_sheet.dart 工厂注入 GptMarkdownThemeData，
  // 全部对各自底色 ≥4.5:1（WCAG AA），矩阵断言见 app_theme_registry_test
  static const mdHeading = Color(0xFFE5E7EB); // 章节标题（H1-H6 统一）
  static const mdTableHeaderBg = Color(0xFF1F2937); // 表头底
  static const mdTableHeaderText = Color(0xFFF9FAFB); // 表头文字
  static const mdTableCell = Color(0xFFD1D5DB); // 单元格文字
  static const mdTableBorder = Color(0xFF374151); // 表格边框
  static const mdCodeComment = Color(0xFF9CA3AF); // 代码块注释/次要文字

  /// 亮主题（深灰蓝底——曜石的「亮色」依然是暗的，只提一档亮度）
  static ThemeData light() => _build(Brightness.light);

  /// 暗主题（纯黑基底，OLED 友好）
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    // 曜石不跟随系统翻白：两套都以深色为基底，亮色版只是「暗的浅一档」
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: Brightness.dark, // 组件形态恒按暗色（深底浅字）
      primary: isDark ? electricCyan : cyanDeep,
      // onPrimary：亮色版白字（#007A9E 底 4.91:1 达 AA）；暗色版电光青
      // #00D4FF 亮度太高白字仅 1.77:1 不可行，深字 9.27:1 是唯一解
      // （类似荧光笔高亮，视觉成立）
      onPrimary: isDark ? const Color(0xFF00232E) : Colors.white,
      primaryContainer: isDark ? cyanContainerDark : cyanContainerLight,
      onPrimaryContainer:
          isDark ? const Color(0xFF8FE8FF) : const Color(0xFF7FD8F0),
      secondary: const Color(0xFF5A6B8C),
      onSecondary: Colors.white,
      secondaryContainer:
          isDark ? const Color(0xFF232B3D) : const Color(0xFF2A3040),
      onSecondaryContainer: const Color(0xFFC5CEDF),
      tertiary: const Color(0xFFE0409A), // 品红（思考/双答态）
      onTertiary: Colors.white,
      tertiaryContainer: const Color(0xFF4A1233),
      onTertiaryContainer: const Color(0xFFFFB8DC),
      error: dangerRed,
      onError: Colors.white,
      errorContainer: const Color(0xFF4A1515),
      onErrorContainer: const Color(0xFFFFC9C9),
      surface: isDark ? bgBlack : bgSlate,
      onSurface: isDark ? const Color(0xFFE8ECF2) : const Color(0xFFD5DAE4),
      surfaceContainerHighest:
          isDark ? panelDarkHigh : panelSlateHigh,
      onSurfaceVariant: inkDim,
      outline: isDark ? const Color(0xFF2A2F3A) : const Color(0xFF333947),
      outlineVariant: isDark ? const Color(0xFF1F232C) : const Color(0xFF232833),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.5,
        space: 1,
      ),
    );
  }
}
