import 'package:flutter/material.dart';

import 'app_theme_id.dart';
import 'minecraft_theme.dart';

/// 单个主题的元数据：显示名 + 明暗两套 ThemeData 工厂 + 组件样式参数
class AppThemeEntry {
  const AppThemeEntry({
    required this.label,
    required this.light,
    required this.dark,
    this.cornerRadius = 16.0,
  });

  final String label;
  final ThemeData Function() light;
  final ThemeData Function() dark;

  /// 聊天气泡/思考块/输入栏等自定义组件的圆角半径
  /// （Material 风格 16，Minecraft 等硬边框风格 0）
  final double cornerRadius;
}

/// 主题注册表
///
/// 扩展新主题三步：
/// 1. 在 [AppThemeId] 添加枚举值
/// 2. 新建主题文件（参考 minecraft_theme.dart）
/// 3. 在 [_registry] 登记一行
class AppThemeRegistry {
  AppThemeRegistry._();

  /// 默认主题
  static const AppThemeId defaultId = AppThemeId.material;

  static final Map<AppThemeId, AppThemeEntry> _registry = {
    AppThemeId.material: AppThemeEntry(
      label: '默认',
      light: () => ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: const Color(0xFF4F8CFF)),
        useMaterial3: true,
      ),
      dark: () => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F8CFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
    ),
    AppThemeId.minecraft: AppThemeEntry(
      label: 'Minecraft',
      light: MinecraftTheme.light,
      dark: MinecraftTheme.dark,
      cornerRadius: 0,
    ),
  };

  /// 全部可选主题（供设置页展示）
  static Map<AppThemeId, AppThemeEntry> get all =>
      Map.unmodifiable(_registry);

  /// 取主题（明/暗），未知 id 回退默认
  static ThemeData resolve(AppThemeId id, Brightness brightness) {
    final entry = _registry[id] ?? _registry[defaultId]!;
    return brightness == Brightness.dark ? entry.dark() : entry.light();
  }

  /// 取主题的组件圆角参数，未知 id 回退默认
  static double cornerRadiusOf(AppThemeId id) =>
      (_registry[id] ?? _registry[defaultId]!).cornerRadius;

  /// 主题显示名
  static String labelOf(AppThemeId id) =>
      (_registry[id] ?? _registry[defaultId]!).label;

  /// 从字符串解析（持久化恢复用），未知值回退默认
  static AppThemeId parse(String? value) {
    for (final id in AppThemeId.values) {
      if (id.name == value) return id;
    }
    return defaultId;
  }
}
