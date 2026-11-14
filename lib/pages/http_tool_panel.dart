import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/http_tool.dart';
import '../providers/http_tool_provider.dart';
import '../providers/pending_tool_provider.dart';
import '../services/tools/builtin_tools.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';
import '../widgets/tool_approval_card.dart';

/// 工具管理面板（v2.32.1 二级导航改版）：一级页 = 类型卡片导航
/// （待审批有才显示 / 内置工具 / HTTP 工具），点击整页跳转二级列表。
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
    final pendingProvider = context.watch<PendingToolProvider>();

    // 首帧后触发加载（build 期间同步调 load + notifyListeners 会抛
    // markNeedsBuild during build，widget 测试必崩）
    if ((!provider.loaded || !pendingProvider.loaded) && !_loadRequested) {
      _loadRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        provider.load();
        pendingProvider.load();
      });
    }

    if (!provider.loaded || !pendingProvider.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    // 一级页：类型卡片导航（待审批有才显示——审批是高频动作但无 pending
    // 时占位反而碍眼；HTTP 工具卡片的「新建」入口保留在二级页）
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        if (pendingProvider.tools.isNotEmpty)
          _TypeCard(
            theme: theme,
            icon: Icons.pending_actions,
            iconColor: theme.colorScheme.primary,
            title: '待审批（${pendingProvider.tools.length}）',
            subtitle: '模型在对话中提交的新工具，试运行后点「通过」生效',
            onTap: () => _openPendingList(context),
          ),
        _TypeCard(
          theme: theme,
          icon: Icons.widgets_outlined,
          iconColor: theme.colorScheme.onSurfaceVariant,
          title: '内置工具（${builtinTools.length}）',
          subtitle: '随 App 内置，不可修改；在 Agent 编辑器里按 Agent 授权',
          onTap: () => _openBuiltinList(context),
        ),
        _TypeCard(
          theme: theme,
          icon: Icons.http_outlined,
          iconColor: theme.colorScheme.onSurfaceVariant,
          title: 'HTTP 工具（${provider.tools.length}）',
          subtitle:
              '把任意 HTTP API 注册为 Agent 工具；模型也能在对话中提交新工具',
          onTap: () => _openHttpList(context),
        ),
        const SizedBox(height: 8),
        Text(
          '· 工具 = URL 模板 + 参数定义 + 响应截取规则\n'
          '· 模型按参数定义填参，{param} 占位符自动替换\n'
          '· 在 Agent 编辑器的「可用工具」里按 Agent 授权\n'
          '· 请求超时 15 秒，响应超长自动截断',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant, height: 1.6),
        ),
      ],
    );
  }

  /// 二级页：待审批列表（审批卡片内嵌，跨会话聚合）
  void _openPendingList(BuildContext context) {
    Haptics.light();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const _PendingToolsPage(),
      ),
    );
  }

  /// 二级页：内置工具只读列表
  void _openBuiltinList(BuildContext context) {
    Haptics.light();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const _BuiltinToolsPage(),
      ),
    );
  }

  /// 二级页：HTTP 工具管理列表（新建/编辑/删除）
  void _openHttpList(BuildContext context) {
    Haptics.light();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const _HttpToolsPage(),
      ),
    );
  }
}

/// 一级页类型卡片（点击进二级列表）
class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.theme,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final ThemeData theme;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, size: 24, color: iconColor),
        title: Text(title, style: theme.textTheme.titleSmall),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        trailing: Icon(Icons.chevron_right,
            size: 22, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 二级页：待审批工具列表（审批卡片内嵌，跨会话聚合）
class _PendingToolsPage extends StatelessWidget {
  const _PendingToolsPage();

  @override
  Widget build(BuildContext context) {
    final pendingProvider = context.watch<PendingToolProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('待审批')),
      body: pendingProvider.tools.isEmpty
          ? const Center(child: Text('没有待审批的工具'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                for (final p in pendingProvider.tools)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ToolApprovalCard(pending: p),
                  ),
              ],
            ),
    );
  }
}

/// 二级页：内置工具只读列表
class _BuiltinToolsPage extends StatelessWidget {
  const _BuiltinToolsPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('内置工具')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          ...builtinTools.map(
            (t) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.extension_outlined,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
              title: Text(t.name,
                  style: const TextStyle(
                      fontSize: 13, fontFamily: 'Monocraft')),
              subtitle: Text(
                t.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二级页：HTTP 工具管理列表（新建/长按菜单编辑删除/启用开关）
class _HttpToolsPage extends StatelessWidget {
  const _HttpToolsPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<HttpToolProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('HTTP 工具'),
        actions: [
          FilledButton.icon(
            onPressed: () {
              Haptics.light();
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HttpToolEditorPage()),
              );
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: provider.tools.isEmpty
          ? const Center(child: Text('还没有自定义 HTTP 工具'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                for (final t in provider.tools)
                  _HttpToolCard(theme: theme, tool: t),
                const SizedBox(height: 8),
                Text(
                  '· 长按卡片弹出菜单（编辑/删除/复制 URL）\n'
                  '· 启用开关控制是否进工具目录\n'
                  '· 请求超时 15 秒，响应超长自动截断',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant, height: 1.6),
                ),
              ],
            ),
    );
  }
}

/// HTTP 工具卡片（v2.32.1 瘦身版）：右侧只留启用开关，编辑/删除/
/// 复制 URL 收进长按菜单——腾出宽度给工具名完整显示
class _HttpToolCard extends StatelessWidget {
  const _HttpToolCard({required this.theme, required this.tool});

  final ThemeData theme;
  final HttpTool tool;

  @override
  Widget build(BuildContext context) {
    final provider = context.read<HttpToolProvider>();
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: GestureDetector(
        onLongPressStart: (details) {
          Haptics.medium();
          _showActions(context, details.globalPosition);
        },
        child: ListTile(
          leading: Icon(
            Icons.http_outlined,
            color: tool.enabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          title: Row(
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
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  tool.method.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Text(
            tool.description.isEmpty ? tool.urlTemplate : tool.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Switch(
            value: tool.enabled,
            onChanged: (v) {
              Haptics.selection();
              provider.update(tool.copyWith(
                  enabled: v,
                  updatedAt: DateTime.now().millisecondsSinceEpoch));
            },
          ),
        ),
      ),
    );
  }

  /// 长按菜单：编辑 / 删除（带确认弹窗）/ 复制 URL
  Future<void> _showActions(BuildContext context, Offset pressPosition) async {
    // 锚定长按点（Overlay 坐标系），越界内收——写死坐标在测试 800×600
    // 视口下菜单偏出命中区，tap 落到别的层
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final box = overlay.size;
    const menuWidth = 160.0;
    const menuHeight = 140.0;
    var left = pressPosition.dx;
    var top = pressPosition.dy;
    if (left + menuWidth > box.width) left = box.width - menuWidth - 8;
    if (top + menuHeight > box.height) top = box.height - menuHeight - 8;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          left, top, box.width - left - menuWidth, box.height - top - menuHeight),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        const PopupMenuItem(
          value: 'edit',
          height: 44,
          child: Row(children: [
            Icon(Icons.edit_outlined, size: 20),
            SizedBox(width: 12),
            Text('编辑'),
          ]),
        ),
        const PopupMenuItem(
          value: 'copy',
          height: 44,
          child: Row(children: [
            Icon(Icons.copy_outlined, size: 20),
            SizedBox(width: 12),
            Text('复制 URL'),
          ]),
        ),
        const PopupMenuItem(
          value: 'delete',
          height: 44,
          child: Row(children: [
            Icon(Icons.delete_outline, size: 20),
            SizedBox(width: 12),
            Text('删除'),
          ]),
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'edit':
        Haptics.light();
        await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => HttpToolEditorPage(tool: tool)),
        );
      case 'copy':
        Haptics.light();
        // Clipboard.setData 是 platform channel 真异步——不 await
        //（fire-and-forget）：fakeAsync 测试区推不动 platform channel，
        // await 会让用例挂死并污染后续用例。复制失败无静默风险
        //（剪贴板写失败用户重按一次即可）
        unawaited(Clipboard.setData(ClipboardData(text: tool.urlTemplate)));
        if (context.mounted) showAppToast(context, 'URL 已复制');
      case 'delete':
        Haptics.medium();
        await _confirmDelete(context, tool);
    }
  }

  Future<void> _confirmDelete(BuildContext context, HttpTool tool) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除工具'),
        content: Text(
            '删除「${tool.name}」后，引用它的 Agent 将无法再调用该工具。确定删除吗？'),
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
    // v2.32.1：POST/PUT/PATCH 但请求体模板为空——大概率漏配（用户
    // 反馈建议），警告但不阻断（确实存在无 body 的 POST API）
    if (switch (_method) {
      'POST' || 'PUT' || 'PATCH' => _bodyCtrl.text.trim().isEmpty,
      _ => false,
    }) {
      showAppToast(context, '提示：$_method 通常需要请求体模板，当前为空');
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
              '· 保存后在 Agent 编辑器的「可用工具」里授权给 Agent',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
