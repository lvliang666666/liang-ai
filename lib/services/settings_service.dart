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

  // ===== 自动记忆沉淀（M2：会话结束自动提取记忆入库） =====
  // 开 = 会话切走/退出聊天态时后台跑一次记忆提取（静默入库，记忆管理
  // 页可删）；关 = 只保留手动「记住xxx」与 memory_save 工具。默认开
  static const _kAutoMemory = 'auto_memory';
  bool get autoMemory => _prefs.getBool(_kAutoMemory) ?? true;
  Future<void> setAutoMemory(bool v) async {
    if (v == autoMemory) return;
    await _prefs.setBool(_kAutoMemory, v);
    notifyListeners();
  }

  // ===== 上下文自动压缩（F2：token 超水位线自动生成前情摘要） =====
  // 开 = 发送前检查水位，超线把早期历史压缩成四段式摘要（钉住消息豁免）；
  // 关 = 永不压缩（超长会话可能被网关拒绝）。默认开
  static const _kContextCompression = 'context_compression';
  bool get contextCompression =>
      _prefs.getBool(_kContextCompression) ?? true;
  Future<void> setContextCompression(bool v) async {
    if (v == contextCompression) return;
    await _prefs.setBool(_kContextCompression, v);
    notifyListeners();
  }

  // ===== 智能路由（F4：按消息内容自动选推理档位） =====
  // 开 = 每条消息发送前经 SmartRouter 规则决策 effort（max 触发词/
  //   短消息 low/默认 high），覆盖会话档位；关 = 用户手动选档不变。
  // 默认关（升级用户行为完全不变；手动档位仍可随时在 tags 切）
  static const _kSmartRouting = 'smart_routing';
  bool get smartRouting => _prefs.getBool(_kSmartRouting) ?? false;
  Future<void> setSmartRouting(bool v) async {
    if (v == smartRouting) return;
    await _prefs.setBool(_kSmartRouting, v);
    notifyListeners();
  }

  // ===== 后台生成保活（I13：前台服务 + WakeLock） =====
  // 开 = 生成期间启动 dataSync 前台服务（通知栏常驻提示）+ WakeLock，
  //   短时切后台 SSE 流不断；关 = 不启动服务（无通知打扰，但切后台
  //   可能断流，降级为 I10 断流续传）。默认开
  static const _kKeepaliveNotification = 'keepalive_notification';
  bool get keepaliveNotification =>
      _prefs.getBool(_kKeepaliveNotification) ?? true;
  Future<void> setKeepaliveNotification(bool v) async {
    if (v == keepaliveNotification) return;
    await _prefs.setBool(_kKeepaliveNotification, v);
    notifyListeners();
  }

  // ===== 情景记忆层（M4：会话结束生成摘要 + search_history 工具） =====
  // 开 = 会话切走/退出聊天态时后台生成「标题+摘要+关键词」入库，
  //   模型可经 search_history 工具检索历史会话；关 = 不生成不检索。
  // 默认开
  static const _kEpisodicMemory = 'episodic_memory';
  bool get episodicMemory => _prefs.getBool(_kEpisodicMemory) ?? true;
  Future<void> setEpisodicMemory(bool v) async {
    if (v == episodicMemory) return;
    await _prefs.setBool(_kEpisodicMemory, v);
    notifyListeners();
  }

  // ===== 晨间简报（P1：每天首次打开 App 生成个性化今日简报） =====
  // 开 = 跨天后首次打开自动生成简报（黄历/灵签/记忆/上周今天）并弹出；
  // 关 = 永不生成。默认开
  static const _kMorningBriefing = 'morning_briefing';
  bool get morningBriefing => _prefs.getBool(_kMorningBriefing) ?? true;
  Future<void> setMorningBriefing(bool v) async {
    if (v == morningBriefing) return;
    await _prefs.setBool(_kMorningBriefing, v);
    notifyListeners();
  }

  // ===== 剪贴板建议（F9：聚焦时检测剪贴板长文本浮出「帮你总结？」胶囊） =====
  // 开 = 输入框聚焦且剪贴板有 ≥200 字文本时提示；关 = 不检测不提示。
  // 默认开
  static const _kClipboardSuggestion = 'clipboard_suggestion';
  bool get clipboardSuggestion =>
      _prefs.getBool(_kClipboardSuggestion) ?? true;
  Future<void> setClipboardSuggestion(bool v) async {
    if (v == clipboardSuggestion) return;
    await _prefs.setBool(_kClipboardSuggestion, v);
    notifyListeners();
  }

  // 上次生成简报的日期（yyyy-MM-dd）；null = 从未生成过。
  // 「打开补算式」的核心状态：跨天即重新生成，当天内不重复打扰
  static const _kLastBriefingDate = 'last_briefing_date';
  String? get lastBriefingDate => _prefs.getString(_kLastBriefingDate);
  Future<void> setLastBriefingDate(String v) =>
      _prefs.setString(_kLastBriefingDate, v);

  // ===== 最近使用的 Agent（LRU，最多 recentAgentLimit 个） =====
  // 存储键沿用 recent_agent_ids：v6 迁移后 Agent id 与旧 Agent id 一致，
  // 老用户的最近使用列表无缝延续
  static const _kRecentAgentIds = 'recent_agent_ids';
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

  // ===== 斜杠命令自定义短语（I12：输入「/」唤起的快捷短语） =====
  // LRU 上限防膨胀；短语为纯文本，点选后整条填入输入框
  static const _kSlashPhrases = 'slash_phrases';
  static const slashPhraseLimit = 20;

  /// 自定义短语列表（index 0 = 最近使用）
  List<String> get slashPhrases =>
      _prefs.getStringList(_kSlashPhrases) ?? [];

  /// 添加短语：去重提到最前，超限淘汰最久未用
  Future<void> addSlashPhrase(String phrase) async {
    final trimmed = phrase.trim();
    if (trimmed.isEmpty) return;
    final list = slashPhrases..remove(trimmed);
    list.insert(0, trimmed);
    if (list.length > slashPhraseLimit) {
      list.removeRange(slashPhraseLimit, list.length);
    }
    await _prefs.setStringList(_kSlashPhrases, list);
    notifyListeners();
  }

  /// 删除短语（不存在时静默）
  Future<void> removeSlashPhrase(String phrase) async {
    final list = slashPhrases;
    if (!list.remove(phrase)) return;
    await _prefs.setStringList(_kSlashPhrases, list);
    notifyListeners();
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
