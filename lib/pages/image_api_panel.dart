import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/image_api.dart';
import '../providers/image_api_provider.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';

/// 生图 API 管理面板（Image Forge）：配置文生图服务（OpenAI 兼容格式）
///
/// 嵌入设置页 PageView 作为独立 tag，无自带 Scaffold。
/// 编辑器为底部弹窗（字段少：名称/地址/Key/模型/尺寸）。
/// 模型在对话中调 generate_image 工具时按启用清单调用。
class ImageApiPanel extends StatefulWidget {
  const ImageApiPanel({super.key});

  @override
  State<ImageApiPanel> createState() => _ImageApiPanelState();
}

class _ImageApiPanelState extends State<ImageApiPanel> {
  bool _loadRequested = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<ImageApiProvider>();

    if (!provider.loaded && !_loadRequested) {
      _loadRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        provider.load();
      });
    }

    if (!provider.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('生图服务（${provider.apis.length}）',
                  style: theme.textTheme.titleMedium),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '添加生图 API',
              onPressed: () => _editApi(context, null),
            ),
          ],
        ),
        if (provider.apis.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Column(
              children: [
                Icon(Icons.image_outlined,
                    size: 48, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('还没有配置生图 API',
                    style: theme.textTheme.bodyLarge),
                const SizedBox(height: 6),
                Text(
                  '点右上角 + 添加一个 OpenAI 兼容的文生图服务\n'
                  '（智谱 CogView / 硅基流动 / OpenAI 等均可）',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.6),
                ),
              ],
            ),
          ),
        for (final api in provider.apis)
          _ImageApiCard(
            api: api,
            onEdit: () => _editApi(context, api),
            onDelete: () => _deleteApi(context, api),
            onToggle: (v) => _toggleApi(context, api, v),
          ),
        const SizedBox(height: 8),
        Text(
          '· 仅支持 OpenAI 兼容格式（/images/generations）\n'
          '· 对话中说「画一张…」模型会自动调用启用的服务\n'
          '· 多个启用时模型可用第一个；也可在对话中点名\n'
          '· API Key 仅存本地数据库，不上传',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant, height: 1.6),
        ),
      ],
    );
  }

  void _editApi(BuildContext context, ImageApi? existing) {
    Haptics.light();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ImageApiEditor(existing: existing),
    );
  }

  Future<void> _deleteApi(BuildContext context, ImageApi api) async {
    Haptics.light();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除生图 API'),
        content: Text('确定删除「${api.name}」？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<ImageApiProvider>().delete(api.id);
      if (context.mounted) showAppToast(context, '已删除');
    }
  }

  Future<void> _toggleApi(
      BuildContext context, ImageApi api, bool value) async {
    await context
        .read<ImageApiProvider>()
        .update(ImageApi(
          id: api.id,
          name: api.name,
          baseUrl: api.baseUrl,
          apiKey: api.apiKey,
          model: api.model,
          size: api.size,
          enabled: value,
          createdAt: api.createdAt,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
  }
}

/// 生图 API 卡片（名称/模型/启用开关，点击编辑）
class _ImageApiCard extends StatelessWidget {
  const _ImageApiCard({
    required this.api,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  final ImageApi api;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(Icons.image_outlined,
            color: api.enabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant),
        title: Text(api.name,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: api.enabled
                    ? null
                    : theme.colorScheme.onSurfaceVariant)),
        subtitle: Text(
          '${api.model} · ${api.size}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: api.enabled, onChanged: onToggle),
            PopupMenuButton<String>(
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'delete') onDelete();
              },
            ),
          ],
        ),
        onTap: onEdit,
      ),
    );
  }
}

/// 生图 API 编辑器（底部弹窗：新建/编辑两用）
class _ImageApiEditor extends StatefulWidget {
  const _ImageApiEditor({this.existing});

  final ImageApi? existing;

  @override
  State<_ImageApiEditor> createState() => _ImageApiEditorState();
}

class _ImageApiEditorState extends State<_ImageApiEditor> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _size;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _size = TextEditingController(text: e?.size ?? '1024x1024');
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _size.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim().replaceAll(RegExp(r'/+$'), '');
    final apiKey = _apiKey.text.trim();
    final model = _model.text.trim();
    final size = _size.text.trim().isEmpty ? '1024x1024' : _size.text.trim();
    if (name.isEmpty || baseUrl.isEmpty || apiKey.isEmpty || model.isEmpty) {
      showAppToast(context, '名称/地址/Key/模型 都必填');
      return;
    }
    if (!baseUrl.startsWith('http')) {
      showAppToast(context, '地址需以 http(s):// 开头');
      return;
    }
    final provider = context.read<ImageApiProvider>();
    final e = widget.existing;
    final api = ImageApi(
      id: e?.id ??
          'img_${DateTime.now().millisecondsSinceEpoch}_${name.hashCode.abs() % 10000}',
      name: name,
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      size: size,
      enabled: e?.enabled ?? true,
      createdAt: e?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (e == null) {
      await provider.create(api);
    } else {
      await provider.update(api);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.existing == null ? '添加生图 API' : '编辑生图 API',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                labelText: '名称（如：智谱 CogView）'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'API 地址（到版本号即可）',
              hintText: 'https://open.bigmodel.cn/api/paas/v4',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration:
                const InputDecoration(labelText: 'API Key'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
                labelText: '模型名（如：cogview-4）'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _size,
            decoration: const InputDecoration(
                labelText: '默认尺寸（如：1024x1024）'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
