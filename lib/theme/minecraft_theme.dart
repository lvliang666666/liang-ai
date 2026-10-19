import 'package:flutter/material.dart';

/// Minecraft 风格配色与主题
///
/// 视觉语言：草绿主色、泥土棕/石头灰中性色、直角硬边框、
/// 按钮立体斜面（亮上左、暗下右，模拟 MC GUI 按钮）、Monocraft 像素字体。
class MinecraftTheme {
  MinecraftTheme._();

  // ===== 调色板 =====
  static const grassGreen = Color(0xFF5B8731); // 草方块绿（主色）
  static const grassDark = Color(0xFF3E5F22);
  static const dirtBrown = Color(0xFF79553A); // 泥土棕
  static const dirtDark = Color(0xFF4A3423);
  static const stoneGray = Color(0xFF7F7F7F); // 石头灰
  static const stoneDark = Color(0xFF3B3B3B);
  static const deepBg = Color(0xFF1C1C1C); // 深层岩石背景
  static const panelBg = Color(0xFF2B2B2B); // 面板背景（MC GUI 深灰）
  static const panelBorder = Color(0xFF4C4C4C);
  static const goldYellow = Color(0xFFFFAA00); // 金锭黄（强调）
  static const diamondCyan = Color(0xFF4AEDD9); // 钻石青
  static const redstoneRed = Color(0xFFC43C3C); // 红石红（错误）
  static const textLight = Color(0xFFE8E8E8);
  static const textDim = Color(0xFFA0A0A0);

  /// 字体族名（pubspec.yaml 中注册）
  static const fontFamily = 'Monocraft';

  /// 亮主题
  static ThemeData light() => _build(Brightness.light);

  /// 暗主题（MC GUI 天然适合暗色，推荐）
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: grassGreen,
      // AppBar 深色底（panelBg/stoneGray）上 primary 绿色可读性差，
      // onPrimary 固定白色，供 AppBar 内强调文字（Agent/模型名）使用
      onPrimary: Colors.white,
      primaryContainer: isDark ? grassDark : Color(0xFFDCEBC8),
      onPrimaryContainer: isDark ? Color(0xFFDCEBC8) : grassDark,
      secondary: dirtBrown,
      onSecondary: Colors.white,
      secondaryContainer: isDark ? dirtDark : Color(0xFFEAD9C5),
      onSecondaryContainer: isDark ? Color(0xFFEAD9C5) : dirtDark,
      tertiary: diamondCyan,
      onTertiary: Color(0xFF00332C),
      tertiaryContainer: isDark ? Color(0xFF0E4A42) : Color(0xFFC5F2EA),
      onTertiaryContainer: isDark ? Color(0xFFC5F2EA) : Color(0xFF00332C),
      error: redstoneRed,
      onError: Colors.white,
      errorContainer: isDark ? Color(0xFF5C1A1A) : Color(0xFFF3D4D4),
      onErrorContainer: isDark ? Color(0xFFF3D4D4) : Color(0xFF5C1A1A),
      surface: isDark ? panelBg : Color(0xFFECE9E2),
      onSurface: isDark ? textLight : Color(0xFF2B2B2B),
      surfaceContainerHighest: isDark ? Color(0xFF3B3B3B) : Color(0xFFDDD9CF),
      onSurfaceVariant: isDark ? textDim : Color(0xFF5A5A5A),
      outline: isDark ? panelBorder : Color(0xFF8A8A8A),
      outlineVariant: isDark ? Color(0xFF3B3B3B) : Color(0xFFC8C4BA),
    );

    // MC 按钮立体斜面：亮上左、暗下右
    final bevelLight = isDark ? Color(0xFF5A5A5A) : Color(0xFFFFFFFF);
    final bevelDark = isDark ? Color(0xFF151515) : Color(0xFFA8A49A);

    final baseBorder = BorderSide(color: scheme.outline, width: 2);

    return ThemeData(
      useMaterial3: false, // MC 风格用 Material 2 组件形态更贴近硬边框
      colorScheme: scheme,
      fontFamily: fontFamily,
      splashFactory: NoSplash.splashFactory,
      scaffoldBackgroundColor: isDark ? deepBg : Color(0xFFD8D4C8),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? panelBg : stoneGray,
        foregroundColor: textLight,
        elevation: 0,
        shape: Border(bottom: BorderSide(color: bevelDark, width: 2)),
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: textLight,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: scheme.outline, width: 2),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 3),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
      // 按钮：直角 + 立体斜面
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: grassGreen,
          foregroundColor: Colors.white,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          side: BorderSide(color: bevelLight, width: 2),
          elevation: 3,
          shadowColor: bevelDark,
          textStyle: const TextStyle(
              fontFamily: fontFamily, fontWeight: FontWeight.bold),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: grassGreen,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          textStyle: const TextStyle(fontFamily: fontFamily),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          side: BorderSide(color: scheme.outline, width: 2),
          elevation: 3,
          shadowColor: bevelDark,
          textStyle: const TextStyle(fontFamily: fontFamily),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: scheme.onSurface),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: grassGreen,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: bevelLight, width: 2),
        ),
        elevation: 4,
        extendedTextStyle:
            const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.bold),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? Color(0xFF1F1F1F) : Color(0xFFF5F3EC),
        hintStyle: TextStyle(fontFamily: fontFamily, color: textDim),
        labelStyle: TextStyle(fontFamily: fontFamily, color: textDim),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: baseBorder,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: baseBorder,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: grassGreen, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      listTileTheme: ListTileThemeData(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        iconColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 15,
          color: scheme.onSurface,
        ),
        subtitleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 12,
          color: scheme.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: panelBg,
        contentTextStyle:
            const TextStyle(fontFamily: fontFamily, color: textLight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: bevelLight, width: 2),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? panelBg : Color(0xFFECE9E2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: bevelLight, width: 2),
        ),
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: scheme.onSurface,
        ),
        contentTextStyle:
            TextStyle(fontFamily: fontFamily, fontSize: 14, color: scheme.onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? panelBg : Color(0xFFECE9E2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: bevelLight, width: 2),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? panelBg : Color(0xFFECE9E2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: bevelLight, width: 2),
        ),
        textStyle: TextStyle(fontFamily: fontFamily, color: scheme.onSurface),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? grassGreen
              : scheme.onSurfaceVariant,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: grassGreen,
        inactiveTrackColor: scheme.outlineVariant,
        thumbColor: goldYellow,
        overlayColor: grassGreen.withValues(alpha: 0.2),
        thumbShape: const RectangularSliderThumbShape(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? goldYellow
              : scheme.onSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? grassGreen.withValues(alpha: 0.5)
              : scheme.surfaceContainerHighest,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: grassGreen,
        linearTrackColor: scheme.outlineVariant,
      ),
      tooltipTheme: TooltipThemeData(
        textStyle: const TextStyle(fontFamily: fontFamily, fontSize: 12),
        decoration: BoxDecoration(
          color: panelBg,
          border: Border.all(color: bevelLight, width: 1),
        ),
      ),
    );
  }
}

/// 方形滑块拇指（MC 风格）
class RectangularSliderThumbShape extends SliderComponentShape {
  const RectangularSliderThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size(14, 14);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final rect = Rect.fromCenter(center: center, width: 14, height: 14);
    context.canvas.drawRect(
      rect,
      Paint()
        ..color = sliderTheme.thumbColor ?? Colors.white
        ..style = PaintingStyle.fill,
    );
    context.canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }
}
