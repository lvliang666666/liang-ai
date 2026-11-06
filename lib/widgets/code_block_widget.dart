import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';

import '../theme/obsidian_theme.dart';
import '../utils/haptics.dart';

/// 语法高亮主题：atomOneDark 基底 + 注释/引用色覆盖。
///
/// atomOneDark 的注释 #5C6370 对代码底 #282C34 对比度仅 2.32:1（实测），
/// 深色主题下不可读——覆盖为曜石 mdCodeComment 令牌 #9CA3AF（5.51:1，
/// WCAG AA 达标）。其余 token 色保持 atomOneDark 原值（对底均 ≥4.5:1）。
final Map<String, TextStyle> _highlightTheme = {
  ...atomOneDarkTheme,
  'comment': const TextStyle(
    color: ObsidianTheme.mdCodeComment,
    fontStyle: FontStyle.italic,
  ),
  'quote': const TextStyle(
    color: ObsidianTheme.mdCodeComment,
    fontStyle: FontStyle.italic,
  ),
};

/// 代码块：语言标签 + 复制按钮 + 语法高亮
///
/// 复制反馈（UI 批次 1）：按钮内状态切换，不用底部 Toast——
/// 反馈就在动作点（按钮原地变「✓已复制」绿色对勾），1500ms 后还原；
/// 重复点击重新计时，不叠加不闪烁。
class CodeBlockWidget extends StatelessWidget {
  const CodeBlockWidget({super.key, required this.code, this.language});

  final String code;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final lang = (language == null || language!.isEmpty) ? 'text' : language!;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF282C34),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: const Color(0xFF21252B),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Text(
                  lang,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade400,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                _CopyButton(code: code),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.widthOf(context) * 0.75,
              ),
              child: HighlightView(
                code,
                language: lang,
                theme: _highlightTheme,
                padding: const EdgeInsets.all(12),
                textStyle: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 复制按钮：点击后原地切换反馈态（绿色对勾 + 「已复制」），1500ms 还原
///
/// - 反馈态：复制图标 → 16dp 绿色对勾（#34C759），「复制」→「已复制」
/// - 按钮位置尺寸不变（Row 主轴尺寸由文案撑开，无布局跳动）
/// - 重复点击：重新计时（刷新 1500ms），不叠加
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.code});

  final String code;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _revertTimer;

  // 反馈态颜色（需求规格：绿色对勾 #34C759）
  static const _copiedColor = Color(0xFF34C759);

  @override
  void dispose() {
    _revertTimer?.cancel();
    super.dispose();
  }

  Future<void> _onTap() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    Haptics.medium(); // 复制完成反馈（三档词汇表：medium）
    if (!mounted) return;
    // 重复点击：重新计时（先撤旧 Timer 再起新的），状态保持不闪烁
    _revertTimer?.cancel();
    setState(() => _copied = true);
    _revertTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _copied ? _copiedColor : Colors.grey.shade400;
    return InkWell(
      onTap: _onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 复制图标 ↔ 16dp 绿色对勾（原地切换）
            _copied
                ? const Icon(Icons.check, size: 16, color: _copiedColor)
                : Icon(Icons.copy, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              _copied ? '已复制' : '复制',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
