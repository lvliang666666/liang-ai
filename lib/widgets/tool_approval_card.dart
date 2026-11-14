import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/pending_tool.dart';
import '../providers/pending_tool_provider.dart';
import '../providers/theme_provider.dart';
import '../services/tools/http_tool_handler.dart';
import '../utils/haptics.dart';
import 'app_toast.dart';

/// 工具审批卡片（自我迭代批次）：模型提交的新 HTTP 工具定义，
/// 用户试运行后点「通过」（落库生效）/「拒绝」（丢弃）
///
/// 渲染位置：MessageBubble 内与 ToolCallBlock 同级——按消息的
/// manage_http_tool 调用关联 pending 记录显示。pending 已处理
/// （批/拒/会话删）显示「已处理」灰态，历史可溯。
///
/// 试运行：按 parameters_json 动态生成参数输入框 → HttpToolHandler
/// 临时实例真实发请求 → 响应截断展示。复用现有 handler，零新网络代码。
class ToolApprovalCard extends StatefulWidget {
  const ToolApprovalCard({super.key, required this.pending});

  final PendingTool pending;

  @override
  State<ToolApprovalCard> createState() => _ToolApprovalCardState();
}

class _ToolApprovalCardState extends State<ToolApprovalCard> {
  /// 试运行展开态（参数表单 + 响应区）
  bool _testing = false;

  /// 试运行参数（name → 用户填的值）
  final Map<String, String> _testArgs = {};

  /// 试运行进行中 / 响应文本 / 失败标记
  bool _running = false;
  String? _testResult;
  bool _testFailed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final radius = context.read<ThemeProvider>().cornerRadius;
    final tool = widget.pending;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：图标 + 标题 + 工具名
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Icon(Icons.build_circle_outlined,
                    size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '新工具待审批',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    tool.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'Monocraft'),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    tool.method.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 描述
          if (tool.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                tool.description,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            ),
          // URL 模板
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              tool.urlTemplate,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'Monocraft',
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // v2.32.1：请求头/请求体/响应路径折叠区（审批方肉眼核对全部
          // 字段——之前只展示 URL+参数，模型漏传请求体时无从发现）
          if (tool.headersJson.trim().isNotEmpty ||
              tool.bodyTemplate.trim().isNotEmpty ||
              tool.responsePath.trim().isNotEmpty)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  dense: true,
                  title: Text(
                    '请求详情（头/体/响应路径）',
                    style: theme.textTheme.bodySmall,
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _detailText(tool),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'Monocraft',
                          fontSize: 10,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 参数定义折叠区（ExpansionTile 内含 ListTile——卡片外层
          // DecoratedBox 有背景色会遮住 ListTile 的墨水效果触发框架
          // 断言，包一层 Material 提供绘制祖先）
          if (tool.parameters.isNotEmpty)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  dense: true,
                  title: Text(
                    '参数定义（${tool.parameters.length} 项）',
                    style: theme.textTheme.bodySmall,
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        const JsonEncoder.withIndent('  ')
                            .convert(tool.parameters),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'Monocraft',
                          fontSize: 10,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 试运行区（展开态：参数表单 + 响应）
          if (_testing) _buildTestArea(theme),
          // 操作区：试运行 / 拒绝 / 通过
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _running
                      ? null
                      : () {
                          Haptics.light();
                          setState(() => _testing = !_testing);
                        },
                  icon: Icon(
                    _testing ? Icons.expand_less : Icons.play_arrow,
                    size: 18,
                  ),
                  label: Text(_testing ? '收起试运行' : '试运行',
                      style: theme.textTheme.labelMedium),
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () {
                    Haptics.light();
                    _reject(context);
                  },
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    Haptics.medium();
                    _approve(context);
                  },
                  child: const Text('通过'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 请求详情折叠区文本（v2.32.1）：请求头 JSON / 请求体模板 / 响应
  /// 截取路径，只列非空字段
  static String _detailText(PendingTool tool) {
    final lines = <String>[];
    final headers = tool.headersJson.trim();
    if (headers.isNotEmpty) lines.add('请求头：$headers');
    final body = tool.bodyTemplate.trim();
    if (body.isNotEmpty) lines.add('请求体：$body');
    final path = tool.responsePath.trim();
    if (path.isNotEmpty) lines.add('响应路径：$path');
    return lines.join('\n');
  }

  /// 试运行区：按 parameters 动态生成输入框 + 执行按钮 + 响应展示
  Widget _buildTestArea(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final params = widget.pending.parameters;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in params.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: entry.key,
                    hintText: (entry.value is Map<String, dynamic>
                            ? entry.value['description'] as String?
                            : null) ??
                        entry.key,
                    counterText: '',
                  ),
                  maxLength: 200,
                  onChanged: (v) => _testArgs[entry.key] = v,
                ),
              ),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: _running ? null : _runTest,
                  child: Text(_running ? '请求中…' : '发送请求'),
                ),
                const SizedBox(width: 8),
                if (_testResult != null)
                  Expanded(
                    child: Text(
                      _testFailed ? '请求失败' : '响应如下',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _testFailed
                            ? colorScheme.error
                            : colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Text(
                      _testResult!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Monocraft',
                        fontSize: 10,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 试运行：临时 HttpToolHandler 真实发请求（不落库）
  Future<void> _runTest() async {
    setState(() {
      _running = true;
      _testResult = null;
      _testFailed = false;
    });
    try {
      final handler = HttpToolHandler(widget.pending.toPreviewTool());
      final args = <String, dynamic>{for (final e in _testArgs.entries) e.key: e.value};
      final output = await handler.execute(args);
      if (!mounted) return;
      setState(() {
        _testResult = output.length > 500 ? '${output.substring(0, 500)}…' : output;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testResult = '执行失败：$e';
        _testFailed = true;
        _running = false;
      });
    }
  }

  /// 审批通过：pending → http_tools + 会话内即时生效（宿主回调）
  Future<void> _approve(BuildContext context) async {
    final provider = context.read<PendingToolProvider>();
    await provider.approve(widget.pending);
    if (!context.mounted) return;
    showAppToast(context, '工具「${widget.pending.name}」已添加，本会话立即可用');
  }

  /// 拒绝：删 pending（模型可修改重提）
  Future<void> _reject(BuildContext context) async {
    final provider = context.read<PendingToolProvider>();
    await provider.reject(widget.pending);
    if (!context.mounted) return;
    showAppToast(context, '已拒绝「${widget.pending.name}」，模型可修改后重提');
  }
}
