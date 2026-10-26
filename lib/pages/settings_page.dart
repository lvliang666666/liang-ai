import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/provider_profile.dart';
import '../models/skill.dart';
import '../providers/http_tool_provider.dart';
import '../providers/memory_provider.dart';
import '../providers/provider_provider.dart';
import '../providers/sessions_provider.dart';
import '../providers/skill_provider.dart';
import '../providers/theme_provider.dart';
import '../services/backup_service.dart';
import '../services/database_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme_id.dart';
import 'http_tool_panel.dart';
import 'memory_page.dart';
import 'skill_editor_page.dart';
import '../theme/app_theme_registry.dart';
import '../utils/haptics.dart';
import '../utils/transitions.dart';
import '../widgets/app_toast.dart';
import '../widgets/tag_bar.dart';

/// 设置页：顶部可滑动 Tags 栏 + 分页内容
///
/// 分类：外观 / API 配置 / 对话参数 / 说明
/// 点击 tag 或左右滑动内容区均可切换，两者联动。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _tabs = ['外观', 'Skill 管理', '记忆管理', 'HTTP 工具', 'API 配置', '对话参数', '快捷操作', '备份', '说明'];

  late final SettingsService _settings;
  late final PageController _pageController;
  double _temperature = 0.7;
  String _effort = 'max';
  int _currentTab = 0;
  String _skillQuery = '';
  final _skillSearchController = TextEditingController();
  final _skillSearchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsService>();
    _temperature = _settings.temperature;
    _effort = _settings.defaultEffortValue;
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _skillSearchController.dispose();
    _skillSearchFocusNode.dispose();
    super.dispose();
  }

  /// 收起搜索框焦点：弹窗/操作完成后调用，防止焦点残留导致键盘反复弹出
  void _unfocusSkillSearch() {
    if (_skillSearchFocusNode.hasFocus) {
      _skillSearchFocusNode.unfocus();
    }
  }

  void _goToTab(int index) {
    if (index == _currentTab) return;
    Haptics.selection();
    // 切页收起焦点：PageView 页面保活，焦点残留会导致键盘自动弹出
    FocusManager.instance.primaryFocus?.unfocus();
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _save() async {
    await _settings.setDefaultEffort(_effort);
    await _settings.setTemperature(_temperature);
    if (mounted) {
      showAppToast(context, '设置已保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              _save();
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          // ===== 顶部 Tags 栏（可横向滑动） =====
          TagBar(
            tabs: _tabs,
            current: _currentTab,
            onTap: _goToTab,
          ),
          // ===== 分页内容 =====
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) {
                Haptics.selection();
                // 滑动切页同样收起焦点，避免键盘残留
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => _currentTab = index);
              },
              children: [
                _buildAppearanceTab(theme),
                _buildSkillTab(theme),
                const MemoryPanel(),
                const HttpToolPanel(),
                _buildApiTab(theme),
                _buildParamsTab(theme),
                _buildGesturesTab(theme),
                _buildBackupTab(theme),
                _buildAboutTab(theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== Tag 1：外观 =====
  Widget _buildAppearanceTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('主题风格', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ...AppThemeRegistry.all.entries.map((entry) => ListTile(
              leading: Icon(
                context.watch<ThemeProvider>().current == entry.key
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                color: theme.colorScheme.primary,
              ),
              title: Text(entry.value.label),
              onTap: () {
                Haptics.selection();
                context.read<ThemeProvider>().setTheme(entry.key);
              },
            )),
      ],
    );
  }

  // ===== Tag 2：Skill 管理 =====
  Widget _buildSkillTab(ThemeData theme) {
    final skills = context.watch<SkillProvider>();
    if (!skills.loaded) {
      skills.load();
      return const Center(child: CircularProgressIndicator());
    }

    // 搜索过滤（名称/描述，不区分大小写）
    final query = _skillQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? skills.skills
        : skills.skills
            .where((a) =>
                a.name.toLowerCase().contains(query) ||
                a.description.toLowerCase().contains(query))
            .toList();

    return Column(
      children: [
        // 搜索框 + 新建按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _skillSearchController,
                  focusNode: _skillSearchFocusNode,
                  onChanged: (v) => setState(() => _skillQuery = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索 Skill',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _skillQuery.isEmpty
                        ? null
                        : IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              Haptics.light();
                              _skillSearchController.clear();
                              setState(() => _skillQuery = '');
                            },
                          ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () {
                  Haptics.light();
                  _unfocusSkillSearch();
                  _openSkillEditor(context);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    query.isEmpty ? '还没有 Skill' : '没有找到「$_skillQuery」',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    ...filtered.map((a) => Card(
                          elevation: 0,
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          child: ListTile(
                            leading: Text(a.icon,
                                style: const TextStyle(fontSize: 24)),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    a.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (a.isBuiltin) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primaryContainer,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '内置',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: theme
                                            .colorScheme.onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              a.description.isEmpty
                                  ? '（无描述）'
                                  : a.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // 操作按钮：编辑 + （内置→复制 / 自定义→删除）
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined,
                                      size: 20),
                                  tooltip: a.isBuiltin ? '查看' : '编辑',
                                  onPressed: () {
                                    Haptics.light();
                                    _unfocusSkillSearch();
                                    _openSkillEditor(context, skill: a);
                                  },
                                ),
                                if (a.isBuiltin)
                                  IconButton(
                                    icon: const Icon(Icons.copy, size: 20),
                                    tooltip: '复制为自定义',
                                    onPressed: () {
                                      Haptics.medium();
                                      _unfocusSkillSearch();
                                      _confirmDuplicateSkill(context, a);
                                    },
                                  )
                                else
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 20),
                                    tooltip: '删除',
                                    onPressed: () {
                                      Haptics.medium();
                                      _unfocusSkillSearch();
                                      _confirmDeleteSkill(context, a);
                                    },
                                  ),
                              ],
                            ),
                          ),
                        )),
                    const SizedBox(height: 8),
                    Text(
                      '· 内置 Skill 不可删除，可复制一份后修改\n'
                      '· Skill = 提示词 + 可用工具 + 参数预设的组合包\n'
                      '· 提示词会作为 system 消息注入对话，工具子集决定模型能调用什么\n'
                      '· 在新建对话或聊天页顶部可切换 Skill',
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

  /// 复制内置 Skill：先确认再执行
  Future<void> _confirmDuplicateSkill(
      BuildContext context, Skill skill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('复制 Skill'),
        content: Text('将复制「${skill.name}」为自定义 Skill（名为「${skill.name} 副本」），可以随意修改。'),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, true);
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      _unfocusSkillSearch();
      await context.read<SkillProvider>().duplicate(skill);
      if (context.mounted) {
        showAppToast(context, '已复制为「${skill.name} 副本」');
      }
    }
  }

  /// Skill 新建/编辑整页（内置 Skill 只读查看）
  Future<void> _openSkillEditor(BuildContext context, {Skill? skill}) async {
    final saved = await Navigator.push<bool>(
      context,
      slideUpRoute(SkillEditorPage(skill: skill)),
    );

    if (saved != true || !mounted) return;

    // 页面关闭后兜底收起焦点：防止编辑页输入框的焦点被框架还给搜索框
    _unfocusSkillSearch();
  }

  Future<void> _confirmDeleteSkill(BuildContext context, Skill skill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 Skill'),
        content: Text('删除「${skill.name}」后，使用它的会话将回到默认助手。确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.heavy();
              Navigator.pop(context, true);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      _unfocusSkillSearch();
      context.read<SkillProvider>().delete(skill.id);
    }
  }

  // ===== Tag 3：API 配置（供应商列表） =====
  Widget _buildApiTab(ThemeData theme) {
    final providers = context.watch<ProviderProvider>();
    if (!providers.loaded) {
      providers.load();
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('供应商', style: theme.textTheme.titleSmall),
              ),
              FilledButton.icon(
                onPressed: () {
                  Haptics.light();
                  _showProviderEditor(context);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新增'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              ...providers.profiles.map((p) => Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    child: ListTile(
                      leading: Icon(
                        Icons.cloud_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              p.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (p.isBuiltin) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '内置',
                                style: TextStyle(
                                  fontSize: 10,
                                  color:
                                      theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        '${p.defaultModel.isEmpty ? '未设模型' : p.defaultModel}'
                        ' · ${p.apiKey.isEmpty ? '未填 Key' : '已填 Key'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            tooltip: '编辑',
                            onPressed: () {
                              Haptics.light();
                              _showProviderEditor(context, profile: p);
                            },
                          ),
                          if (!p.isBuiltin)
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 20),
                              tooltip: '删除',
                              onPressed: () {
                                Haptics.medium();
                                _confirmDeleteProvider(context, p);
                              },
                            ),
                        ],
                      ),
                    ),
                  )),
              const SizedBox(height: 8),
              Text(
                '· 供应商 = 一组 API 端点 + Key + 能力声明\n'
                '· 新会话默认用第一个供应商，聊天页顶部可按会话切换\n'
                '· 内置供应商不可删除，可编辑 Key 与模型',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.6),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 供应商编辑弹窗（新增/编辑共用）
  Future<void> _showProviderEditor(BuildContext context,
      {ProviderProfile? profile}) async {
    final isBuiltin = profile?.isBuiltin ?? false;
    final nameCtrl = TextEditingController(text: profile?.name ?? '');
    final urlCtrl = TextEditingController(text: profile?.baseUrl ?? '');
    final keyCtrl = TextEditingController(text: profile?.apiKey ?? '');
    final modelCtrl = TextEditingController(text: profile?.defaultModel ?? '');
    var vision = profile?.capabilities.vision ?? false;
    var reasoning = profile?.capabilities.reasoning ?? false;
    var effortParam = profile?.dialect.effortParam;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(profile == null ? '新增供应商' : '编辑供应商'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                TextField(
                  controller: nameCtrl,
                  enabled: !isBuiltin,
                  maxLength: 20,
                  decoration: const InputDecoration(
                      labelText: '名称', counterText: ''),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.example.com/v1',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keyCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    hintText: '留空 = 未配置',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: modelCtrl,
                  decoration: const InputDecoration(
                    labelText: '默认模型名',
                    hintText: '如 glm5.1 / deepseek-chat',
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('支持图片输入'),
                  subtitle: const Text('开启后聊天页显示拍照/相册按钮'),
                  value: vision,
                  onChanged: (v) => setDialogState(() => vision = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('支持思考流'),
                  subtitle: const Text('开启后展示深度思考过程'),
                  value: reasoning,
                  onChanged: (v) => setDialogState(() => reasoning = v),
                ),
                DropdownButtonFormField<String>(
                  initialValue: effortParam,
                  decoration: const InputDecoration(
                      labelText: '推理档位参数（方言）'),
                  items: const [
                    DropdownMenuItem(
                        value: 'reasoning_effort',
                        child: Text('reasoning_effort（GLM 系）')),
                    DropdownMenuItem(child: Text('不发送（其他供应商）')),
                  ],
                  onChanged: (v) => setDialogState(() => effortParam = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Haptics.light();
                Navigator.pop(context, false);
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Haptics.light();
                Navigator.pop(context, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !context.mounted) return;

    final name = nameCtrl.text.trim();
    final url = urlCtrl.text.trim();
    if (name.isEmpty || url.isEmpty) {
      showAppToast(context, '名称和 Base URL 不能为空');
      return;
    }

    final providers = context.read<ProviderProvider>();
    final capabilities = (profile?.capabilities ?? const ProviderCapabilities())
        .copyWith(vision: vision, reasoning: reasoning);
    final dialect = (profile?.dialect ?? const ProviderDialect())
        .copyWith(effortParam: effortParam);

    if (profile == null) {
      await providers.create(ProviderProfile(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: name,
        baseUrl: url,
        apiKey: keyCtrl.text.trim(),
        defaultModel: modelCtrl.text.trim(),
        capabilities: capabilities,
        dialect: dialect,
      ));
    } else {
      await providers.update(profile.copyWith(
        name: name,
        baseUrl: url,
        apiKey: keyCtrl.text.trim(),
        defaultModel: modelCtrl.text.trim(),
        capabilities: capabilities,
        dialect: dialect,
      ));
    }
  }

  /// 删除供应商：先确认再执行
  Future<void> _confirmDeleteProvider(
      BuildContext context, ProviderProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除供应商'),
        content: Text('确定删除「${profile.name}」吗？\n绑定它的会话将回退到默认供应商。'),
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
      await context.read<ProviderProvider>().delete(profile.id);
    }
  }

  // ===== Tag 3：对话参数 =====
  Widget _buildParamsTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('默认推理档位', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ...['max', 'high', 'low'].map((e) => ListTile(
              leading: Icon(
                _effort == e ? Icons.check_circle : Icons.circle_outlined,
                color: theme.colorScheme.primary,
              ),
              title: Text(switch (e) {
                'max' => '深度推理（默认）',
                'high' => '均衡推理',
                _ => '轻量推理（最快）',
              }),
              onTap: () {
                Haptics.selection();
                setState(() => _effort = e);
              },
            )),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text('温度'),
            Expanded(
              child: Slider(
                value: _temperature,
                min: 0,
                max: 2,
                divisions: 20,
                label: _temperature.toStringAsFixed(1),
                onChangeStart: (_) => Haptics.light(),
                onChanged: (v) => setState(() => _temperature = v),
                onChangeEnd: (_) => Haptics.selection(),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                _temperature.toStringAsFixed(1),
                textAlign: TextAlign.end,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ===== Tag 6：快捷操作（消息横滑手势开关） =====
  Widget _buildGesturesTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('消息横滑快捷操作'),
          subtitle: const Text(
            '开启后：助手消息左滑复制，用户消息右滑复制；'
            '关闭后恢复常规样式（长按复制仍可用）',
          ),
          value: _settings.swipeActions,
          onChanged: (v) {
            Haptics.selection();
            setState(() => _settings.setSwipeActions(v));
          },
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '· 横滑复制与「右滑出会话列表」抽屉共存：气泡上右滑开抽屉，'
            '左滑复制\n'
            '· 流式生成中的消息横滑自动禁用，避免与滚动冲突\n'
            '· 长按助手气泡可弹出菜单：复制全文 / 选择文字 / 导出并分享',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
          ),
        ),
      ],
    );
  }

  // ===== Tag 7：备份（E1 备份/导出） =====
  Widget _buildBackupTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '· 备份包含：会话、消息、Skill、记忆、HTTP 工具、供应商配置（不含 API Key）\n'
            '· 导出为 JSON 文件，通过系统分享面板发送（微信/网盘/邮件均可）\n'
            '· 导入会**清空并替换**当前全部数据，操作前请先导出一份备份\n'
            '· 导入后建议返回主页再继续聊天',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
          ),
        ),
        const SizedBox(height: 16),
        ListTile(
          leading: Icon(Icons.ios_share,
              color: theme.colorScheme.primary),
          title: const Text('导出备份'),
          subtitle: const Text('生成 JSON 文件并分享'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _exportBackup,
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.restore,
              color: theme.colorScheme.primary),
          title: const Text('导入备份'),
          subtitle: const Text('从 JSON 文件恢复（覆盖当前数据）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _importBackup,
        ),
      ],
    );
  }

  /// 导出备份：生成文件 + 系统分享面板
  Future<void> _exportBackup() async {
    Haptics.light();
    try {
      final service = BackupService(
        database: DatabaseService.instance,
        settings: _settings,
      );
      final result = await service.shareBackup();
      if (mounted && result?.status == ShareResultStatus.success) {
        showAppToast(context, '备份已生成');
      }
    } catch (e) {
      if (mounted) showAppToast(context, '导出失败：$e');
    }
  }

  /// 导入备份：选文件 → 确认覆盖 → 恢复 → 全量刷新
  Future<void> _importBackup() async {
    Haptics.light();
    // 1. 选文件
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(type: FileType.custom,
          allowedExtensions: ['json']);
    } on PlatformException {
      if (mounted) showAppToast(context, '当前环境不支持文件选择');
      return;
    }
    if (picked.isEmpty) return;
    final file = picked.single;
    final String jsonText;
    try {
      jsonText = await File(file.path!).readAsString();
    } catch (_) {
      if (mounted) showAppToast(context, '文件读取失败');
      return;
    }

    // 2. 确认覆盖（不可逆操作）
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('导入会清空并替换当前全部数据（会话/消息/Skill/记忆/供应商），'
            '此操作不可撤销。确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 3. 恢复
    try {
      final service = BackupService(
        database: DatabaseService.instance,
        settings: _settings,
      );
      final stats = await service.restore(jsonText);

      // 4. 应用备份中的主题 + 全量刷新四个 Provider
      final data =
          (const JsonDecoder().convert(jsonText) as Map)['data']
              as Map?;
      final themeId = data?['settings']?['theme_id'];
      if (themeId is String && mounted) {
        // 只应用备份里合法的主题 id（未知 id 不动当前主题）
        for (final id in AppThemeId.values) {
          if (id.name == themeId) {
            await context.read<ThemeProvider>().setTheme(id);
            break;
          }
        }
      }
      // M2：自动记忆沉淀开关随备份迁移（缺字段 = 老备份，不动当前值）
      final autoMemory = data?['settings']?['auto_memory'];
      if (autoMemory is bool && mounted) {
        await _settings.setAutoMemory(autoMemory);
      }
      if (!mounted) return;
      await context.read<SessionsProvider>().refresh();
      await context.read<SkillProvider>().load();
      await context.read<ProviderProvider>().load();
      await context.read<MemoryProvider>().load();
      await context.read<HttpToolProvider>().load();

      if (mounted) {
        showAppToast(context,
            '导入完成：${stats.sessions} 会话 / ${stats.messages} 消息');
      }
    } on BackupFormatException catch (e) {
      if (mounted) showAppToast(context, e.message);
    } catch (e) {
      if (mounted) showAppToast(context, '导入失败：$e');
    }
  }

  // ===== Tag 6：说明 =====
  Widget _buildAboutTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('使用说明', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                '· 公司内网建议切换到 vemic 域名，DNS 解析更快\n'
                '· 401 错误 = API Key 无效，请到内部平台重新申请\n'
                '· 403 错误 = 域名白名单限制，请使用预设域名\n'
                '· 新会话默认使用「对话参数」中的推理档位，聊天中可单独切换\n'
                '· API 配置修改后需点击右上角「保存」生效',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
