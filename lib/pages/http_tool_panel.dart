import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/http_tool.dart';
import '../providers/http_tool_provider.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';

/// HTTP 工具管理面板（T1）：查看/新建/编辑/删除自定义 HTTP 工具
///
/// 嵌入设置页 PageView 作为独立 tag，无自带 Scaffold。
/// 编辑器为整页弹窗（字段多，弹窗放不下）。
class HttpToolPanel extends StatefulWidget {
  const HttpToolPanel({super.key});

  @override
  State<HttpToolPanel> createState() => _HttpToolPanelState();
}

class _HttpToolPanelState extends State<HttpToolPanel> {
  bool _loadRequested = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<HttpToolProvider>();

    // 首帧后触发加载（build 期间同步调 load + notifyListeners 会抛
    // markNeedsBuild during build，widget 测试必崩）
    if (!provider.loaded && !_loadRequested) {
      _loadRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) provider.load();
      });
    }

    if (!provider.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('自定义 HTTP 工具', style: theme.textTheme.titleSmall),
              ),
              FilledButton.icon(
                onPressed: () {
                  Haptics.light();
                  _openEditor(context);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
        Expanded(
          child: provider.tools.isEmpty
              ? Center(
                  child: Text(
                    '还没有自定义工具\n把任意 HTTP API 注册为 Agent 工具',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    for (final t in provider.tools)
                      Card(
                        elevation: 0,
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        child: ListTile(
                          leading: Icon(
                            Icons.http_outlined,
                            color: t.enabled
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  t.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13, fontFamily: 'Monocraft'),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  t.method.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color:
                                        theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            t.description.isEmpty ? t.urlTemplate : t.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 启用开关（禁用 = 不进工具目录）
                              Switch(
                                value: t.enabled,
                                onChanged: (v) {
                                  Haptics.selection();
                                  provider.update(
                                      t.copyWith(enabled: v, updatedAt: DateTime.now().millisecondsSinceEpoch));
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit_outlined,
                                    size: 20),
                                tooltip: '编辑',
                                onPressed: () {
                                  Haptics.light();
                                  _openEditor(context, tool: t);
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 20),
                                tooltip: '删除',
                                onPressed: () {
                                  Haptics.medium();
                                  _confirmDelete(context, t);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '· 工具 = URL 模板 + 参数定义 + 响应截取规则\n'
                      '· 模型按参数定义填参，{param} 占位符自动替换\n'
                      '· 在 Skill 编辑器的「可用工具」里按 Skill 授权\n'
                      '· 请求超时 15 秒，响应超长自动截断',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.6),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 新建/编辑整页（复用 slideUpRoute 由调用方导航）
  Future<void> _openEditor(BuildContext context, {HttpTool? tool}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => HttpToolEditorPage(tool: tool)),
    );
  }

  Future<void> _confirmDelete(BuildContext context, HttpTool tool) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除工具'),
        content: Text('删除「${tool.name}」后，引用它的 Skill 将无法再调用该工具。确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<HttpToolProvider>().delete(tool.id);
      if (context.mounted) showAppToast(context, '已删除');
    }
  }
}

/// HTTP 工具新建/编辑整页
class HttpToolEditorPage extends StatefulWidget {
  const HttpToolEditorPage({super.key, this.tool});

  /// null = 新建；非 null = 编辑
  final HttpTool? tool;

  @override
  State<HttpToolEditorPage> createState() => _HttpToolEditorPageState();
}

class _HttpToolEditorPageState extends State<HttpToolEditorPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _headersCtrl;
  late final TextEditingController _bodyCtrl;
  late final TextEditingController _paramsCtrl;
  late final TextEditingController _pathCtrl;
  late final TextEditingController _maxCharsCtrl;
  late String _method;
  bool _enabled = true;

  static const _methods = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'];

  @override
  void initState() {
    super.initState();
    final t = widget.tool;
    _nameCtrl = TextEditingController(text: t?.name ?? '');
    _descCtrl = TextEditingController(text: t?.description ?? '');
    _urlCtrl = TextEditingController(text: t?.urlTemplate ?? '');
    _headersCtrl = TextEditingController(text: t?.headersJson ?? '');
    _bodyCtrl = TextEditingController(text: t?.bodyTemplate ?? '');
    _paramsCtrl = TextEditingController(text: t?.parametersJson ?? '');
    _pathCtrl = TextEditingController(text: t?.responsePath ?? '');
    _maxCharsCtrl =
        TextEditingController(text: (t?.maxResponseChars ?? 4000).toString());
    _method = t?.method.toUpperCase() ?? 'GET';
    _enabled = t?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _urlCtrl.dispose();
    _headersCtrl.dispose();
    _bodyCtrl.dispose();
    _paramsCtrl.dispose();
    _pathCtrl.dispose();
    _maxCharsCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final url = _urlCtrl.text.trim();

    if (name.isEmpty) {
      showAppToast(context, '工具名不能为空');
      return;
    }
    if (!HttpTool.isValidName(name)) {
      showAppToast(context, '工具名只能用字母/数字/下划线/连字符');
      return;
    }
    if (url.isEmpty) {
      showAppToast(context, 'URL 模板不能为空');
      return;
    }
    final maxChars = int.tryParse(_maxCharsCtrl.text.trim());
    if (maxChars == null || maxChars < 100 || maxChars > 100000) {
      showAppToast(context, '截断长度需在 100–100000 之间');
      return;
    }
    // headers/params 必须是合法 JSON 对象（填了才校验）
    for (final (label, text) in [
      ('请求头', _headersCtrl.text.trim()),
      ('参数定义', _paramsCtrl.text.trim()),
    ]) {
      if (text.isEmpty) continue;
      try {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) {
          showAppToast(context, '$label必须是 JSON 对象');
          return;
        }
      } catch (_) {
        showAppToast(context, '$label不是合法 JSON');
        return;
      }
    }

    final provider = context.read<HttpToolProvider>();
    final now = DateTime.now().millisecondsSinceEpoch;
    final original = widget.tool;
    if (original == null) {
      await provider.create(HttpTool(
        id: now.toRadixString(36),
        name: name,
        description: _descCtrl.text.trim(),
        urlTemplate: url,
        method: _method,
        headersJson: _headersCtrl.text.trim(),
        bodyTemplate: _bodyCtrl.text.trim(),
        parametersJson: _paramsCtrl.text.trim(),
        responsePath: _pathCtrl.text.trim(),
        maxResponseChars: maxChars,
        enabled: _enabled,
        createdAt: now,
        updatedAt: now,
      ));
    } else {
      await provider.update(original.copyWith(
        name: name,
        description: _descCtrl.text.trim(),
        urlTemplate: url,
        method: _method,
        headersJson: _headersCtrl.text.trim(),
        bodyTemplate: _bodyCtrl.text.trim(),
        parametersJson: _paramsCtrl.text.trim(),
        responsePath: _pathCtrl.text.trim(),
        maxResponseChars: maxChars,
        enabled: _enabled,
        updatedAt: now,
      ));
    }

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBody = switch (_method) {
      'POST' || 'PUT' || 'PATCH' => true,
      _ => false,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.tool == null ? '新建 HTTP 工具' : '编辑 HTTP 工具'),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.light();
              _save();
            },
            child: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: '工具名',
                  hintText: '如 query_weather',
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 130,
              child: DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: const InputDecoration(labelText: '方法'),
                items: [
                  for (final m in _methods)
                    DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (v) => setState(() => _method = v ?? 'GET'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _descCtrl,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: '功能描述（模型据此决定何时调用）',
              hintText: '如：查询指定城市的实时天气',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'URL 模板',
              hintText: 'https://api.example.com/weather?city={city}',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _paramsCtrl,
            maxLines: 4,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: '参数定义（JSON Schema properties）',
              hintText: '{"city": {"type": "string", "description": "城市名"}}',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _headersCtrl,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: '请求头（JSON，可选）',
              hintText: '{"Authorization": "Bearer xxx"}',
              alignLabelWithHint: true,
            ),
          ),
          if (hasBody) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _bodyCtrl,
              maxLines: 4,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: '请求体模板（{param} 占位符）',
                hintText: '{"q": "{city}", "unit": "c"}',
                alignLabelWithHint: true,
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _pathCtrl,
            decoration: const InputDecoration(
              labelText: '响应截取路径（可选）',
              hintText: '如 data.temp；留空返回全文',
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _maxCharsCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: '响应截断长度（字符）',
                  hintText: '4000',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '· {param} 占位符会被模型填的参数替换（URL 和请求体都支持）\n'
              '· 参数定义决定模型怎么填参（JSON Schema properties 段）\n'
              '· 响应截取路径用点号逐层取值，数组用数字下标（data.items.0.name）\n'
              '· 保存后在 Skill 编辑器的「可用工具」里授权给 Skill',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
