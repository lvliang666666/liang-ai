import 'dart:math';

import 'package:ai_chat_app/theme/app_theme_id.dart';
import 'package:ai_chat_app/theme/app_theme_registry.dart';
import 'package:ai_chat_app/theme/ink_wash_theme.dart';
import 'package:ai_chat_app/theme/markdown_style_sheet.dart';
import 'package:ai_chat_app/theme/obsidian_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

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

  group('Markdown 渲染对比度矩阵（WCAG AA ≥4.5:1）', () {
    // 对比度计算（WCAG 相对亮度公式）
    double luminance(Color c) => c.computeLuminance();
    double contrast(Color a, Color b) {
      final la = luminance(a);
      final lb = luminance(b);
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
    }

    // Markdown 主题数据：直接调工厂（与 main.dart builder 同路径——
    // GptMarkdownTheme 经 MaterialApp.builder 注入，不走 ThemeExtension）
    GptMarkdownThemeData mdThemeOf(AppThemeId id, ThemeData theme) =>
        markdownThemeData(
          theme.colorScheme,
          tokens: AppThemeRegistry.markdownTokensOf(id),
        );

    for (final id in AppThemeId.values) {
      for (final brightness in Brightness.values) {
        test('$id/$brightness: 标题/表格/行内代码全部达标', () {
          final theme = AppThemeRegistry.resolve(id, brightness);
          final md = mdThemeOf(id, theme);
          final scheme = theme.colorScheme;
          // 气泡底（AI 回复正文所在）：surfaceContainerHighest@45% 叠 surface
          // ——与 message_bubble.dart 的气泡底色公式一致
          final bubbleBg = Color.lerp(
            scheme.surfaceContainerHighest,
            scheme.surface,
            0.55,
          )!;

          // ① 标题（H1-H6）对气泡底 ≥4.5:1
          for (final (i, h) in [md.h1, md.h2, md.h3, md.h4, md.h5, md.h6]
              .indexed) {
            expect(
              contrast(h!.color!, bubbleBg),
              greaterThanOrEqualTo(4.5),
              reason: '$id/$brightness H${i + 1} 标题色对气泡底须 ≥4.5:1',
            );
          }

          // ② 表格：表头文字对表头底、单元格文字对气泡底、边框可见性
          final table = md.styleSheet.table!;
          expect(
            contrast(table.headerTextStyle!.color!, table.headerBackground!),
            greaterThanOrEqualTo(4.5),
            reason: '$id/$brightness 表头文字对表头底须 ≥4.5:1',
          );
          expect(
            contrast(scheme.onSurface, bubbleBg),
            greaterThanOrEqualTo(4.5),
            reason: '$id/$brightness 正文/单元格文字对气泡底须 ≥4.5:1',
          );
          expect(
            contrast(table.borderColor!, bubbleBg),
            greaterThanOrEqualTo(1.2),
            reason: '$id/$brightness 表格边框对气泡底须可辨识（≥1.2:1，'
                '装饰线标准——用户指定的曜石边框 #374151 对气泡底也是 2.2:1）',
          );

          // ③ 行内代码：文字对代码 chip 底 ≥4.5:1
          final inlineCode = md.styleSheet.inlineCode!;
          // chip 底 = backgroundColor（半透明）叠气泡底
          final chipBg = Color.alphaBlend(
            inlineCode.backgroundColor!,
            bubbleBg,
          );
          expect(
            contrast(inlineCode.color!, chipBg),
            greaterThanOrEqualTo(4.5),
            reason: '$id/$brightness 行内代码文字对 chip 底须 ≥4.5:1',
          );

          // ④ 链接对气泡底 ≥4.5:1（可点击元素必须可辨识）
          final link = md.styleSheet.link!;
          expect(
            contrast(link.color!, bubbleBg),
            greaterThanOrEqualTo(4.5),
            reason: '$id/$brightness 链接色对气泡底须 ≥4.5:1',
          );
        });
      }
    }

    test('曜石 Markdown 令牌：用户指定色值精确生效', () {
      final theme = AppThemeRegistry.resolve(
        AppThemeId.obsidian,
        Brightness.dark,
      );
      final md = mdThemeOf(AppThemeId.obsidian, theme);
      // 标题 = 用户指定 #E5E7EB
      expect(md.h1!.color, ObsidianTheme.mdHeading);
      expect(md.styleSheet.heading!.textStyle!.color,
          ObsidianTheme.mdHeading);
      // 表格 = 用户指定四色
      final table = md.styleSheet.table!;
      expect(table.headerBackground, ObsidianTheme.mdTableHeaderBg);
      expect(table.headerTextStyle!.color, ObsidianTheme.mdTableHeaderText);
      expect(table.borderColor, ObsidianTheme.mdTableBorder);
      // 单元格文字经 tokens.tableCell → inlineCode.color 同源
      expect(
        md.styleSheet.inlineCode!.color,
        ObsidianTheme.mdTableCell,
      );
    });

    test('代码块注释色对代码底 ≥4.5:1（atomOneDark 覆盖后）', () {
      // 覆盖后的注释色 = 曜石 mdCodeComment #9CA3AF
      const codeBg = Color(0xFF282C34); // CodeBlockWidget 硬编码底
      final comment = ObsidianTheme.mdCodeComment;
      final c = contrast(comment, codeBg);
      expect(c, greaterThanOrEqualTo(4.5),
          reason: '代码注释 #9CA3AF 对 #282C34 实测 ${c.toStringAsFixed(2)}:1');
      // 旧值回归锁：atomOneDark 原注释 #5C6370 只有 2.32:1，禁止回退
      expect(contrast(const Color(0xFF5C6370), codeBg), lessThan(4.5),
          reason: '旧注释色不达标——此断言防回退');
    });
  });
}
