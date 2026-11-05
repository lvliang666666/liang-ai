/// 应用主题风格 ID
///
/// 扩展新主题：在此添加枚举值 → 在 app_theme_registry.dart 注册 → 完成。
enum AppThemeId {
  /// Material 3 默认风格（当前默认）
  material,

  /// Minecraft 像素风格
  minecraft,

  /// DeepSeek 风格（深海蓝 + 极简留白）
  deepseek,

  /// 曜石风格（架构级深色：纯黑基底 + 电光青，明暗两套都是暗色气质）
  obsidian,

  /// 墨韵风格（水墨宣纸：宣纸米白 + 朱砂红 / 砚台黑 + 黛青）
  inkWash,
}
