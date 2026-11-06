import 'package:ai_chat_app/theme/app_theme_id.dart';
import 'package:ai_chat_app/theme/app_theme_registry.dart';
import 'package:ai_chat_app/theme/ink_wash_theme.dart';
import 'package:ai_chat_app/theme/obsidian_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 主题注册表回归锁：新主题（曜石/墨韵）接入后
/// - 枚举可解析（持久化恢复）
/// - 明暗工厂可用（ThemeData 构造不抛）
/// - 圆角参数正确（组件层气泡/输入栏消费）
/// - 未知 id 回退默认（老备份兼容）
void main() {
  group('AppThemeRegistry 新主题接入', () {
    test('注册表含 5 个主题（默认/Minecraft/DeepSeek/曜石/墨韵）', () {
      expect(AppThemeRegistry.all.length, 5);
      expect(AppThemeRegistry.all.keys, containsAll(AppThemeId.values));
    });

    test('曜石：明暗工厂可用 + 圆角 12', () {
      final entry = AppThemeRegistry.all[AppThemeId.obsidian]!;
      expect(entry.label, '曜石');
      expect(entry.cornerRadius, 12);

      final light = entry.light();
      final dark = entry.dark();
      // 架构级深色：亮色版也是深底（surface 亮度 < 0.2），不是白底
      expect(light.colorScheme.surface.computeLuminance(), lessThan(0.2),
          reason: '曜石亮色版应是深灰蓝底，不是白底');
      expect(dark.colorScheme.surface.computeLuminance(), lessThan(0.1),
          reason: '暗色版纯黑基底（OLED 省电）');
      // 电光青主色（暗色版）
      expect(dark.colorScheme.primary, ObsidianTheme.electricCyan);
      // 用户气泡对比度回归锁（2026-11-05 修复）：亮色版 primary 底 +
      // onPrimary 白字 ≥4.5:1（旧值 #0090B8 + 近黑字 4.85:1 数学过线
      // 但深字在彩底上观感差——"黑色字体看不清"根因）
      final lp = light.colorScheme.primary;
      final lpLum = lp.computeLuminance();
      final whiteContrast =
          (1.0 + 0.05) / (lpLum + 0.05);
      expect(whiteContrast, greaterThan(4.5),
          reason: '亮色版 primary 底上白字对比度须达 WCAG AA');
      expect(light.colorScheme.onPrimary, Colors.white,
          reason: '亮色版 onPrimary 应是白字（与其他主题视觉语言一致）');
      // 暗色版电光青太亮白字不可行（1.77:1），深字 9.27:1 保持
      final dpContrast = dark.colorScheme.onPrimary.computeLuminance() >
              dark.colorScheme.primary.computeLuminance()
          ? (dark.colorScheme.onPrimary.computeLuminance() + 0.05) /
              (dark.colorScheme.primary.computeLuminance() + 0.05)
          : (dark.colorScheme.primary.computeLuminance() + 0.05) /
              (dark.colorScheme.onPrimary.computeLuminance() + 0.05);
      expect(dpContrast, greaterThan(7.0),
          reason: '暗色版电光青底 + 深字对比度应充足');
    });

    test('墨韵：明暗工厂可用 + 圆角 8', () {
      final entry = AppThemeRegistry.all[AppThemeId.inkWash]!;
      expect(entry.label, '墨韵');
      expect(entry.cornerRadius, 8);

      final light = entry.light();
      final dark = entry.dark();
      // 亮色 = 宣纸米白（暖白，红分量高于蓝——偏黄不是冷白）
      final paper = light.colorScheme.surface;
      expect(paper.computeLuminance(), greaterThan(0.85),
          reason: '宣纸底应接近白（高亮度）');
      expect((paper.r * 255.0).round(), greaterThan((paper.b * 255.0).round()),
          reason: '宣纸米白应偏暖（红>蓝），不是冷白');
      // 朱砂红主色（亮色版）
      expect(light.colorScheme.primary, InkWashTheme.cinnabar);
      // 暗色 = 砚台暖黑 + 黛青主色
      expect(dark.colorScheme.primary, InkWashTheme.indigo);
      expect(dark.colorScheme.surface.computeLuminance(), lessThan(0.05));
    });

    test('新主题 id 可从字符串解析（持久化恢复）', () {
      expect(AppThemeRegistry.parse('obsidian'), AppThemeId.obsidian);
      expect(AppThemeRegistry.parse('inkWash'), AppThemeId.inkWash);
    });

    test('未知 id 回退默认（老备份兼容）', () {
      expect(AppThemeRegistry.parse('nonexistent'), AppThemeId.material);
      expect(AppThemeRegistry.parse(null), AppThemeId.material);
    });

    test('resolve 明暗两套都能构造（不抛异常）', () {
      for (final id in AppThemeId.values) {
        expect(
          () => AppThemeRegistry.resolve(id, Brightness.light),
          returnsNormally,
          reason: '$id 亮色工厂应可用',
        );
        expect(
          () => AppThemeRegistry.resolve(id, Brightness.dark),
          returnsNormally,
          reason: '$id 暗色工厂应可用',
        );
      }
    });
  });
}
