import 'package:flutter/material.dart';

/// 墨韵（Ink Wash）风格配色与主题
///
/// 视觉语言：水墨宣纸气质——亮色 = 宣纸米白底 + 墨色正文 + 朱砂红主色
/// （印章/强调/发送键），暗色 = 砚台暖黑 + 淡墨文字 + 黛青主色。
/// 圆角收敛（8，折页感），留白大，文字是主角。中文 App 辨识度拉满，
/// 与聊天场景（文字为主角）天然契合。零新字体依赖，气质靠配色撑。
class InkWashTheme {
  InkWashTheme._();

  // ===== 调色板 =====
  static const cinnabar = Color(0xFFB03A2E); // 朱砂红（亮色主色，印章）
  static const cinnabarDeep = Color(0xFF8E2E24); // 朱砂深（按压态）
  static const cinnabarContainer = Color(0xFFF5E0DC); // 亮色主容器（淡朱）
  static const indigo = Color(0xFF4A7A8C); // 黛青（暗色主色）
  static const indigoContainerDark = Color(0xFF1E3A44); // 暗色主容器
  static const paperWhite = Color(0xFFF5F1E8); // 宣纸底（米白）
  static const paperCard = Color(0xFFEBE5D8); // 亮色气泡/卡片（略深的纸）
  static const inkBlack = Color(0xFF2B2B26); // 墨色正文（暖黑）
  static const inkDim = Color(0xFF8A8578); // 淡墨（次要文字）
  static const inkBorder = Color(0xFFD8D2C4); // 淡墨线（描边）
  static const inkWash = Color(0xFFE2DCCF); // 分隔线（更淡）
  static const inkStone = Color(0xFF1A1916); // 砚台黑（暗色基底，暖黑）
  static const inkPanel = Color(0xFF24231F); // 暗色面板
  static const inkCard = Color(0xFF2E2D28); // 暗色气泡
  static const inkTextDark = Color(0xFFE5E0D5); // 暗色正文（淡墨白）
  static const inkTextDimDark = Color(0xFF9A958A); // 暗色次要文字
  static const bambooGreen = Color(0xFF5A7A4A); // 竹青（成功/思考态点缀）
  static const sealRed = Color(0xFFC0392B); // 印泥红（错误，比朱砂亮）

  /// 亮主题（宣纸底）
  static ThemeData light() => _build(Brightness.light);

  /// 暗主题（砚台黑）
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: isDark ? indigo : cinnabar,
      onPrimary: Colors.white,
      primaryContainer: isDark ? indigoContainerDark : cinnabarContainer,
      onPrimaryContainer:
          isDark ? const Color(0xFFB8D8E0) : const Color(0xFF5A1A12),
      secondary: isDark ? const Color(0xFF7A7568) : const Color(0xFF6B665A),
      onSecondary: Colors.white,
      secondaryContainer:
          isDark ? const Color(0xFF33322C) : const Color(0xFFE5DFD0),
      onSecondaryContainer:
          isDark ? const Color(0xFFD5D0C2) : const Color(0xFF3E3A30),
      tertiary: bambooGreen, // 竹青（思考/工具态）
      onTertiary: Colors.white,
      tertiaryContainer:
          isDark ? const Color(0xFF2A3A22) : const Color(0xFFDCE8D0),
      onTertiaryContainer:
          isDark ? const Color(0xFFC8E0B8) : const Color(0xFF2A3A1E),
      error: sealRed,
      onError: Colors.white,
      errorContainer:
          isDark ? const Color(0xFF4A1A15) : const Color(0xFFF3DAD5),
      onErrorContainer:
          isDark ? const Color(0xFFF3DAD5) : const Color(0xFF5A1A12),
      surface: isDark ? inkStone : paperWhite,
      onSurface: isDark ? inkTextDark : inkBlack,
      surfaceContainerHighest: isDark ? inkCard : paperCard,
      onSurfaceVariant: isDark ? inkTextDimDark : inkDim,
      outline: isDark ? const Color(0xFF3E3C35) : const Color(0xFFB8B2A2),
      outlineVariant: isDark ? const Color(0xFF2A2925) : inkWash,
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
