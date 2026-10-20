import 'package:flutter/material.dart';

/// DeepSeek 风格配色与主题
///
/// 视觉语言：深海蓝主色（#4D6BFE）、大量留白、极简中性灰、
/// 圆角胶囊组件、无重装饰。亮色干净通透，暗色沉稳不刺眼。
class DeepSeekTheme {
  DeepSeekTheme._();

  // ===== 调色板 =====
  static const deepBlue = Color(0xFF4D6BFE); // DeepSeek 品牌蓝（主色）
  static const deepBlueDark = Color(0xFF3A55D9); // 暗色下的主色
  static const blueContainerLight = Color(0xFFE3E8FF); // 亮色主容器
  static const blueContainerDark = Color(0xFF2A3A8F); // 暗色主容器
  static const inkDark = Color(0xFF1B1F3B); // 亮色正文（近黑带蓝调）
  static const inkLight = Color(0xFFE8EAF2); // 暗色正文
  static const grayDim = Color(0xFF8A90A5); // 次要文字（中性灰蓝）
  static const surfaceLight = Color(0xFFF7F8FC); // 亮色背景（微蓝白）
  static const surfaceCardLight = Color(0xFFEFF1F6); // 亮色气泡/卡片
  static const surfaceDark = Color(0xFF151824); // 暗色背景（深蓝黑）
  static const surfaceCardDark = Color(0xFF22263A); // 暗色气泡/卡片

  /// 亮主题
  static ThemeData light() => _build(Brightness.light);

  /// 暗主题
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: isDark ? deepBlueDark : deepBlue,
      onPrimary: Colors.white,
      primaryContainer: isDark ? blueContainerDark : blueContainerLight,
      onPrimaryContainer: isDark ? blueContainerLight : Color(0xFF1A2A7A),
      secondary: isDark ? const Color(0xFF6B7BB8) : const Color(0xFF5A6A9E),
      onSecondary: Colors.white,
      secondaryContainer:
          isDark ? const Color(0xFF2C3352) : const Color(0xFFE4E8F4),
      onSecondaryContainer:
          isDark ? const Color(0xFFDCE2F5) : const Color(0xFF2C3355),
      tertiary: const Color(0xFF30B8A8), // 点缀青绿（思考/工具态）
      onTertiary: Colors.white,
      tertiaryContainer:
          isDark ? const Color(0xFF0E4A44) : const Color(0xFFC8F2EC),
      onTertiaryContainer:
          isDark ? const Color(0xFFC8F2EC) : const Color(0xFF00332E),
      error: const Color(0xFFE5484D),
      onError: Colors.white,
      errorContainer: isDark ? const Color(0xFF5C1A1A) : const Color(0xFFF3D4D4),
      onErrorContainer:
          isDark ? const Color(0xFFF3D4D4) : const Color(0xFF5C1A1A),
      surface: isDark ? surfaceDark : surfaceLight,
      onSurface: isDark ? inkLight : inkDark,
      surfaceContainerHighest:
          isDark ? surfaceCardDark : surfaceCardLight,
      onSurfaceVariant: grayDim,
      outline: isDark ? const Color(0xFF3A4059) : const Color(0xFFD5D9E4),
      outlineVariant:
          isDark ? const Color(0xFF2C3147) : const Color(0xFFE2E5EE),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      scaffoldBackgroundColor: scheme.surface,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.5,
        space: 1,
      ),
    );
  }
}
