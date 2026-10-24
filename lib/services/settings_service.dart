import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置（shared_preferences KV 存储）
///
/// 继承 [ChangeNotifier]：UI 直接 watch 本类（如 MessageBubble 的
/// 快捷操作开关），setter 落盘后 notifyListeners 即时生效——
/// v2.6.1 前无通知，开关切换要杀进程重启才生效。
class SettingsService extends ChangeNotifier {
  SettingsService(this._prefs);

  final SharedPreferences _prefs;

  // ===== Keys =====
  static const _kApiKey = 'api_key';
  static const _kBaseUrl = 'base_url';
  static const _kModel = 'model';
  static const _kDefaultEffort = 'default_effort';
  static const _kTemperature = 'temperature';
  static const _kThemeId = 'theme_id';

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

  // ===== 快捷操作（消息横滑复制） =====
  // 开 = 助手左滑复制 + 用户右滑复制（v2.5.0 定版方案）；
  // 关 = 无横滑动作（长按复制保留）。默认开（升级用户行为不变）
  static const _kSwipeActions = 'swipe_actions';
  bool get swipeActions => _prefs.getBool(_kSwipeActions) ?? true;
  Future<void> setSwipeActions(bool v) async {
    if (v == swipeActions) return;
    await _prefs.setBool(_kSwipeActions, v);
    notifyListeners();
  }

  // ===== 最近使用的 Skill（LRU，最多 recentSkillLimit 个） =====
  // 存储键沿用 recent_agent_ids：v6 迁移后 Skill id 与旧 Agent id 一致，
  // 老用户的最近使用列表无缝延续
  static const _kRecentSkillIds = 'recent_agent_ids';
  static const recentSkillLimit = 3;

  /// 最近使用的 skillId 列表（index 0 = 最近使用）
  List<String> get recentSkillIds =>
      _prefs.getStringList(_kRecentSkillIds) ?? [];

  /// 记录一次 Skill 使用：提到最前，去重，截断到上限
  Future<void> touchRecentSkill(String skillId) async {
    final list = recentSkillIds..remove(skillId);
    list.insert(0, skillId);
    if (list.length > recentSkillLimit) {
      list.removeRange(recentSkillLimit, list.length);
    }
    await _prefs.setStringList(_kRecentSkillIds, list);
  }

  // ===== 会话草稿（I6：按会话 ID 存取输入框未发送内容） =====
  // key 前缀 + 会话 id；空闲态（新对话）用固定键 [idleDraftKey]。
  // LRU 上限防膨胀：超限时淘汰最久未写的草稿。
  static const _kDraftPrefix = 'draft_';
  static const _kDraftOrder = 'draft_order';
  static const draftLimit = 20;

  /// 空闲态（新对话）草稿的固定键
  static const idleDraftKey = '$_kDraftPrefix:idle';

  String _draftKey(String sessionId) => '$_kDraftPrefix$sessionId';

  /// 读会话草稿（无草稿返回空串）
  String getDraft(String sessionId) =>
      _prefs.getString(_draftKey(sessionId)) ?? '';

  /// 读空闲态草稿
  String get idleDraft => _prefs.getString(idleDraftKey) ?? '';

  /// 保存会话草稿（空文本 = 清除草稿），并记入 LRU 顺序
  Future<void> setDraft(String sessionId, String text) async {
    final key = _draftKey(sessionId);
    if (text.isEmpty) {
      await _prefs.remove(key);
      await _touchDraftOrder(sessionId, remove: true);
      return;
    }
    await _prefs.setString(key, text);
    await _touchDraftOrder(sessionId);
    await _evictDraftOverflow();
  }

  /// 保存空闲态草稿（空文本 = 清除）
  Future<void> setIdleDraft(String text) async {
    if (text.isEmpty) {
      await _prefs.remove(idleDraftKey);
      return;
    }
    await _prefs.setString(idleDraftKey, text);
  }

  /// 删除会话时同步清草稿
  Future<void> clearDraft(String sessionId) async {
    await _prefs.remove(_draftKey(sessionId));
    await _touchDraftOrder(sessionId, remove: true);
  }

  /// LRU 顺序表：最近写的会话 id 在最前
  Future<void> _touchDraftOrder(String sessionId,
      {bool remove = false}) async {
    final list = _prefs.getStringList(_kDraftOrder) ?? [];
    list.remove(sessionId);
    if (!remove) list.insert(0, sessionId);
    await _prefs.setStringList(_kDraftOrder, list);
  }

  /// 草稿超上限时淘汰最久未写的（只删内容，顺序表同步收缩）
  Future<void> _evictDraftOverflow() async {
    final list = _prefs.getStringList(_kDraftOrder) ?? [];
    if (list.length <= draftLimit) return;
    for (final id in list.sublist(draftLimit)) {
      await _prefs.remove(_draftKey(id));
    }
    await _prefs.setStringList(
        _kDraftOrder, list.sublist(0, draftLimit));
  }
}
