import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../theme/app_theme_id.dart';
import '../theme/app_theme_registry.dart';

/// 主题状态：当前主题 ID + 切换 + 持久化
class ThemeProvider extends ChangeNotifier {
  ThemeProvider({required SettingsService settings}) : _settings = settings {
    _current = AppThemeRegistry.parse(settings.themeIdRaw);
  }

  final SettingsService _settings;
  AppThemeId _current = AppThemeRegistry.defaultId;

  AppThemeId get current => _current;

  /// 当前主题的组件圆角参数（自定义组件用）
  double get cornerRadius => AppThemeRegistry.cornerRadiusOf(_current);

  ThemeData theme(Brightness brightness) =>
      AppThemeRegistry.resolve(_current, brightness);

  Future<void> setTheme(AppThemeId id) async {
    if (_current == id) return;
    _current = id;
    await _settings.setThemeId(id.name);
    notifyListeners();
  }
}
