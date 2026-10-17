import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../services/settings_service.dart';
import '../theme/app_theme_registry.dart';
import '../utils/haptics.dart';

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
  static const _tabs = ['外观', 'API 配置', '对话参数', '说明'];

  late final SettingsService _settings;
  late final TextEditingController _keyController;
  late final TextEditingController _urlController;
  late final TextEditingController _modelController;
  late final PageController _pageController;
  double _temperature = 0.7;
  String _effort = 'max';
  bool _obscureKey = true;
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsService>();
    _keyController = TextEditingController(text: _settings.apiKey);
    _urlController = TextEditingController(text: _settings.baseUrl);
    _modelController = TextEditingController(text: _settings.model);
    _temperature = _settings.temperature;
    _effort = _settings.defaultEffortValue;
    _pageController = PageController();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _urlController.dispose();
    _modelController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _goToTab(int index) {
    if (index == _currentTab) return;
    Haptics.selection();
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _save() async {
    await _settings.setApiKey(_keyController.text.trim());
    await _settings.setBaseUrl(_urlController.text.trim());
    await _settings.setModel(_modelController.text.trim());
    await _settings.setDefaultEffort(_effort);
    await _settings.setTemperature(_temperature);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
      );
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
          _TagBar(
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
                setState(() => _currentTab = index);
              },
              children: [
                _buildAppearanceTab(theme),
                _buildApiTab(theme),
                _buildParamsTab(theme),
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

  // ===== Tag 2：API 配置 =====
  Widget _buildApiTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _keyController,
          obscureText: _obscureKey,
          decoration: InputDecoration(
            labelText: 'API Key',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscureKey
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              onPressed: () {
                Haptics.light();
                setState(() => _obscureKey = !_obscureKey);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://aep.focusaim.com/focus_coding_local/v1',
            border: OutlineInputBorder(),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            ActionChip(
              label: const Text('公网 focusaim'),
              onPressed: () {
                Haptics.selection();
                setState(() =>
                    _urlController.text = SettingsService.defaultBaseUrl);
              },
            ),
            ActionChip(
              label: const Text('内网 vemic（更快）'),
              onPressed: () {
                Haptics.selection();
                setState(
                    () => _urlController.text = SettingsService.vemicBaseUrl);
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(
            labelText: '模型名',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
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

  // ===== Tag 4：说明 =====
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

/// 顶部 Tags 栏：横向滑动 + 选中高亮
class _TagBar extends StatelessWidget {
  const _TagBar({
    required this.tabs,
    required this.current,
    required this.onTap,
  });

  final List<String> tabs;
  final int current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final selected = index == current;
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onTap(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? colorScheme.primary
                    : colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                tabs[index],
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? colorScheme.onPrimary
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
