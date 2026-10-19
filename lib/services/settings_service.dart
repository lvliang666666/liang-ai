import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置（shared_preferences KV 存储）
class SettingsService {
  SettingsService(this._prefs);

  final SharedPreferences _prefs;

  // ===== Keys =====
  static const _kApiKey = 'api_key';
  static const _kBaseUrl = 'base_url';
  static const _kModel = 'model';
  static const _kDefaultEffort = 'default_effort';
  static const _kTemperature = 'temperature';
  static const _kThemeId = 'theme_id';
  static const _kRecentAgentIds = 'recent_agent_ids';

  // ===== 默认值 =====
  // API Key 不预填（凭据不入代码库）；首次使用请在设置页填入公司分配的 Key
  static const defaultApiKey = '';
  static const defaultBaseUrl =
      'https://aep.focusaim.com/focus_coding_local/v1';
  static const vemicBaseUrl = 'https://aep.vemic.com/focus_coding_local/v1';
  static const defaultModel = 'glm5.1';
  static const defaultEffort = 'max';
  static const defaultTemperature = 0.7;

  // ===== API Key =====
  String get apiKey => _prefs.getString(_kApiKey) ?? defaultApiKey;
  Future<void> setApiKey(String v) => _prefs.setString(_kApiKey, v);

  // ===== Base URL =====
  String get baseUrl => _prefs.getString(_kBaseUrl) ?? defaultBaseUrl;
  Future<void> setBaseUrl(String v) => _prefs.setString(_kBaseUrl, v);

  // ===== 模型名 =====
  String get model => _prefs.getString(_kModel) ?? defaultModel;
  Future<void> setModel(String v) => _prefs.setString(_kModel, v);

  // ===== 默认推理档位 =====
  String get defaultEffortValue =>
      _prefs.getString(_kDefaultEffort) ?? defaultEffort;
  Future<void> setDefaultEffort(String v) =>
      _prefs.setString(_kDefaultEffort, v);

  // ===== 温度 =====
  double get temperature => _prefs.getDouble(_kTemperature) ?? defaultTemperature;
  Future<void> setTemperature(double v) => _prefs.setDouble(_kTemperature, v);

  // ===== 主题风格 =====
  String? get themeIdRaw => _prefs.getString(_kThemeId);
  Future<void> setThemeId(String v) => _prefs.setString(_kThemeId, v);

  // ===== 最近使用的 Agent（LRU，最多 recentAgentLimit 个） =====
  static const recentAgentLimit = 3;

  /// 最近使用的 agentId 列表（index 0 = 最近使用）
  List<String> get recentAgentIds =>
      _prefs.getStringList(_kRecentAgentIds) ?? [];

  /// 记录一次 Agent 使用：提到最前，去重，截断到上限
  Future<void> touchRecentAgent(String agentId) async {
    final list = recentAgentIds..remove(agentId);
    list.insert(0, agentId);
    if (list.length > recentAgentLimit) {
      list.removeRange(recentAgentLimit, list.length);
    }
    await _prefs.setStringList(_kRecentAgentIds, list);
  }
}
