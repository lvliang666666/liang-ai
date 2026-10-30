import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/commitment.dart';
import '../models/message_attachment.dart';
import '../models/provider_profile.dart';
import '../models/agent.dart' as agent_model;
import '../providers/chat_provider.dart';
import '../providers/http_tool_provider.dart';
import '../providers/provider_provider.dart';
import '../providers/sessions_provider.dart';
import '../providers/agent_provider.dart';
import '../services/api_service.dart';
import '../services/card_forge_service.dart';
import '../services/commitment_service.dart';
import '../services/database_service.dart';
import '../services/memory_extraction_service.dart';
import '../services/morning_briefing_service.dart';
import '../services/session_summary_service.dart';
import '../services/memory_service.dart';
import '../services/settings_service.dart';
import '../services/share_receive_service.dart';
import '../services/screenshot_memory_service.dart';
import '../services/skill_variables.dart';
import '../services/widget_data_service.dart';
import '../services/tools/builtin_tools.dart';
import '../services/tools/http_tool_handler.dart';
import '../utils/haptics.dart';
import '../utils/transitions.dart';
import '../widgets/app_bottom_sheet.dart';
import '../widgets/app_toast.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/commitment_follow_up_sheet.dart';
import '../widgets/gesture_drawer.dart';
import '../widgets/home/chat_message_list.dart';
import '../widgets/home/home_input_bar.dart';
import '../widgets/home/message_outline_sheet.dart';
import '../widgets/home/new_chat_preset_sheet.dart';
import '../widgets/home/session_drawer_panel.dart';
import '../widgets/morning_briefing_sheet.dart';
import '../widgets/home/agent_picker_sheet.dart';
import '../widgets/skill_variables_sheet.dart';
import 'settings_page.dart';

/// 首页：DeepSeek 风格单页架构——主页即聊天页
///
/// 两种状态：
/// - 空闲态：问候语 + tags 行 + 输入框（发送时才创建会话）
/// - 聊天态：header 显示会话标题 + 消息列表 + 同一套输入区（tags 随会话）
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();

  /// 当前聊天区（I1 智能跟随在 ChatMessageList 内部自管理；
  /// GlobalKey 保留供未来宿主级滚动操作）
  final _chatAreaKey = GlobalKey<ChatMessageListState>();

  /// 抽屉批量管理模式开关（长按菜单「批量管理」触发）
  final ValueNotifier<bool> _drawerBatchMode = ValueNotifier(false);

  /// 正在播离场动画的会话 id（删除前先收缩淡出，动画完再真删）
  final Set<String> _removingSessionIds = {};

  // 聊天态：当前会话的 ChatProvider（null = 空闲态）
  ChatProvider? _chat;

  // 空闲态的预选状态（tags 行展示与切换）
  agent_model.Agent? _selectedAgent; // null = 默认助手
  (ProviderProfile, String)? _selectedModel; // null = 用默认供应商默认模型

  // F10 空闲态预选 Agent 的变量值（随首条消息传入新会话）
  Map<String, String> _selectedAgentVariables = const {};

  // 空闲态预选推理档位（effort tag 空闲态也显示）
  String _selectedEffort = 'max';

  // I4 编辑态：正在编辑重发的 user 消息（null = 非编辑态）
  ChatMessage? _editingMessage;

  // I5 引用态：被引用的 assistant 消息（null = 无引用）
  ChatMessage? _quotedMessage;

  // F9/F7 分享即问：系统分享接收服务 + 订阅句柄
  final ShareReceiveService _shareReceive = ShareReceiveService();
  StreamSubscription<SharePayload>? _shareSubscription;

  // F7 空闲态暂存的分享图片（聊天态直接进 ChatProvider 附件队列）
  final List<MessageAttachment> _idleShareAttachments = [];

  // P2 桌面小组件：会话变化 → 防抖推送数据到原生 widget
  WidgetDataPusher? _widgetPusher;
  VoidCallback? _sessionsListener;

  @override
  void initState() {
    super.initState();
    context.read<SessionsProvider>().loadSessions();
    // 启动即加载 Agent 列表：否则 tags 行的 Agent 图标在首次懒加载前显示兜底 emoji
    context.read<AgentProvider>().load();
    // F9/F7 分享即问：注册分享接收（冷启动兜底拉取 + 热启动推送），
    // 收到后按类型分发（fire-and-forget，不阻塞首帧）
    _shareSubscription = _shareReceive.stream.listen(_onSharedPayload);
    unawaited(_shareReceive.init());
    // P2 桌面小组件：订阅会话列表变化，防抖推送最近会话 + 简报行
    // （fire-and-forget；平台不可用静默降级）
    unawaited(_setupWidgetPusher());
    // P1 晨间简报：跨天后首次打开自动生成并弹出（fire-and-forget，
    // 生成完成才弹；开关关闭/当天已生成过则零操作）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeShowMorningBriefing();
    });
    // P3 承诺跟进：跨天首开扫描到期承诺，有则弹跟进 Sheet（排在晨报
    // 之后——两个弹层不叠加，晨报先弹，跟进 Sheet 等晨报关闭再弹）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeShowCommitmentFollowUp();
    });
    // 聚焦根治：键盘收起（ViewInsets 归零）时自动退出聚焦。
    // 场景：用户点输入框聚焦 → 点 tag 弹层（键盘收起）→ 弹层关闭后
    // FocusScope 会把焦点还给输入框并重新弹键盘——监听键盘收起主动
    // unfocus，保证「键盘收起 = 退出聚焦」，弹层关闭不再回弹。
    WidgetsBinding.instance.addObserver(_KeyboardDismissObserver(this));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_KeyboardDismissObserver(this));
    _shareSubscription?.cancel();
    _shareReceive.dispose();
    _teardownWidgetPusher();
    _inputController.dispose();
    _inputFocusNode.dispose();
    _drawerBatchMode.dispose();
    _chat?.dispose();
    _chat = null;
    super.dispose();
  }

  /// P2：初始化 widget 推送器（读 SharedPreferences → 订阅会话变化 → 首推）
  Future<void> _setupWidgetPusher() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final pusher = WidgetDataPusher(
        service: WidgetDataService(),
        prefs: prefs,
      );
      final sessions = context.read<SessionsProvider>();
      void listener() => pusher.onSessionsChanged(sessions.sessions);
      sessions.addListener(listener);
      setState(() {
        _widgetPusher = pusher;
        _sessionsListener = listener;
      });
      // 首推：不等防抖，widget 放上桌面即有数据
      await pusher.pushNow();
    } catch (_) {
      // SharedPreferences 不可用（测试环境）——widget 功能静默降级
    }
  }

  /// P2：移除会话监听并释放推送器
  void _teardownWidgetPusher() {
    final listener = _sessionsListener;
    if (listener != null) {
      context.read<SessionsProvider>().removeListener(listener);
    }
    _widgetPusher?.dispose();
    _widgetPusher = null;
    _sessionsListener = null;
  }

  /// F9/F7 分享即问：收到系统分享载荷 → 按类型分发。
  /// 文本预填输入框；图片进附件队列（聊天态）或暂存（空闲态随首条消息发出）；
  /// P2 link：widget deep link 路由（新对话/进会话/简报）
  void _onSharedPayload(SharePayload payload) {
    if (!mounted) return;
    switch (payload) {
      case ShareLinkPayload(:final link):
        _handleWidgetLink(link);
      case ShareTextPayload(:final text):
        final existing = _inputController.text;
        _inputController.text = existing.isEmpty ? text : '$existing\n$text';
        _inputController.selection = TextSelection.collapsed(
            offset: _inputController.text.length);
        showAppToast(context, '已填入分享内容，可直接发送或让 AI 处理');
      case ShareImagePayload(:final base64, :final mime):
        _onSharedImage(base64: base64, mime: mime);
    }
  }

  /// P2 桌面小组件 deep link 路由：
  /// - `liangai://new` → 新对话预设弹窗（与主页新建按钮同流程）
  /// - `liangai://chat/<id>` → 进入对应会话（会话已删则静默忽略）
  /// - `liangai://briefing` → 展示当天简报问候（无缓存静默忽略）
  Future<void> _handleWidgetLink(String link) async {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'liangai') return;
    switch (uri.host) {
      case 'new':
        await _newChat();
      case 'chat':
        final id = uri.path.replaceFirst('/', '');
        if (id.isEmpty) return;
        await _openChat(id);
      case 'briefing':
        final prefs = await SharedPreferences.getInstance();
        final today = DateTime.now();
        final dateKey = '${today.year}-${today.month.toString().padLeft(2, '0')}-'
            '${today.day.toString().padLeft(2, '0')}';
        final cached = prefs.getString('widgetBriefingDate');
        final text = prefs.getString('widgetBriefingText');
        if (!mounted) return;
        if (cached == dateKey && text != null && text.isNotEmpty) {
          // 缓存只有 greeting 一行（完整简报 sheet 需重建 MorningBriefing，
          // 成本高且跨天即失效）——widget 点击场景轻量展示即可
          showAppToast(context, text);
        }
    }
  }

  /// F7 截图视觉记忆：分享图片 → 附件队列 + 视觉理解描述（后台）。
  /// 描述生成不阻塞发送——用户可直接问「这张图讲了什么」，描述服务
  /// 同时把图片内容写进可搜索的描述文本（见 ScreenshotMemoryService）
  Future<void> _onSharedImage(
      {required String base64, required String mime}) async {
    final ext = mime.contains('jpeg') || mime.contains('jpg')
        ? 'jpg'
        : mime.contains('webp')
            ? 'webp'
            : mime.contains('gif')
                ? 'gif'
                : 'png';
    final attachment = MessageAttachment(
      type: AttachmentType.image,
      name: '分享图片_$ext',
      base64Data: base64,
    );
    final chat = _chat;
    if (chat != null) {
      final ok = chat.addAttachment(attachment);
      showAppToast(context,
          ok ? '已加入待发送附件' : '图片附件已达上限（3 张），未加入');
    } else {
      // 空闲态：暂存输入栏本地队列，随首条消息经 onSendIdle 传入新会话
      setState(() => _idleShareAttachments.add(attachment));
      showAppToast(context, '已暂存分享图片，发送消息时一并带上');
    }
    // 后台视觉理解：描述入 FTS 可搜索（fire-and-forget，不阻塞发送）。
    // 走当前供应商（聊天态）或默认供应商（空闲态）；供应商不支持视觉
    // 或生成失败静默——描述是增强不是门槛
    _describeScreenshotInBackground(base64, chat);
  }

  /// F7 后台描述生成：图片 → 视觉理解 → 描述文本入 FTS 索引。
  /// 开关 screenshotDescription 关闭 / 供应商无视觉能力 / 生成失败均静默
  void _describeScreenshotInBackground(String base64, ChatProvider? chat) {
    final settings = context.read<SettingsService>();
    if (!settings.screenshotDescription) return;
    final profile = chat?.profile ?? _defaultProfile();
    if (profile == null || !profile.capabilities.vision) return;
    final model = chat?.model ?? _defaultModel(profile);
    unawaited(() async {
      final api = ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
      try {
        final service = ScreenshotMemoryService(
          api: api,
          db: DatabaseService.instance,
        );
        final description = await service.describe(
          imageBase64: base64,
          profile: profile,
          model: model,
        );
        if (description == null || !mounted) return;
        await service.indexDescription(
          description: description,
          sessionId: chat?.session.id,
        );
        if (mounted) {
          showAppToast(context, '已生成截图描述，可在搜索中找回');
        }
      } finally {
        api.dispose();
      }
    }());
  }

  /// 默认供应商（空闲态分享图片时描述请求的目标）；无任何供应商返回 null
  ProviderProfile? _defaultProfile() {
    final profiles = context.read<ProviderProvider>().profiles;
    return profiles.isEmpty ? null : profiles.first;
  }

  /// 默认模型：供应商声明的默认模型
  String _defaultModel(ProviderProfile profile) {
    return profile.defaultModel.isEmpty ? 'glm5.1' : profile.defaultModel;
  }

  /// 导航前收起键盘，避免返回主页时自动弹键盘
  void _unfocus() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// M2 自动记忆沉淀 + M4 情景记忆 + P3 承诺提取：会话结束（切走/
  /// 退出聊天态）时后台提取
  ///
  /// fire-and-forget：不阻塞切换动画；各自开关关闭/正在流式/无
  /// user+assistant 交换时跳过。三个服务共用一次自建 ApiService
  /// （会话 provider 的 Key 从 DB 注水），与 ChatProvider 的连接池
  /// 互不影响；失败静默（后台任务不打扰）。
  void _extractMemoryInBackground(ChatProvider chat) {
    final settings = context.read<SettingsService>();
    if (chat.isStreaming) return;
    final doMemory = settings.autoMemory;
    final doSummary = settings.episodicMemory;
    final doCommitment = settings.commitmentFollowUp;
    if (!doMemory && !doSummary && !doCommitment) return;
    final messages = List<ChatMessage>.of(chat.messages);
    final profile = chat.profile;
    final model = chat.model;
    final agentName = chat.agent?.name;
    final sessionTitle = chat.session.title;
    final sessionId = chat.session.id;
    unawaited(() async {
      final api = ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
      try {
        if (doMemory) {
          await MemoryExtractionService(
            api: api,
            memory: MemoryService(database: DatabaseService.instance),
          ).extractAndSave(
            messages: messages,
            profile: profile,
            model: model,
            sourceAgent: agentName,
            sessionTitle: sessionTitle,
          );
        }
        if (doSummary) {
          await SessionSummaryService(
            api: api,
            database: DatabaseService.instance,
          ).summarizeAndSave(
            sessionId: sessionId,
            messages: messages,
            profile: profile,
            model: model,
            sessionTitle: sessionTitle,
          );
        }
        // P3 承诺提取：与记忆同源（对话文本），独立开关
        if (doCommitment) {
          await CommitmentService(
            api: api,
            db: DatabaseService.instance,
          ).extractAndSave(
            messages: messages,
            profile: profile,
            model: model,
            sessionId: sessionId,
          );
        }
      } finally {
        api.dispose();
      }
    }());
  }

  /// P1 晨间简报：跨天后首次打开 App 时生成并弹出
  ///
  /// 「打开补算式」：不做定时任务（Android 后台限制），跨天判断 =
  /// SettingsService.lastBriefingDate 与今天不等。生成走默认供应商
  /// （low 档低温，失败本地回退）；完成后先落日期再弹 sheet——
  /// 弹出期间崩溃/杀进程不会当天重复打扰。开关关闭则零操作。
  Future<void> _maybeShowMorningBriefing() async {
    final settings = context.read<SettingsService>();
    if (!settings.morningBriefing) return;
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    if (settings.lastBriefingDate == today) return;

    final db = DatabaseService.instance;
    final profiles = await db.getAllProviders();
    if (!mounted || profiles.isEmpty) return;
    final profile = profiles.first;
    final model =
        profile.defaultModel.isNotEmpty ? profile.defaultModel : 'glm5.1';

    final api = ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
    MorningBriefing? briefing;
    try {
      briefing = await MorningBriefingService(
        api: api,
        database: db,
      ).generate(profile: profile, model: model);
    } finally {
      api.dispose();
    }
    if (!mounted) return;
    await settings.setLastBriefingDate(today);
    // P2：简报 greeting 段缓存进 widget 可读键（桌面小组件简报行数据源）
    try {
      final prefs = await SharedPreferences.getInstance();
      await cacheBriefingForWidget(prefs, briefing);
      await _widgetPusher?.pushNow();
    } catch (_) {
      // prefs 不可用（测试环境）——widget 简报行静默降级
    }
    await showMorningBriefingSheet(context, briefing);
  }

  /// P3 承诺跟进：跨天首开扫描到期承诺，有则生成跟进语并弹 Sheet
  ///
  /// 防打扰生命线（roadmap 原文）：开关可关 + 每天最多弹一次
  /// （lastFollowUpDate 与晨报同款「打开补算式」状态）+ 点遮罩关闭
  /// = 剩余承诺保持待跟进（明天再问，不强制处理）。
  /// 跟进语生成走默认供应商（LLM 失败本地模板兜底）；无到期承诺零操作。
  Future<void> _maybeShowCommitmentFollowUp() async {
    final settings = context.read<SettingsService>();
    if (!settings.commitmentFollowUp) return;
    final now = DateTime.now();
    final today = CommitmentService.dateKey(now);
    if (settings.lastFollowUpDate == today) return;

    final db = DatabaseService.instance;
    final due = await CommitmentService(api: ApiService(
      baseUrl: 'unused',
      apiKey: 'unused',
    ), db: db).scanDue(now: now);
    if (!mounted || due.isEmpty) return;

    // 跟进语生成：默认供应商（失败本地模板兜底）；无供应商全走模板
    final profiles = await db.getAllProviders();
    ProviderProfile? profile;
    String? model;
    if (profiles.isNotEmpty) {
      profile = profiles.first;
      model =
          profile.defaultModel.isNotEmpty ? profile.defaultModel : 'glm5.1';
    }
    final api = profile == null
        ? null
        : ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
    List<Commitment> withFollowUps;
    try {
      withFollowUps = await CommitmentService(
        api: api ?? ApiService(baseUrl: 'unused', apiKey: 'unused'),
        db: db,
      ).generateFollowUps(
        due,
        profile: profile,
        model: model,
        now: now,
      );
    } finally {
      api?.dispose();
    }
    if (!mounted) return;
    // 先落日期再弹：弹出期间崩溃/杀进程不会当天重复打扰
    await settings.setLastFollowUpDate(today);
    final toContinue = await showCommitmentFollowUpSheet(context, withFollowUps);
    // 「继续聊」：跳回承诺来源会话（会话已删静默忽略）
    if (toContinue != null && mounted) {
      final sessionId = toContinue.sessionId;
      if (sessionId != null) {
        await _openChat(sessionId);
      }
    }
  }

  /// 按时段问候语
  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5) return '夜深了';
    if (hour < 11) return '早上好';
    if (hour < 13) return '中午好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  /// M5 对话炼金炉：把消息沉淀为知识卡片
  ///
  /// 提炼走会话同款供应商与模型（low 档低温，失败本地回退）；
  /// 成功 Toast 提示并可跳转卡片库。fire-and-forget：提炼期间用户
  /// 可继续操作，完成时 Toast 反馈。
  void _saveMessageAsCard(ChatMessage msg) {
    final chat = _chat;
    if (chat == null) return;
    Haptics.light();
    final profile = chat.profile;
    final model = chat.model;
    final sessionId = chat.session.id;
    unawaited(() async {
      final api = ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
      try {
        final card = await CardForgeService(
          api: api,
          db: DatabaseService.instance,
        ).forge(
          message: msg,
          profile: profile,
          model: model,
          sessionId: sessionId,
        );
        if (!mounted) return;
        showAppToast(context, '已沉淀卡片「${card.title}」');
      } catch (_) {
        if (!mounted) return;
        showAppToast(context, '沉淀失败，请重试');
      } finally {
        api.dispose();
      }
    }());
  }

  /// 打开即聊：发送首条消息时才创建会话，主页原地进入聊天态
  Future<void> _startChat(String text,
      {String? agentId,
      (ProviderProfile, String)? modelPick,
      List<MessageAttachment> attachments = const [],
      Map<String, String> agentVariables = const {}}) async {
    Haptics.light();
    _unfocus();

    // F7 空闲态暂存的分享图片并入首条消息附件（一次性，取后即清）
    final allAttachments = [...attachments, ..._idleShareAttachments];
    if (_idleShareAttachments.isNotEmpty) {
      setState(() => _idleShareAttachments.clear());
    }

    final settings = context.read<SettingsService>();
    // 记录最近使用（LRU），供下次选择页展示
    if (agentId != null) {
      await settings.touchRecentAgent(agentId);
      if (!mounted) return;
    }
    final sessions = context.read<SessionsProvider>();
    final session = await sessions.createSession(
      _selectedEffort, // 空闲态预选档位随会话创建
      agentId: agentId,
      providerId: modelPick?.$1.id,
      model: modelPick?.$2,
    );
    if (!mounted) return;

    // 主页原地进入聊天态并自动发送首条消息（附件随首条消息发出）
    await _enterChat(session,
        initialMessage: text,
        initialAttachments: allAttachments,
        initialAgentVariables: agentVariables);
  }

  /// 进入聊天态：构建 ChatProvider 并加载消息
  ///
  /// 切换会话时旧内容保持显示（不清空），数据在后台加载，就绪后
  /// 一次性原子替换——加载时间被藏掉，UI 无空档无闪页。
  /// [_switchToken] 递增防快速连点：只有最后一次切换的结果生效，
  /// 过期结果直接丢弃（provider 已 dispose）。
  int _switchToken = 0;

  Future<void> _enterChat(ChatSession session,
      {String? initialMessage,
      List<MessageAttachment> initialAttachments = const [],
      Map<String, String> initialAgentVariables = const {}}) async {
    final token = ++_switchToken;
    final isSwitch = _chat != null && _chat!.session.id != session.id;

    // 切换会话：旧 provider 延后到新数据就绪再 dispose（旧内容保持
    // 显示）；新建会话（_startChat）无旧态，直接走
    final old = isSwitch ? _chat : null;

    // 切走前把输入框内容存为旧会话草稿（I6 会话独立草稿）
    if (old != null) {
      final draft = _inputController.text;
      final settings = context.read<SettingsService>();
      if (draft.trim().isEmpty) {
        await settings.clearDraft(old.session.id);
      } else {
        await settings.setDraft(old.session.id, draft);
      }
      _inputController.clear();
    }

    final db = DatabaseService.instance;
    final s = await db.getSession(session.id);
    final profiles = await db.getAllProviders();
    if (!mounted || token != _switchToken) {
      return;
    }
    if (s == null || profiles.isEmpty) return;

    ProviderProfile profile;
    if (s.providerId != null) {
      profile = profiles.firstWhere(
        (p) => p.id == s.providerId,
        orElse: () => profiles.first,
      );
    } else {
      profile = profiles.first;
    }

    final agent = context.read<AgentProvider>().byId(s.agentId);
    // T1：内置工具 + 用户自定义 HTTP 工具合并进目录（Agent 白名单统一纳管）
    final httpTools = context.read<HttpToolProvider>().enabledTools;
    final chat = ChatProvider(
      database: db,
      api: ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey),
      session: s,
      profile: profile,
      model: s.model?.isNotEmpty == true ? s.model! : profile.defaultModel,
      agent: agent,
      memory: MemoryService(database: db),
      // F4 智能路由开关（设置页控制；关 = 手动档位行为不变）
      smartRouting: context.read<SettingsService>().smartRouting,
      // I13 后台保活通知开关（设置页控制；关 = 不启动前台服务）
      keepaliveNotification:
          context.read<SettingsService>().keepaliveNotification,
      // T2 run_skill 链式编排：Skill 查库服务（子 loop 委派桥）
      agentService: context.read<AgentProvider>().service,
      toolCatalog: [
        ...builtinTools,
        for (final t in httpTools) HttpToolHandler(t),
      ],
    );
    // 消息先加载完再进聊天态：避免 setState 后首帧渲染空列表
    // （转圈）→ 消息到达 → 整列表重建，两帧重活叠一起掉帧
    await chat.loadMessages();
    if (!mounted || token != _switchToken) {
      // 过期结果（期间用户又点了别的会话）：直接丢弃
      chat.dispose();
      return;
    }
    old?.dispose();
    setState(() {
      _chat = chat;
    });
    // F10：空闲态预选的 Agent 变量带入新会话（含人格预设名回显）
    if (initialAgentVariables.isNotEmpty && agent != null) {
      chat.setAgentVariables(initialAgentVariables);
      final personaName = agent.personas
          .where((p) => initialAgentVariables['persona'] == p.value)
          .map((p) => p.name)
          .firstOrNull;
      chat.restorePersonaName(personaName);
    }
    // M2 自动记忆沉淀：旧会话结束，后台提取记忆（fire-and-forget）
    if (old != null) {
      _extractMemoryInBackground(old);
    }

    // 恢复目标会话草稿（静默恢复：输入框里看得见，无需弹提示）
    final draft = context.read<SettingsService>().getDraft(session.id);
    if (draft.isNotEmpty && mounted) {
      _inputController.text = draft;
      _inputController.selection =
          TextSelection.collapsed(offset: draft.length);
    }

    // 自动发送首条消息（等首帧完成）；附件先入队再发送
    final initial = initialMessage ?? '';
    if (initial.isNotEmpty || initialAttachments.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final att in initialAttachments) {
          chat.addAttachment(att);
        }
        chat.sendMessage(initial);
      });
    }
  }

  /// 新增对话：预设弹窗（预选 agent/model）→ 仅点「开始新对话」才退出当前聊天态
  ///
  /// 两态统一：都直接弹预设弹窗（聊天态初始值取当前会话配置，新对话从
  /// 当前设置延续）；点遮罩关闭/取消 = 回到点新建之前的状态，
  /// 不退出聊天、不改预选。
  Future<void> _newChat() async {
    Haptics.light();
    _unfocus();

    // 预设交互页：预选本次新对话的 agent / model（力度不加，走 tags 预选）
    final agentsProvider = context.read<AgentProvider>();
    if (!agentsProvider.loaded) await agentsProvider.load();
    if (!mounted) return;
    final providersProvider = context.read<ProviderProvider>();
    if (!providersProvider.loaded) await providersProvider.load();
    if (!mounted) return;

    final chat = _chat;
    final preset = await showModalBottomSheet<(agent_model.Agent?, (ProviderProfile, String)?)>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => NewChatPresetSheet(
        agents: agentsProvider,
        providers: providersProvider,
        recentIds: context.read<SettingsService>().recentAgentIds,
        initialAgent: chat?.agent ?? _selectedAgent,
        initialModel: chat != null ? (chat.profile, chat.model) : _selectedModel,
      ),
    );
    // 点遮罩关闭/取消：什么都不做，保持点新建之前的状态
    if (preset == null || !mounted) return;

    // 仅确认「开始新对话」才应用预选并退出当前聊天态
    final (agent, model) = preset;
    setState(() {
      _selectedAgent = agent?.id == '__default__' ? null : agent;
      _selectedModel = model;
    });
    if (_selectedAgent != null) {
      await context.read<SettingsService>().touchRecentAgent(_selectedAgent!.id);
      if (!mounted) return;
    }

    final current = _chat;
    if (current != null) {
      if (current.isStreaming) current.stopGeneration();
      // 退出聊天态前存当前会话草稿（I6 会话独立草稿）
      final draft = _inputController.text;
      final settings = context.read<SettingsService>();
      if (draft.trim().isEmpty) {
        await settings.clearDraft(current.session.id);
      } else {
        await settings.setDraft(current.session.id, draft);
      }
      _inputController.clear();
      // 先置空再 dispose：避免 dispose 后 provider 仍被 UI 引用
      setState(() {
        _chat = null;
      });
      // M2 自动记忆沉淀：退出聊天态，后台提取记忆（fire-and-forget）
      _extractMemoryInBackground(current);
      current.dispose();
    }
    // 空闲态恢复新对话草稿（上次在主页打了字没发出去的场景）
    final idleDraft = context.read<SettingsService>().idleDraft;
    if (idleDraft.isNotEmpty && mounted) {
      _inputController.text = idleDraft;
      _inputController.selection =
          TextSelection.collapsed(offset: idleDraft.length);
    }
    context.read<SessionsProvider>().refresh();
  }

  /// 抽屉点历史会话：主页切换到该会话（聊天态）
  ///
  /// 旧内容保持显示，_enterChat 后台加载数据，就绪后原子替换 +
  /// 滑入过渡（_ChatArea 外层 AnimatedSwitcher）——无空档无闪页。
  /// 点同一个会话 = 忽略（避免无意义的重载闪烁）。
  Future<void> _openChat(String id) async {
    Haptics.light();
    _unfocus();
    if (_chat?.session.id == id) return;
    final sessions = context.read<SessionsProvider>();
    final session = sessions.sessions.where((s) => s.id == id).firstOrNull;
    if (session == null) return;
    await _enterChat(session);
  }

  /// 删除当前聊天态的会话（header 删除按钮）：退出聊天态
  Future<void> _deleteCurrentChat() async {
    final chat = _chat;
    if (chat == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: const Text('删除后聊天记录无法恢复，确定删除吗？'),
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
    if (confirmed != true || !mounted) return;
    if (chat.isStreaming) chat.stopGeneration();
    await context.read<SessionsProvider>().deleteSession(chat.session.id);
    // 会话已删，草稿一并清（I6）
    await context.read<SettingsService>().clearDraft(chat.session.id);
    if (!mounted) return;
    setState(() => _chat = null);
    chat.dispose();
  }

  // ===== I4 编辑重发 / I5 引用追问 =====

  /// 进入编辑态：输入框预填原文并聚焦（光标在末尾）
  void _enterEditMode(ChatMessage message) {
    Haptics.light();
    _exitQuoteMode(); // 编辑与引用互斥
    setState(() {
      _editingMessage = message;
      _inputController.text = message.content;
      _inputController.selection =
          TextSelection.collapsed(offset: message.content.length);
    });
    _inputFocusNode.requestFocus();
  }

  /// 退出编辑态：清空输入框恢复原状
  void _exitEditMode() {
    setState(() {
      _editingMessage = null;
      _inputController.clear();
    });
  }

  /// 进入引用态：输入框上方显示引用条
  void _enterQuoteMode(ChatMessage message) {
    Haptics.light();
    setState(() => _quotedMessage = message);
    _inputFocusNode.requestFocus();
  }

  /// 退出引用态
  void _exitQuoteMode() {
    if (_quotedMessage == null) return;
    setState(() => _quotedMessage = null);
  }


  Future<void> _renameSession(BuildContext context, String id, String current) async {
    final controller = TextEditingController(text: current);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(hintText: '会话名称'),
        ),
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
              Navigator.pop(context, controller.text.trim());
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newTitle != null && newTitle.isNotEmpty && newTitle != current) {
      if (context.mounted) {
        context.read<SessionsProvider>().renameSession(id, newTitle);
      }
    }
  }

  Future<void> _deleteSession(BuildContext context, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: const Text('删除后聊天记录无法恢复，确定删除吗？'),
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
      await _removeSessionWithAnimation(context, id);
    }
  }

  /// 带离场动画的删除：卡片先收缩淡出（200ms），动画完再真删——
  /// 其余卡片随列表重建平滑上移补位
  Future<void> _removeSessionWithAnimation(
      BuildContext context, String id) async {
    setState(() => _removingSessionIds.add(id));
    await Future.delayed(const Duration(milliseconds: 200));
    if (!context.mounted) {
      _removingSessionIds.remove(id);
      return;
    }
    await context.read<SessionsProvider>().deleteSession(id);
    // 会话已删，草稿一并清（I6）
    await context.read<SettingsService>().clearDraft(id);
    if (mounted) setState(() => _removingSessionIds.remove(id));
  }

  /// 长按会话卡片：锚点菜单栏（置顶/重命名/删除/批量管理）
  ///
  /// [pressPosition] = 长按点的全局坐标，菜单锚定在该处弹出（微信/桌面右键菜单风格）
  Future<void> _showSessionActions(
      BuildContext context, String id, String title, Offset pressPosition) async {
    Haptics.medium();
    final pinned =
        context.read<SessionsProvider>().sessions.firstWhere((s) => s.id == id).pinned;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final box = overlay.size;
    // 菜单估算尺寸：4 项（44 高）+ divider ≈ 190 高，宽约 160
    const menuWidth = 160.0;
    const menuHeight = 190.0;
    // 锚定长按点，超出屏幕右/下边界时向内收
    var left = pressPosition.dx;
    var top = pressPosition.dy;
    if (left + menuWidth > box.width) left = box.width - menuWidth - 8;
    if (top + menuHeight > box.height) top = box.height - menuHeight - 8;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        left, top, box.width - left - menuWidth, box.height - top - menuHeight,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem(
          value: 'pin',
          height: 44,
          child: Row(
            children: [
              Icon(
                pinned ? Icons.push_pin_outlined : Icons.push_pin,
                size: 20,
                color: pinned ? Theme.of(context).colorScheme.primary : null,
              ),
              const SizedBox(width: 12),
              Text(pinned ? '取消置顶' : '置顶'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'rename',
          height: 44,
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 20),
              SizedBox(width: 12),
              Text('重命名'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          height: 44,
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 20),
              SizedBox(width: 12),
              Text('删除'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'batch',
          height: 44,
          child: Row(
            children: [
              Icon(Icons.checklist, size: 20),
              SizedBox(width: 12),
              Text('批量管理'),
            ],
          ),
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    if (action == 'pin') {
      Haptics.light();
      await context.read<SessionsProvider>().setSessionPinned(id, !pinned);
      if (context.mounted) {
        showAppToast(context, pinned ? '已取消置顶' : '已置顶，会话将保持在列表顶部');
      }
    } else if (action == 'rename') {
      _renameSession(context, id, title);
    } else if (action == 'delete') {
      _deleteSession(context, id);
    } else if (action == 'batch') {
      _openBatchMode();
    }
  }

  /// 抽屉进入批量管理模式（多选删除）
  void _openBatchMode() {
    _openDrawer();
    // 抽屉内部状态切换到多选：通过 drawerKey 通知
    _drawerBatchMode.value = true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = context.watch<SessionsProvider>();
    final agentsProvider = context.watch<AgentProvider>();

    final allSessions = sessions.sessions;

    return Scaffold(
      key: _scaffoldKey,
      // 手势跟手抽屉：拖多少走多少 + 速度甩动（替换内置 Drawer）
      body: GestureDrawer(
        key: _drawerKey,
        drawer: SessionDrawerPanel(
          sessions: allSessions,
          agentsProvider: agentsProvider,
          loaded: sessions.loaded,
          batchMode: _drawerBatchMode,
          removingIds: _removingSessionIds,
          onClose: _closeDrawer,
          onDeleteSelected: (ids) async {
            // 先整体播离场动画（卡片收缩淡出），再逐个真删
            setState(() => _removingSessionIds.addAll(ids));
            await Future.delayed(const Duration(milliseconds: 200));
            if (!mounted) {
              _removingSessionIds.removeAll(ids);
              return;
            }
            final provider = this.context.read<SessionsProvider>();
            final settings = this.context.read<SettingsService>();
            for (final id in ids) {
              // 当前聊天态会话被删时退出聊天态
              if (_chat?.session.id == id) {
                final chat = _chat!;
                setState(() => _chat = null);
                chat.dispose();
              }
              await provider.deleteSession(id);
              // 会话已删，草稿一并清（I6）
              await settings.clearDraft(id);
            }
            if (mounted) setState(() => _removingSessionIds.removeAll(ids));
          },
          onOpenChat: (id) async {
            // 先等抽屉关完再切会话：_enterChat 的 DB 读取 + 整列表
            // Markdown 构建是重活，与关闭动画同帧会掉帧
            await _closeDrawerAndWait();
            if (!mounted) return;
            _openChat(id);
          },
          // I7 全文搜索命中：切到命中会话后滚动定位 + 高亮
          onOpenMessage: (hit, query) async {
            await _closeDrawerAndWait();
            if (!mounted) return;
            if (_chat?.session.id != hit.sessionId) {
              await _openChat(hit.sessionId);
              if (!mounted) return;
            }
            // 切会话后列表已就绪（_enterChat 原子替换后才返回）；
            // 同会话直接定位。等一帧让列表完成首次布局再定位
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _chatAreaKey.currentState
                  ?.scrollToMessage(hit.id, highlight: query);
            });
          },
          onOpenSettings: () {
            _closeDrawer();
            Haptics.light();
            _unfocus();
            Navigator.push(context, slideUpRoute(const SettingsPage()));
          },
          onShowActions: (ctx, id, title, pos) =>
              _showSessionActions(ctx, id, title, pos),
        ),
        // 圆形新对话按钮已移除：主页即聊天入口，历史对话走抽屉
        child: !sessions.loaded
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    // ===== header：抽屉入口 + 会话标题（聊天态）+ 新增对话 =====
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.menu),
                            tooltip: '会话列表',
                            onPressed: () {
                              Haptics.light();
                              _openDrawer();
                            },
                          ),
                          // 聊天态：header 显示会话标题（I8 点击弹消息大纲）
                          Expanded(
                            child: _chat != null
                                ? Tooltip(
                                    message: '消息大纲',
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: _showMessageOutline,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 6),
                                        child: Text(
                                          _chat!.session.title,
                                          textAlign: TextAlign.center,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.titleMedium,
                                        ),
                                      ),
                                    ),
                                  )
                                : const SizedBox(),
                          ),
                          // 右上角：新增对话（聊天态确认后退出回空闲态）
                          IconButton(
                            icon: const Icon(Icons.add),
                            tooltip: '新对话',
                            onPressed: _newChat,
                          ),
                        ],
                      ),
                    ),
                    // ===== 主体：空闲态问候语 / 聊天态消息列表 =====
                    // AnimatedSwitcher：切换会话时新内容从右轻滑入+淡入，
                    // 旧内容淡出（key 绑定会话 id，同会话重建不触发）。
                    // 空闲态问候语与聊天态之间切换同样过渡，无闪页
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) =>
                            FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0.04, 0),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: _chat == null
                            ? Center(
                                key: ValueKey('greeting'),
                                child: Text(
                                  '${_greeting()}，\n想聊点什么？',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.3,
                                  ),
                                ),
                              )
                            : RepaintBoundary(
                                // 隔离聊天区重绘：流式打字机逐帧重绘若向上
                                // 传播会重录主页大层，拖拽抽屉时掉帧
                                child: ChatMessageList(
                                  key: _chatAreaKey,
                                  chatKey: ValueKey(_chat!.session.id),
                                  chat: _chat!,
                                  onDelete: _deleteCurrentChat,
                                  // I4 编辑重发 / I5 引用追问 / I3 重答入口
                                  onEditMessage: _enterEditMode,
                                  onQuoteMessage: _enterQuoteMode,
                                  onRegenerateMessage: (msg) {
                                    Haptics.light();
                                    _chat?.regenerateFrom(msg);
                                  },
                                  // M5 沉淀为卡片入口
                                  onSaveAsCard: _saveMessageAsCard,
                                  // F6 同问双答「用这个继续」入口
                                  onChooseDualMessage: _chooseDualForHome,
                                  // F8 引用溯源：引用 chips 点击查 doc_chunks 原文
                                  resolveChunk: (docName, page) async {
                                    final db = DatabaseService.instance;
                                    final names = await db.getDocNames(
                                        _chat!.session.id);
                                    if (!names.contains(docName)) return null;
                                    final hits = await db.searchDocChunks(
                                        _chat!.session.id, docName,
                                        docName: docName, limit: 50);
                                    // 同页可能多块：拼合返回（原文 Sheet 展示整页）
                                    final samePage = hits
                                        .where((c) => c.page == page)
                                        .toList();
                                    if (samePage.isEmpty) return null;
                                    return samePage.first;
                                  },
                                ),
                              ),
                      ),
                    ),
                    // ===== 底部：tags 行 + 输入框（空闲态/聊天态共用） =====
                    // RepaintBoundary 隔离输入栏重绘：光标每 500ms 闪烁
                    // 重绘若向上传播，会重录主页大层（含聊天列表）——
                    // 拖拽抽屉时周期性掉帧的元凶
                    RepaintBoundary(
                      child: HomeInputBar(
                        controller: _inputController,
                        focusNode: _inputFocusNode,
                        chat: _chat,
                        selectedAgent: _selectedAgent,
                        selectedModel: _selectedModel,
                        selectedEffort: _selectedEffort,
                        onSendIdle: _startChat,
                        onPickAgent: _pickAgentForHome,
                        onPickModel: _pickModelForHome,
                        onPickEffort: _pickEffortForHome,
                        // F6 同问双答：双答 tag 点击弹对侧供应商选择
                        onPickDual: _pickDualForHome,
                        // I4 编辑态 / I5 引用态
                        editingMessage: _editingMessage,
                        onCancelEdit: _exitEditMode,
                        quotedMessage: _quotedMessage,
                        onCancelQuote: _exitQuoteMode,
                        // I9 胶囊行收纳：聊天态随消息列表滚动方向收起/展开
                        capsuleCollapsed:
                            _chatAreaKey.currentState?.capsuleCollapsed,
                        // F10 空闲态预选 Agent 的变量值（随首条消息传入）
                        agentVariables: _chat == null
                            ? _selectedAgentVariables
                            : null,
                        // F10 空闲态长按 agent tag 重开配置表单的回传暂存
                        onIdleAgentVariables: _chat == null
                            ? (values) => setState(
                                () => _selectedAgentVariables = values)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  /// 手势抽屉开合（按钮触发 / 抽屉内回调关闭）
  final GlobalKey<GestureDrawerState> _drawerKey =
      GlobalKey<GestureDrawerState>();

  void _openDrawer() => _drawerKey.currentState?.open();

  /// 关抽屉并等动画走完（600ms 兜底：拖拽中调用动画不推进，Future
  /// 永不完成，不能裸 await）。重活（切会话的列表构建）放在动画后，
  /// 避免与关闭动画抢主线程造成掉帧
  Future<void> _closeDrawerAndWait() async {
    final closing = _drawerKey.currentState?.close();
    if (closing == null) return;
    await closing.timeout(const Duration(milliseconds: 600),
        onTimeout: () {});
  }

  void _closeDrawer() => _drawerKey.currentState?.close();

  /// effort tag：空闲态改预选档位 / 聊天态改当前会话档位
  Future<void> _pickEffortForHome() async {
    final chat = _chat;
    final current = chat?.session.effort ?? _selectedEffort;
    final selected = await showEffortPicker(context, current);
    if (selected == null || selected == current) return;
    if (chat != null) {
      await chat.setEffort(selected);
    } else {
      setState(() => _selectedEffort = selected);
    }
  }

  /// I8 消息大纲：点击 header 会话标题弹出目录浮层
  ///
  /// 以每条 user 提问为目录项，点击条目关闭浮层并滚动定位到该消息
  /// （复用 I7 的 scrollToMessage 管线：reverse 列表定位 + 临时高亮）。
  /// 空会话（无提问）不弹浮层。
  Future<void> _showMessageOutline() async {
    final chat = _chat;
    if (chat == null) return;
    final entries = MessageOutlineSheet.outlineEntries(chat.displayMessages);
    if (entries.isEmpty) {
      Haptics.light();
      showAppToast(context, '还没有提问，发送第一条消息后可查看大纲');
      return;
    }
    Haptics.light();
    final selected = await showMessageOutlineSheet(
      context,
      chat.displayMessages,
    );
    if (selected == null || !mounted) return;
    // 等浮层关闭动画走完再定位，避免同帧布局竞争
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _chatAreaKey.currentState?.scrollToMessage(selected.id);
    });
  }

  /// 主页 agent tag：空闲态改预选 / 聊天态改当前会话 Agent
  ///
  /// F10：选中的 Agent 声明了自定义变量或人格预设时，接着弹变量
  /// 填写表单（预填当前值）；点遮罩关闭表单 = 取消本次切换（Agent
  /// 保持原样——填了一半的配置不该生效）。
  Future<void> _pickAgentForHome() async {
    Haptics.light();
    // 打开面板前收起键盘（需求：点「+」/tag 后键盘先收起，面板再滑出）
    FocusManager.instance.primaryFocus?.unfocus();
    final agents = context.read<AgentProvider>();
    if (!agents.loaded) await agents.load();
    if (!mounted) return;

    // 聊天态：当前会话的 Agent 为选中项
    final chat = _chat;
    final currentId = chat != null ? chat.agent?.id : _selectedAgent?.id;

    final result = await showAppBottomSheet<agent_model.Agent?>(
      context: context,
      builder: (context) => AgentPickerSheet(
        agents: agents,
        recentIds: context.read<SettingsService>().recentAgentIds,
        includeDefault: true,
        selectedId: currentId,
        onSelected: (s) => Navigator.pop(context, s),
      ),
    );
    if (result == null || !mounted) return; // 点遮罩关闭不改动
    // 哨兵 Agent（id='__default__'）= 默认助手 = null
    final picked = result.id == '__default__' ? null : result;

    // F10：需要变量/预设的 Agent 先弹配置表单（取消 = 放弃切换）
    Map<String, String>? variables;
    if (picked != null &&
        (picked.customVariables.isNotEmpty || picked.personas.isNotEmpty)) {
      variables = await showSkillVariablesSheet(
        context,
        agent: picked,
        initial: chat?.agentVariables ?? _selectedAgentVariables,
      );
      if (variables == null || !mounted) return; // 表单取消：不切换
    }

    if (chat != null) {
      await chat.setAgent(picked, variables: variables);
      // 恢复预设名回显（变量 map 里 persona 值反查预设名）
      if (picked != null) {
        final personaName = picked.personas
            .where((p) => variables?['persona'] == p.value)
            .map((p) => p.name)
            .firstOrNull;
        chat.restorePersonaName(personaName);
      }
      if (mounted) context.read<SessionsProvider>().refresh();
    } else {
      setState(() {
        _selectedAgent = picked;
        _selectedAgentVariables = variables ?? const {};
      });
    }
  }

  /// 主页 model tag：空闲态改预选 / 聊天态切当前会话供应商
  Future<void> _pickModelForHome() async {
    Haptics.light();
    final providersProvider = context.read<ProviderProvider>();
    if (!providersProvider.loaded) await providersProvider.load();
    if (!mounted) return;

    final chat = _chat;

    final selected = await showModalBottomSheet<(ProviderProfile, String)>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child:
                  Text('切换模型', style: Theme.of(context).textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in providersProvider.profiles) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                      child: Text(
                        p.name,
                        style:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                ),
                      ),
                    ),
                    if (p.defaultModel.isNotEmpty)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.model_training, size: 20),
                        title: Text(p.defaultModel),
                        trailing: currentModelLabel == p.defaultModel &&
                                (chat?.profile.id ?? _selectedModel?.$1.id) ==
                                    p.id
                            ? Icon(Icons.check_circle,
                                color:
                                    Theme.of(context).colorScheme.primary)
                            : null,
                        onTap: () =>
                            Navigator.pop(context, (p, p.defaultModel)),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (chat != null) {
      final ok = await chat.switchProvider(selected.$1, selected.$2);
      if (mounted && !ok) {
        showAppToast(context, '生成进行中，无法切换模型');
      }
    } else {
      setState(() => _selectedModel = selected);
    }
  }

  /// F6 同问双答：双答 tag 点击 → 选对侧供应商 → 设一次性双答目标
  ///
  /// 下一条消息经 sendDualMessage 并行发给当前供应商与对侧，双气泡
  /// 对照。目标一次性消费：发送后 tag 回到「双答」，再点再选。
  Future<void> _pickDualForHome() async {
    Haptics.light();
    _unfocus();
    final chat = _chat;
    if (chat == null) return;
    final providersProvider = context.read<ProviderProvider>();
    if (!providersProvider.loaded) await providersProvider.load();
    if (!mounted) return;

    final selected = await showModalBottomSheet<(ProviderProfile, String)>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('同问双答 · 选择对照方',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '下一条消息将同时发给「${chat.profile.name} · ${chat.model}」'
                    '与所选方，双气泡对照后点选其一继续',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in providersProvider.profiles) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                      child: Text(
                        p.name,
                        style:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                ),
                      ),
                    ),
                    if (p.defaultModel.isNotEmpty)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.compare_arrows, size: 20),
                        title: Text(p.defaultModel),
                        // 当前会话供应商 = 主侧，列表里仍可选（同模型
                        // 双采样对照），不置灰
                        onTap: () =>
                            Navigator.pop(context, (p, p.defaultModel)),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await chat.setDualTarget(selected.$1, selected.$2);
    if (mounted) {
      showAppToast(context,
          '已设对照方：${selected.$1.name} · ${selected.$2}，发送即双答');
    }
  }

  /// F6 同问双答「用这个继续」：点选一侧回答，姊妹删除、会话回单线
  ///
  /// chooseDual 返回切换目标（选中侧来源 ≠ 当前供应商时非空）——
  /// 复用 switchProvider 管线切换，后续对话延续所选供应商。
  Future<void> _chooseDualForHome(ChatMessage msg) async {
    Haptics.light();
    final chat = _chat;
    if (chat == null) return;
    final switchTo = await chat.chooseDual(msg);
    if (!mounted) return;
    if (switchTo != null) {
      final ok = await chat.switchProvider(switchTo.$1, switchTo.$2);
      if (mounted && !ok) {
        showAppToast(context, '已保留该回答，但切换供应商失败（生成中）');
      }
    }
  }

  /// 当前模型显示名（空闲态预选 / 聊天态会话模型）
  String get currentModelLabel =>
      _chat?.model ?? _selectedModel?.$2 ?? '默认模型';
}

/// 键盘收起观察者：ViewInsets.bottom 归零（键盘收起）时退出输入框聚焦
///
/// 聚焦规则（用户明确）：
/// - 点击输入框 → 聚焦弹键盘，输入中保持聚焦（持续输入）
/// - 键盘收起（点弹层/点空白/系统返回）→ 自动退出聚焦，
///   弹层关闭后 FocusScope 不再把焦点还给输入框（不再回弹键盘）
class _KeyboardDismissObserver extends WidgetsBindingObserver {
  _KeyboardDismissObserver(this._state);

  final _HomePageState _state;
  double _lastBottomInset = 0;

  @override
  void didChangeMetrics() {
    final inset = _state._inputFocusNode.context == null
        ? 0.0
        : (View.of(_state._inputFocusNode.context!).viewInsets.bottom);
    // 键盘从弹出变为收起：退出聚焦
    if (_lastBottomInset > 0 && inset == 0) {
      _state._inputFocusNode.unfocus();
    }
    _lastBottomInset = inset;
  }
}
