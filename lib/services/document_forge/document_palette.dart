import 'package:flutter/material.dart';

/// 文档排版色板（Document Forge 排版美化，生成时从 App 主题快照）
///
/// 文档是打印物：白底黑字为基底，强调色只用于标题/表头/装饰条。
/// 强调色由宿主按当前 App 主题注入（AppThemeRegistry.accentColorOf），
/// 其余色阶从强调色派生，保证一套主题一个色系。
class DocumentPalette {
  DocumentPalette({required this.accent});

  /// 主题强调色（标题/表头底色/装饰条）
  final Color accent;

  /// 强调色的深色变体（标题文字用，白纸上更稳）
  Color get accentDeep {
    final hsl = HSLColor.fromColor(accent);
    return hsl.withLightness((hsl.lightness * 0.72).clamp(0.0, 1.0)).toColor();
  }

  /// 表头底色（强调色淡版，白纸上柔和）
  Color get headerBg {
    final hsl = HSLColor.fromColor(accent);
    return hsl.withLightness(0.92).toColor();
  }

  /// 斑马纹底色（比表头更淡一档）
  Color get zebraBg {
    final hsl = HSLColor.fromColor(accent);
    return hsl.withLightness(0.96).toColor();
  }

  /// 边框色（强调色灰调版）
  Color get border {
    final hsl = HSLColor.fromColor(accent);
    return hsl.withLightness(0.82).withSaturation(0.25).toColor();
  }

  /// 正文黑（暖黑，纯黑打印刺眼）
  static const bodyText = Color(0xFF1F2329);

  /// 次要文字灰（页脚/注释）
  static const mutedText = Color(0xFF8A9099);

  /// OOXML 十六进制（无 # 前缀，RRGGBB）
  String get accentHex => _hex(accent);
  String get accentDeepHex => _hex(accentDeep);
  String get headerBgHex => _hex(headerBg);
  String get zebraBgHex => _hex(zebraBg);
  String get borderHex => _hex(border);

  static String _hex(Color c) =>
      '${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
      '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
      '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}'
      .toUpperCase();
}
