import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../models/doc_chunk.dart';
import 'app_bottom_sheet.dart';
import 'app_toast.dart';
import '../utils/haptics.dart';

/// 引用标注解析（F8）：从回答文本提取【文件名·第N页】标注
///
/// 格式契约与注入指令一致（ChatProvider.buildDocContextText）：
/// 【文件名·第N页】——文件名不含【】与·，页码为正整数。
/// 去重保序（同一来源多次引用只出一个 chip）。
List<CitationRef> parseCitations(String content) {
  final refs = <CitationRef>[];
  final seen = <String>{};
  final regex = RegExp(r'【([^【】·]+)·第(\d+)页】');
  for (final match in regex.allMatches(content)) {
    final docName = match.group(1)!;
    final page = int.tryParse(match.group(2)!) ?? 1;
    final key = '$docName#$page';
    if (seen.contains(key)) continue;
    seen.add(key);
    refs.add(CitationRef(docName: docName, page: page));
  }
  return refs;
}

/// 一条引用来源（文件名 + 页码）
class CitationRef {
  const CitationRef({required this.docName, required this.page});

  final String docName;
  final int page;

  String get label => '$docName · 第$page页';
}

/// 「打开原文件」实现（可测试注入；生产 = OpenFilex 调系统应用）
Future<String> Function(String path) openSourceFileImpl =
    (path) async => (await OpenFilex.open(path)).type.name;

/// 引用来源 chips 行（assistant 气泡正文下方）：点击弹来源原文 Sheet
///
/// [resolveChunk] 按 (docName, page) 从 doc_chunks 查回原文块；
/// null = 无检索能力（chips 纯展示不可点）。
class CitationChips extends StatelessWidget {
  const CitationChips({
    super.key,
    required this.content,
    this.resolveChunk,
  });

  final String content;
  final Future<DocChunk?> Function(String docName, int page)? resolveChunk;

  @override
  Widget build(BuildContext context) {
    final refs = parseCitations(content);
    if (refs.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final ref in refs)
            ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(Icons.description_outlined,
                  size: 14, color: colorScheme.primary),
              label: Text(
                ref.label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                    ),
              ),
              onPressed: resolveChunk == null
                  ? null
                  : () => _showSource(context, ref),
            ),
        ],
      ),
    );
  }

  /// 来源原文 Sheet：片段原文（可选中复制）+ 打开原文件（有路径时）
  Future<void> _showSource(BuildContext context, CitationRef ref) async {
    Haptics.light();
    final chunk = await resolveChunk!(ref.docName, ref.page);
    if (!context.mounted) return;
    if (chunk == null) {
      showAppToast(context, '未找到该来源的原文片段');
      return;
    }
    await showAppBottomSheet<void>(
      context: context,
      // v2.30.3：键盘适配/60% 上限/状态栏保护已下沉到 showAppBottomSheet
      // 入口统一施加，调用点不再手动包 SheetKeyboardInset
      builder: (context) => SheetScaffold(
        title: ref.label,
        // SingleChildScrollView：引用原文可能很长，矮屏 60% 上限内放不下
        // 时可滚动（v2.30.3 矮屏防护，同消息操作菜单）
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  chunk.content,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(height: 1.6),
                ),
              ),
              if (chunk.sourcePath.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('打开原文件'),
                    onPressed: () => _openSource(context, chunk.sourcePath),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSource(BuildContext context, String path) async {
    try {
      final result = await openSourceFileImpl(path);
      if (result != 'done' && context.mounted) {
        showAppToast(context, '无法打开该文件');
      }
    } catch (_) {
      if (context.mounted) showAppToast(context, '无法打开该文件');
    }
  }
}
