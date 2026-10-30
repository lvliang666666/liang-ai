import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/context_summary.dart';
import '../models/doc_chunk.dart';
import '../models/message_attachment.dart';
import '../models/provider_profile.dart';
import '../models/agent.dart';
import '../models/tool_call.dart';
import '../services/agent_service.dart';
import '../services/api_service.dart';
import '../services/context_summary_service.dart';
import '../services/database_service.dart';
import '../services/document_index_service.dart';
import '../services/generation_keepalive.dart';
import '../services/memory_service.dart';
import '../services/smart_router.dart';
import '../services/sse_parser.dart';
import '../services/tool_registry.dart';
import '../services/tools/builtin_tools.dart';
import '../services/tools/run_skill_tool.dart';

/// 聊天流式状态
enum ChatStatus { idle, thinking, answering, toolCalling, error }

/// 聊天页状态：消息列表 + 流式状态机 + agentic loop
class ChatProvider extends ChangeNotifier {
  ChatProvider({
    required DatabaseService database,
    required ApiService api,
    required ChatSession session,
    required ProviderProfile profile,
    required String model,
    Agent? agent,
    List<ToolHandler> toolCatalog = builtinTools,
    MemoryService? memory,
    ContextSummaryService? summaryService,
    bool smartRouting = false,
    bool keepaliveNotification = false,
    AgentService? agentService,
    ApiService Function(ProviderProfile profile)? dualApiFactory,
    DocumentIndexService? documentIndex,
  })  : _db = database,
        _api = api,
        _session = session,
        _profile = profile,
        _model = model,
        _agent = agent,
        _toolCatalog = toolCatalog,
        _memory = memory,
        _summaryService = summaryService ??
            ContextSummaryService(api: api, database: database),
        _smartRoutingEnabled = smartRouting,
        _keepaliveNotification = keepaliveNotification,
        _documentIndex = documentIndex,
        _runSkillDelegate = agentService == null
            ? null
            : _HostRunSkillDelegate(agentService) {
    // 委派桥绑定宿主（初始化列表不能引用 this，构造体补挂）
    _runSkillDelegate?._bindHost(this);
    // 注册表在构造体构建：run_skill 需要已绑定的委派桥实例
    _tools = _buildRegistry(
      agent,
      toolCatalog,
      sessionId: session.id,
      runSkillDelegate: _runSkillDelegate,
    );
    // F6 双答对侧连接工厂（null = 默认按 profile 新建；测试注入 mock）
    _dualApiFactory = dualApiFactory ??
        (profile) =>
            ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
  }

  final DatabaseService _db;
  ApiService _api;
  final ChatSession _session;
  ProviderProfile _profile;
  String _model;

  /// 用户长期记忆服务（null = 不启用记忆注入，兼容现有测试）
  MemoryService? _memory;

  /// F2 上下文压缩服务（水位检查 + 摘要生成）
  final ContextSummaryService _summaryService;

  /// F8 长文工作台索引服务（null = 不索引不注入，兼容现有测试）
  final DocumentIndexService? _documentIndex;

  /// 本轮检索注入文本（sendMessage 预取，_buildApiMessages 消费；
  /// null = 无文档资料）
  String? _docContextText;

  /// 当前会话的前情摘要（null = 未压缩过；loadMessages 时从 DB 读）
  ContextSummary? _contextSummary;

  /// 当前会话绑定的 Agent（null = 默认助手，无 system prompt + 全部工具）
  Agent? _agent;

  /// 工具目录（Agent 工具子集的选取范围）
  List<ToolHandler> _toolCatalog;

  /// run_skill 委派桥（agentService 非空时构建并绑定宿主；null =
  /// run_skill 不注册，兼容现有测试与「无 Agent 服务」场景）
  _HostRunSkillDelegate? _runSkillDelegate;

  /// 工具注册表（按 Agent.toolNames 从目录构建；null = 不启用工具；
  /// 是否随请求发送还看 profile 能力）
  ToolRegistry? _tools;

  /// 按 Agent 的工具子集声明从目录构建注册表
  ///
  /// toolNames null = 全部目录工具（默认助手/迁移老数据）；
  /// [] = 无工具；非空 = 指定子集（目录中不存在的名字忽略）。
  /// memory_save 工具按当前 Agent 注入来源名（记忆溯源）；
  /// search_history 工具注入当前会话 id（检索时排除本会话）。
  /// run_skill 仅在宿主提供 AgentService 时注册（T2 链式编排）。
  static ToolRegistry _buildRegistry(
      Agent? agent, List<ToolHandler> catalog,
      {String? sessionId, RunSkillDelegate? runSkillDelegate}) {
    final registry = ToolRegistry();
    final allowed = agent?.toolNames;
    final selected = allowed == null
        ? catalog
        : catalog.where((t) => allowed.contains(t.name)).toList();
    registry.registerAll([
      for (final t in selected)
        t is MemorySaveTool
            ? MemorySaveTool(sourceAgent: agent?.name)
            : t is SearchHistoryTool
                ? SearchHistoryTool(currentSessionId: sessionId)
                : t,
    ]);
    if (runSkillDelegate != null) {
      registry.register(RunSkillTool(runSkillDelegate));
    }
    return registry;
  }

  /// 会话绑定的供应商 profile（请求组装与能力判断依据）
  ProviderProfile get profile => _profile;

  /// 能力快捷判断（UI 显隐用）
  bool get supportsVision => _profile.capabilities.vision;
  bool get supportsReasoning => _profile.capabilities.reasoning;

  /// 工具调用是否随请求发送（能力 + 注册表非空）
  bool get _toolsEnabled =>
      _profile.capabilities.toolCalls && (_tools?.isNotEmpty ?? false);

  /// 当前注册的工具数（测试/调试用）
  int get toolCount => _tools?.length ?? 0;

  /// agentic loop 最大轮数（防死循环 + token 膨胀）
  static const _maxLoopIterations = 8;

  List<ChatMessage> _messages = [];
  ChatStatus _status = ChatStatus.idle;
  String _errorMessage = '';

  /// 待发送附件队列（随下一条消息一起发出）
  List<MessageAttachment> _pendingAttachments = [];

  /// 当前流式中的 assistant 消息（未落库，done 时落库）
  ChatMessage? _streamingMessage;

  /// F6 双答对侧的流式消息（与 _streamingMessage 并存渲染两条流式气泡；
  /// 非双答时为 null）
  ChatMessage? _dualStreamingMessage;

  /// F6 双答对侧的取消令牌（停止键同时停两侧）
  CancelToken? _dualCancelToken;

  /// F6 双答对侧 ApiService 工厂（生产按 profile 新建；测试注入 mock。
  /// 对侧供应商 baseUrl/Key 与主侧不同，不能复用主连接池）
  late ApiService Function(ProviderProfile profile) _dualApiFactory;

  CancelToken? _cancelToken;
  StreamSubscription<SseEvent>? _subscription;
  DateTime? _thinkingStart;

  /// 本轮生成起始时间（I10：思考+回答全程耗时；工具轮跨轮累计）
  DateTime? _generationStart;

  /// 最近一次收尾的耗时快照（落库后供 UI 角标读取；流式中为 null）
  int? _lastGenerationSeconds;

  /// 本轮 usage 统计（SseUsage 末帧捕获；null = 网关未透传，走估算）
  int? _roundPromptTokens;
  int? _roundCompletionTokens;

  /// 本轮发起请求前的 prompt 估算（订阅前算好，供无 usage 时兜底）
  int _promptEstimate = 0;

  /// dispose 标记：loop 在后台推进，dispose 后不再通知 UI，也不再碰 DB
  ///
  /// CI 取证（run 40973938298）：fire-and-forget loop 在测试 tearDown
  /// （dispose + db.close）后仍会推进——挂起中的工具轮写库链在下一个
  /// 用例 initForTest 换库后恢复，把上一用例的残留消息写进新库
  /// （I4 断言 5 vs 2 的元凶）。dispose 必须是硬边界：loop 各 await
  /// 恢复点检查此标记，置位即退出，不再产生任何 DB 写。
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 工具调用分片累积（按 index 拼接，SseToolCallsFinished 时成完整调用）
  final Map<int, _ToolCallAccumulator> _toolCallAccumulators = {};

  /// 本轮已完成的工具执行结果（UI 卡片渲染用，随 streamingMessage 生命周期）
  List<ToolCallResult> _toolResults = [];

  /// 最近一次发起工具调用的 assistant 消息 ID（UI 卡片归属判断）
  String? _lastToolCallMessageId;

  // ===== Getters =====
  ChatSession get session => _session;
  Agent? get agent => _agent;
  List<ChatMessage> get messages => _messages;
  ChatStatus get status => _status;
  String get errorMessage => _errorMessage;
  bool get isStreaming =>
      _status == ChatStatus.thinking ||
      _status == ChatStatus.answering ||
      _status == ChatStatus.toolCalling;
  ChatMessage? get streamingMessage => _streamingMessage;

  /// 本轮工具执行结果（UI 工具卡片用）
  List<ToolCallResult> get toolResults => _toolResults;

  /// 最近一次发起工具调用的 assistant 消息 ID（UI 工具卡片归属判断）
  String? get lastToolCallMessageId => _lastToolCallMessageId;

  /// 页面渲染用的完整消息列表（含流式中消息；双答时两条流式占位都在尾部）
  List<ChatMessage> get displayMessages {
    if (_streamingMessage == null && _dualStreamingMessage == null) {
      return _messages;
    }
    return [
      ..._messages,
      ?_streamingMessage,
      ?_dualStreamingMessage,
    ];
  }

  /// 会话累计 token 消耗（输入+输出，落库消息求和；F3 Token 水位仪表盘）
  int get totalTokens {
    var sum = 0;
    for (final m in _messages) {
      sum += (m.promptTokens ?? 0) + (m.completionTokens ?? 0);
    }
    return sum;
  }

  /// 最近一轮输入 token（上下文水位条用；无记录返回 null）
  int? get lastPromptTokens {
    for (final m in _messages.reversed) {
      if (m.promptTokens != null) return m.promptTokens;
    }
    return null;
  }

  /// 当前会话的前情摘要（F2 压缩产物；null = 未压缩过，UI 摘要卡片用）
  ContextSummary? get contextSummary => _contextSummary;

  /// 生效的推理档位（UI 展示用，与请求实际发送值一致）
  String get effectiveEffort => _effectiveEffort;

  /// 生效的温度（UI 展示用）
  double get effectiveTemperature => _effectiveTemperature;

  /// 待发送附件（输入栏预览条渲染用）
  List<MessageAttachment> get pendingAttachments =>
      List.unmodifiable(_pendingAttachments);

  bool get hasPendingAttachments => _pendingAttachments.isNotEmpty;

  /// 添加附件（图片 ≤3、文件 ≤3，超限返回 false）
  ///
  /// F8：PDF 附件（有沙箱路径）后台分块索引——fire-and-forget，
  /// 索引完成前发送也能走 extractedText 全量注入的老路径（索引是
  /// 增强不是门槛）。
  bool addAttachment(MessageAttachment attachment) {
    final images = _pendingAttachments.where((a) => a.isImage).length;
    final files = _pendingAttachments.where((a) => a.isFile).length;
    if (attachment.isImage && images >= 3) return false;
    if (attachment.isFile && files >= 3) return false;
    _pendingAttachments = [..._pendingAttachments, attachment];
    _maybeIndexPdfAttachment(attachment);
    _notify();
    return true;
  }

  /// PDF 附件后台索引（F8）：有原文件路径且是 .pdf 才索引
  void _maybeIndexPdfAttachment(MessageAttachment attachment) {
    final index = _documentIndex;
    if (index == null) return;
    if (!attachment.isFile) return;
    final path = attachment.filePath;
    if (path == null || path.isEmpty) return;
    if (!attachment.name.toLowerCase().endsWith('.pdf')) return;
    unawaited(index
        .indexPdfFile(
            sessionId: _session.id,
            docName: attachment.name,
            sourcePath: path)
        .then((count) {
      if (count > 0) debugPrint('文档索引完成：${attachment.name}（$count 块）');
    }));
  }

  /// 移除待发送附件
  void removeAttachment(MessageAttachment attachment) {
    _pendingAttachments = [
      for (final a in _pendingAttachments)
        if (!identical(a, attachment)) a,
    ];
    _notify();
  }

  /// 加载历史消息
  Future<void> loadMessages() async {
    _messages = await _db.getMessages(_session.id);
    _contextSummary = await _db.getContextSummary(_session.id);
    // E5：启动扫描——最后一条 assistant 消息带中断标记（App 被杀时
    // 占位未收尾 / 断流落库的半截），恢复中断态供 UI 显示续传胶囊
    if (_messages.isNotEmpty) {
      final last = _messages.last;
      _lastRoundInterrupted =
          last.role == 'assistant' && last.interrupted;
    }
    _notify();
  }

  /// 发送消息（可带待发送附件队列）
  Future<void> sendMessage(String text) async {
    final content = text.trim();
    if ((content.isEmpty && _pendingAttachments.isEmpty) || isStreaming) {
      return;
    }

    _errorMessage = '';
    // E5：中断态下直接发新消息 = 放弃续传（被中断的半截消息保留原样，
    // 不再是「最后一条 assistant」，启动扫描不会误报）
    _lastRoundInterrupted = false;
    final now = DateTime.now().millisecondsSinceEpoch;

    // F4 智能路由：按本条消息内容决策推理档位（开关关闭时为 null，
    // _effectiveEffort 走原有 Agent/会话优先级，行为不变）
    _smartRouteEffort = _smartRoutingEnabled
        ? SmartRouter.route(content, hasAttachments: _pendingAttachments.isNotEmpty)
        : null;

    // 1. 落库 user 消息（含待发送附件，随后清空队列）
    final userMsg = ChatMessage(
      id: _genId(),
      sessionId: _session.id,
      role: 'user',
      content: content,
      attachments: _pendingAttachments,
      createdAt: now,
    );
    _pendingAttachments = [];
    await _db.insertMessage(userMsg);
    _messages = [..._messages, userMsg];

    // 首条消息自动生成会话标题（无文字时用附件名）
    if (_session.title.isEmpty || _session.title == '新对话') {
      final titleSource = content.isNotEmpty
          ? content
          : userMsg.attachments.first.name;
      _session.title =
          titleSource.length > 20 ? titleSource.substring(0, 20) : titleSource;
      await _db.updateSessionTitle(_session.id, _session.title);
    }
    await _db.touchSession(_session.id);

    // 2. 水位检查：超线则先把早期历史压缩成前情摘要（F2）。
    // 压缩失败静默跳过——不影响本轮正常发送，下轮再试。
    await _maybeCompressContext();

    // 3. 预取第一轮记忆注入文本（在 loop 启动前完成——loop 从启动到
    // 建立流订阅之间不能有 await，否则测试/调用方在 sendMessage 返回后
    // 立即 emit 的事件会因订阅未建立而丢失）
    await _refreshMemoryText();

    // 3.5 F8：按本轮消息检索文档片段（同上，loop 启动前完成）
    await _refreshDocContext(content);

    // 4. 启动 agentic loop（fire-and-forget：sendMessage 立即返回，
    // loop 在后台推进，与旧版「启动流即返回」语义一致）。
    // loop 后台推进期间宿主可能已 dispose（切会话/测试 tearDown 关库），
    // 后续落库会抛 database_closed——吞掉即可：dispose 后 UI 已不订阅，
    // 消息数据以已落库部分为准，索引/续轮丢失无碍。
    _toolResults = [];
    unawaited(_runLoop().catchError((Object e) {
      debugPrint('ChatProvider loop 后台异常（已忽略）：$e');
    }));
  }

  /// F6 同问双答：同一条消息并发发给两个供应商，双气泡对照，点选其一继续
  ///
  /// 与 [sendMessage] 共用前置（落库 user 消息/标题/压缩/记忆预取），
  /// 之后**两侧并发纯文本流**（tools: null——对照场景要的是模型本色，
  /// 工具编排是主 loop 的职责）。每侧独立 CancelToken：停止键同时停
  /// 两侧；一侧失败不拖垮另一侧（失败侧落错误占位，成功侧照常待选）。
  ///
  /// 双答目标由 [setDualTarget] 预设（一次性消费）；未预设 = 当前会话
  /// 供应商自答（同模型双采样对照）。
  ///
  /// 两侧都收尾后交叉标记 dualOf（互指 = 待选择态），[chooseDual]
  /// 删姊妹清标记回到单线。全程不落会话级状态——重启后待选择态由
  /// 消息数据派生，天然恢复。
  Future<void> sendDualMessage(String text) async {
    final content = text.trim();
    if (content.isEmpty || isStreaming || _dualRunning) return;

    // 消费一次性双答目标（读后即清，下次发送回到普通单流）
    final target = _dualTarget;
    _dualTarget = null;

    _errorMessage = '';
    _lastRoundInterrupted = false;
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. 落库 user 消息（双答不支持附件——对照场景以文本为主）
    final userMsg = ChatMessage(
      id: _genId(),
      sessionId: _session.id,
      role: 'user',
      content: content,
      createdAt: now,
    );
    await _db.insertMessage(userMsg);
    _messages = [..._messages, userMsg];

    // 首条消息自动生成会话标题（与 sendMessage 同规则）
    if (_session.title.isEmpty || _session.title == '新对话') {
      _session.title =
          content.length > 20 ? content.substring(0, 20) : content;
      await _db.updateSessionTitle(_session.id, _session.title);
    }
    await _db.touchSession(_session.id);

    // 2. 水位检查 + 记忆预取（与 sendMessage 同前置；压缩失败静默）
    await _maybeCompressContext();
    await _refreshMemoryText();

    // 3. 双侧并发流。对侧供应商走独立 ApiService（baseUrl/Key 不同，
    //    不能复用主连接池）；同供应商自答时也走独立实例——连接池隔离，
    //    两侧取消互不干扰。生命周期归本方法（finally dispose）
    final (otherProfile, otherModel) = target ?? (_profile, _model);
    final otherApi = _dualApiFactory(otherProfile);
    _dualRunning = true;
    _status = ChatStatus.thinking;
    _notify();
    try {
      await _runDualStreams(otherApi, otherProfile, otherModel, content);
    } finally {
      otherApi.dispose();
      _dualRunning = false;
      if (!_disposed) _notify();
    }
  }

  /// 双侧并发流式：每侧独立占位消息 + CancelToken + 订阅，两侧都收尾
  /// 后交叉标记 dualOf 进入待选择态
  Future<void> _runDualStreams(
    ApiService otherApi,
    ProviderProfile otherProfile,
    String otherModel,
    String task,
  ) async {
    // 两侧占位消息（E5 同款：interrupted 预置 true，收尾覆写复位）
    final leftMsg = ChatMessage(
      id: _genId(),
      sessionId: _session.id,
      role: 'assistant',
      interrupted: true,
      sourceLabel: '${_profile.name} · $_model',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final rightMsg = ChatMessage(
      id: _genId(),
      sessionId: _session.id,
      role: 'assistant',
      interrupted: true,
      sourceLabel: '${otherProfile.name} · $otherModel',
      createdAt: DateTime.now().millisecondsSinceEpoch + 1,
    );
    // 主侧流式占位走 _streamingMessage（复用既有渲染管线），对侧挂
    // _dualStreamingMessage（列表渲染第二条流式气泡）
    _streamingMessage = leftMsg;
    _dualStreamingMessage = rightMsg;
    _persistQuietly(_db.insertMessage(leftMsg));
    _persistQuietly(_db.insertMessage(rightMsg));
    _notify();

    final leftToken = CancelToken();
    final rightToken = CancelToken();
    _cancelToken = leftToken;
    _dualCancelToken = rightToken;

    final history = _buildApiMessages();
    final leftEstimate = estimatePromptTokens(history);

    // 单侧执行：流式收包 → 收尾落库。返回是否成功（失败侧落错误占位）
    Future<bool> runSide({
      required ApiService api,
      required ProviderProfile profile,
      required String model,
      required ChatMessage msg,
      required CancelToken token,
      required int promptEstimate,
    }) async {
      final completer = Completer<void>();
      Object? streamError;
      var finished = false;

      // 收尾：成功/取消保留内容，错误标错误占位（不进 _messages——
      // 双答收尾统一在两侧都完成后处理）
      void finish({String? error}) {
        if (finished) return;
        finished = true;
        if (error != null) streamError = error;
        if (!completer.isCompleted) completer.complete();
      }

      final sub = api
          .chatStream(
        profile: profile,
        messages: history,
        model: model,
        effort: _effectiveEffort,
        cancelToken: token,
        temperature: _effectiveTemperature,
        tools: null, // 双答纯文本对照，无工具
      )
          .listen(
        (event) {
          switch (event) {
            case SseDeltaReasoning(:final text):
              msg.reasoning += text;
              if (!_disposed) _notify();
            case SseDeltaContent(:final text):
              msg.content += text;
              if (!_disposed) _notify();
            case SseUsage(:final promptTokens, :final completionTokens):
              msg.promptTokens = promptTokens;
              msg.completionTokens = completionTokens;
            case SseDone():
              finish();
            case SseInterrupted():
              finish();
            case SseError(:final message):
              finish(error: message);
            default:
              break;
          }
        },
        onError: (Object e) {
          if (e is DioException && e.type == DioExceptionType.cancel) {
            finish(); // 手动停止：保留已收内容
          } else if (e is ApiException) {
            finish(error: e.message);
          } else {
            finish(error: '请求失败：$e');
          }
        },
        onDone: finish,
      );

      await completer.future;
      await sub.cancel();

      if (_disposed) return false;

      // 收尾落库：有内容（或思考）= 覆写占位；空 + 出错 = 错误占位；
      // 空 + 无错（取消时刚建）= 删占位
      final hasContent =
          msg.content.isNotEmpty || msg.reasoning.isNotEmpty;
      if (hasContent) {
        msg.promptTokens ??= promptEstimate > 0 ? promptEstimate : null;
        msg.completionTokens ??= () {
          final est = estimateTextTokens(msg.reasoning + msg.content);
          return est > 0 ? est : null;
        }();
        msg.interrupted = streamError != null;
        _persistQuietly(_db.insertMessage(msg));
        return streamError == null;
      }
      if (streamError != null) {
        msg.content = '（该侧请求失败：$streamError）';
        msg.interrupted = true;
        _persistQuietly(_db.insertMessage(msg));
        return false;
      }
      _persistQuietly(_db.deleteMessage(msg.id));
      return false;
    }

    // 两侧真并发：Future.wait 同时跑（对照体验 = 同时出字）。
    // 任一侧抛异常按失败处理（runSide 内部已兜住流错误，这里防漏网）
    var leftOk = false;
    var rightOk = false;
    try {
      final results = await Future.wait([
        runSide(
          api: _api,
          profile: _profile,
          model: _model,
          msg: leftMsg,
          token: leftToken,
          promptEstimate: leftEstimate,
        ),
        runSide(
          api: otherApi,
          profile: otherProfile,
          model: otherModel,
          msg: rightMsg,
          token: rightToken,
          promptEstimate: leftEstimate,
        ),
      ]);
      leftOk = results[0];
      rightOk = results[1];
    } catch (e) {
      debugPrint('ChatProvider 双答流异常（按失败收尾）：$e');
    }
    if (_disposed) return;

    // 两侧都收尾：进消息列表 + 交叉标记 dualOf（互指 = 待选择态）。
    // 仅两侧都成功收尾（runSide true = 有真实内容且无错误）才互指——
    // 失败侧的错误占位不参与选择（没人会在真答案和报错之间纠结），
    // 空侧占位已删除；单侧结果直接当普通消息用，无需选择
    final leftKept = leftMsg.content.isNotEmpty;
    final rightKept = rightMsg.content.isNotEmpty;
    if (leftOk && rightOk) {
      leftMsg.dualOf = rightMsg.id;
      rightMsg.dualOf = leftMsg.id;
      _persistQuietly(_db.insertMessage(leftMsg));
      _persistQuietly(_db.insertMessage(rightMsg));
    }
    _messages = [..._messages, if (leftKept) leftMsg, if (rightKept) rightMsg];

    // 双答收尾状态：两侧都成功 = idle 待选择；有失败侧 = error 提示
    //（成功侧仍展示，错误条可关闭）
    _streamingMessage = null;
    _dualStreamingMessage = null;
    _cancelToken = null;
    _dualCancelToken = null;
    if (!leftOk || !rightOk) {
      _status = ChatStatus.error;
      _errorMessage = leftOk
          ? '对侧（${otherProfile.name}）请求失败，本侧结果已保留'
          : '本侧（${_profile.name}）请求失败，对侧结果已保留';
    } else {
      _status = ChatStatus.idle;
    }
    _thinkingStart = null;
    _generationStart = null;
    _lastRoundInterrupted = false;
    _notify();
  }

  /// F6 点选其一继续会话：删除姊妹回答，清本侧标记，返回应切换到的
  /// 供应商与模型（选中侧的来源；null = 保持当前）
  ///
  /// 待选择态下气泡上的「用这个继续」按钮调用。切换由宿主执行
  /// （switchProvider 需要重建 ApiService，UI 层已有成熟管线）。
  Future<(ProviderProfile, String)?> chooseDual(ChatMessage keep) async {
    if (!isAwaitingDualChoice) return null;
    final siblingId = keep.dualOf;
    if (siblingId == null) return null;

    // 删姊妹（DB + 内存），清本侧标记（DB + 内存）。
    // keep 可能是宿主传入的 DB 新实例（非 _messages 内对象），
    // 标记清除按 id 定位内存实例，保证渲染态与 DB 一致
    await _db.deleteMessage(siblingId);
    _messages = [
      for (final m in _messages)
        if (m.id != siblingId) m,
    ];
    for (final m in _messages) {
      if (m.id == keep.id) m.dualOf = null;
    }
    keep.dualOf = null;
    await _db.insertMessage(keep); // replace 覆写清 dual_of
    _notify(); // 列表重建：姊妹气泡消失 + 本侧按钮隐藏（待选择态解除）

    // 选中侧来源 = 会话后续走向（来源徽标已把出处告诉用户，切换让
    // 后续对话延续同一供应商）
    final label = keep.sourceLabel;
    if (label == null) return null;
    // sourceLabel 格式「{name} · {model}」；反解 name 找 profile
    final sep = label.lastIndexOf(' · ');
    if (sep < 0) return null;
    final providerName = label.substring(0, sep);
    final model = label.substring(sep + 3);
    // 当前会话供应商名字匹配 = 保持现状（无需切换）
    if (providerName == _profile.name && model == _model) return null;
    // 找不到对应 profile（如已删除）= 保持现状
    final profiles = await _db.getAllProviders();
    for (final p in profiles) {
      if (p.name == providerName) return (p, model);
    }
    return null;
  }

  /// F2 分层上下文压缩：水位检查 → 触发摘要生成 → 更新注入状态
  ///
  /// 触发条件：最近一轮 prompt token ≥ 水位线（名义 32k 的 75%）且
  /// 保留窗口之外有足够可压缩轮。压缩请求走 low 档低温，失败静默。
  /// 钉住消息所在轮豁免压缩（isPinned 谓词透传给轮切分）。
  Future<void> _maybeCompressContext() async {
    bool isPinned(ChatMessage m) => m.pinned;
    if (!ContextSummaryService.shouldCompress(
      _messages,
      lastPromptTokens: lastPromptTokens,
      isPinned: isPinned,
    )) {
      return;
    }
    final summary = await _summaryService.compressIfNeeded(
      messages: _messages,
      profile: _profile,
      model: _model,
      sessionId: _session.id,
      existing: _contextSummary,
      isPinned: isPinned,
    );
    if (summary != null) {
      _contextSummary = summary;
      _notify();
    }
  }

  /// 设置消息钉住状态（F2：钉住消息所在轮永不压缩进前情摘要）
  ///
  /// DB 落盘 + 内存同步 + 通知 UI（气泡显示图钉标记）。
  Future<void> setMessagePinned(ChatMessage message, bool pinned) async {
    if (message.pinned == pinned) return;
    message.pinned = pinned;
    await _db.setMessagePinned(message.id, pinned);
    _notify();
  }

  /// 编辑重发（I4）：截断该消息及其后全部消息，以新文本重新发送
  ///
  /// ChatGPT 式「说错了改一句重来」：只允许编辑自己的 user 消息，
  /// 流式中禁止。截断 = DB 删除 + 内存列表同步；若前情摘要边界指向
  /// 被删消息，摘要一并作废（早期历史已不在，摘要失去锚点）。
  /// 截断后走 [sendMessage] 正常管线（水位检查/记忆注入/loop 全复用）。
  Future<void> editAndResend(ChatMessage message, String newText) async {
    if (!message.isUser || isStreaming) return;
    final content = newText.trim();
    if (content.isEmpty) return;

    // 1. 截断：DB 删除该消息及其后全部消息，内存列表同步
    await _db.deleteMessagesFrom(message.id, message.createdAt);
    final idx = _messages.indexWhere((m) => m.id == message.id);
    if (idx >= 0) {
      _messages = _messages.sublist(0, idx);
    }
    // E5：截断即离开中断态（被中断的半截消息已随截断删除）
    _lastRoundInterrupted = false;

    // 2. 前情摘要失效检查：边界消息被删则摘要作废（DB + 内存）
    final summary = _contextSummary;
    if (summary != null) {
      final boundaryGone = _messages.every((m) =>
          m.id != summary.firstKeptId && m.createdAt < summary.firstKeptAt);
      if (boundaryGone) {
        await _db.deleteContextSummary(_session.id);
        _contextSummary = null;
      }
    }

    // 3. 以新文本重新发送（sendMessage 落库新 user 消息 + 启动 loop）
    await sendMessage(content);
  }

  /// 重答（I3）：删除该 assistant 消息及其后全部消息，复用原 user
  /// 消息重新生成
  ///
  /// 长按菜单「重答」入口：对最后一条 assistant 回答不满意时一键
  /// 重跑。截断 = DB 删除 + 内存同步（复用 [resumeLastGeneration]
  /// 的孤儿清理语义）；user 消息不重插，直接走 loop 启动段。
  Future<void> regenerateFrom(ChatMessage assistantMsg) async {
    if (isStreaming || assistantMsg.isUser) return;

    // 找该 assistant 消息之前最近的一条 user 消息（重答锚点）
    final idx = _messages.indexWhere((m) => m.id == assistantMsg.id);
    if (idx < 0) return;
    String? lastUserId;
    for (var i = idx - 1; i >= 0; i--) {
      if (_messages[i].isUser) {
        lastUserId = _messages[i].id;
        break;
      }
    }
    if (lastUserId == null) return;

    // 删除该 assistant 消息及其后全部消息（含 tool 结果等中间产物；
    // F6：双答姊妹在前面时同样被删——重答任一侧 = 整轮重来）
    final orphans = _messages.skip(idx).toList();
    for (final m in orphans) {
      await _db.deleteMessage(m.id);
    }
    // 姊妹回答在重答目标之前（重答左侧时右侧还在列表前段）：一并删除
    final siblingId = assistantMsg.dualOf;
    if (siblingId != null) {
      await _db.deleteMessage(siblingId);
    }
    final userIdx = _messages.indexWhere((m) => m.id == lastUserId);
    _messages = _messages.sublist(0, userIdx + 1);
    // E5：重答即离开中断态（被中断的半截消息已删除）
    _lastRoundInterrupted = false;

    // 前情摘要失效检查：边界消息被删则摘要作废（与 editAndResend 同规则）
    final summary = _contextSummary;
    if (summary != null) {
      final boundaryGone = _messages.every((m) =>
          m.id != summary.firstKeptId && m.createdAt < summary.firstKeptAt);
      if (boundaryGone) {
        await _db.deleteContextSummary(_session.id);
        _contextSummary = null;
      }
    }

    // 重新生成（user 消息复用原条，直接走 loop 启动段）
    await _refreshMemoryText();
    _toolResults = [];
    unawaited(_runLoop().catchError((Object e) {
      debugPrint('ChatProvider loop 后台异常（已忽略）：$e');
    }));
  }

  /// agentic loop：请求 → 流式收包 →（工具调用？执行 → 再请求）→ 收尾
  ///
  /// 每轮创建新的流式 assistant 消息；工具轮结束后 assistant 消息
  /// （含 tool_calls）立即落库，工具结果以 role='tool' 消息落库，
  /// 然后进入下一轮。取消 = 终止整个 loop，已落库内容保留。
  Future<void> _runLoop() async {
    // I13 后台保活：生成开始启动前台服务 + WakeLock（静默容错，
    // 插件异常不影响生成主流程）
    unawaited(GenerationKeepalive.start(
      notificationEnabled: _keepaliveNotification,
      title: _session.title.isEmpty ? 'Liang AI' : _session.title,
    ));
    try {
      await _runLoopInner();
    } finally {
      // 所有收尾路径（完成/出错/断流/取消/轮数耗尽）统一释放
      unawaited(GenerationKeepalive.stop());
    }
  }

  Future<void> _runLoopInner() async {
    for (var iteration = 0; iteration < _maxLoopIterations; iteration++) {
      // dispose 硬边界：宿主已销毁（切会话/测试 tearDown），立即退出，
      // 不再创建占位消息、不再发起请求、不再写库
      if (_disposed) return;
      // 超上限保护：最后一轮注入系统提示强制模型总结
      final forceSummary = iteration == _maxLoopIterations - 1;

      // 创建本轮流式 assistant 消息（E5：interrupted 预置 true——
      // 占位即「未收尾」，正常收尾时覆写复位）
      _streamingMessage = ChatMessage(
        id: _genId(),
        sessionId: _session.id,
        role: 'assistant',
        interrupted: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _status = ChatStatus.thinking;
      _thinkingStart ??= DateTime.now();
      // I10：首轮记生成起点（工具轮跨轮累计，不重置）
      _generationStart ??= DateTime.now();
      // E5：流式开始即落库占位（interrupted=1）——App 被杀时消息已在
      // DB，启动扫描能识别「未收尾」；正常收尾时覆写为完整内容
      _persistQuietly(_db.insertMessage(_streamingMessage!));
      _notify();

      // 发起流式请求（Agent system prompt 插入消息头部）
      _cancelToken = CancelToken();
      final history = _buildApiMessages(forceSummary: forceSummary);
      // F3：本轮 token 统计复位 + prompt 估算（订阅前完成，无 await 间隙）
      _roundPromptTokens = null;
      _roundCompletionTokens = null;
      _promptEstimate = estimatePromptTokens(history);
      final completer = Completer<void>();
      // 本轮是否已进入工具执行流程（防止 [DONE] 尾随分片重复收尾）
      var toolRoundStarted = false;

      _subscription = _api
          .chatStream(
        profile: _profile,
        messages: history,
        model: _model,
        effort: _effectiveEffort,
        cancelToken: _cancelToken!,
        temperature: _effectiveTemperature,
        tools: _toolsEnabled ? _tools!.toOpenAiTools() : null,
      )
          .listen(
        (event) {
          switch (event) {
            case SseDeltaReasoning(:final text):
              _streamingMessage = _streamingMessage!..reasoning += text;
              if (_status == ChatStatus.thinking) _notify();
            case SseDeltaContent(:final text):
              _streamingMessage = _streamingMessage!..content += text;
              _status = ChatStatus.answering;
              _notify();
            case SseToolCallDelta():
              _accumulateToolCallFragment(event);
            case SseUsage(:final promptTokens, :final completionTokens):
              // F3：网关透传的真实用量（末帧），优先于本地估算
              _roundPromptTokens = promptTokens;
              _roundCompletionTokens = completionTokens;
            case SseToolCallsFinished():
              toolRoundStarted = true;
              // 延迟到微任务后 complete：vLLM 在 finish_reason=tool_calls
              // 之后同批还会发 usage 末帧（+ [DONE]），同步 complete 会让
              // loop 在 usage 投递前取消订阅（真实用量丢失）。让出微任务
              // 让同批事件先走完，兼容不发 usage/[DONE] 的服务端。
              scheduleMicrotask(() {
                if (!completer.isCompleted) completer.complete();
              });
            case SseDone():
              // 工具轮后服务端常尾随 [DONE]：此时本轮已交给工具流程，忽略
              if (toolRoundStarted) return;
              _finishStreaming();
              if (!completer.isCompleted) completer.complete();
            case SseInterrupted():
              // I10 断流：连接断开未收到 [DONE]——保留已收内容落库，
              // 标记中断态供 UI 显示「连接中断 · 点击续传」
              if (toolRoundStarted) return;
              _interruptStreaming();
              if (!completer.isCompleted) completer.complete();
            case SseError(:final message):
              if (toolRoundStarted) return;
              _failStreaming(message);
              if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (Object e) {
          if (e is DioException && e.type == DioExceptionType.cancel) {
            _finishStreaming(); // 手动停止：保留已收内容
          } else if (e is ApiException) {
            _failStreaming(e.message);
          } else {
            _failStreaming('请求失败：$e');
          }
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (isStreaming) _finishStreaming();
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future;
      // 旧订阅不再需要：广播流下不取消会重复消费下一轮事件
      await _subscription?.cancel();

      // 流结束后判定：正常收尾 / 工具轮继续 / 出错终止
      if (_status == ChatStatus.error || _status == ChatStatus.idle) {
        return; // SseDone / SseError / 取消：loop 结束
      }
      // toolCalling：执行工具 → 落库 → 下一轮
      final continueLoop = await _executeToolRound();
      if (!continueLoop) return;
    }
    // 轮数耗尽（理论上 forceSummary 已让模型收尾，这里兜底）
    _finishStreaming();
  }

  /// 累积工具调用分片（按 index 拼接：首片 id/name，后续片 arguments 增量）
  void _accumulateToolCallFragment(SseToolCallDelta event) {
    final acc = _toolCallAccumulators.putIfAbsent(
        event.index, () => _ToolCallAccumulator());
    if (event.id != null) acc.id = event.id!;
    if (event.name != null) acc.name = event.name!;
    if (event.argumentsFragment != null) {
      acc.arguments.write(event.argumentsFragment!);
    }
  }

  /// 执行工具轮：assistant 消息（含 tool_calls）落库 → 逐个执行 →
  /// 结果消息落库 → 返回是否继续下一轮
  Future<bool> _executeToolRound() async {
    // dispose 硬边界：completer 恢复后宿主可能已销毁（测试 tearDown
    // 关库/切会话），继续走会把上一宿主的消息写进新库
    if (_disposed) return false;
    // 1. 分片累积成完整 ToolCall 列表
    final calls = <ToolCall>[
      for (final entry in _toolCallAccumulators.entries)
        ToolCall(
          id: entry.value.id.isEmpty ? 'call_${entry.key}' : entry.value.id,
          name: entry.value.name,
          argumentsJson: entry.value.arguments.toString(),
        ),
    ];
    _toolCallAccumulators.clear();

    // 2. 当前 assistant 消息（含 tool_calls + 已收 content/reasoning）落库
    //（E5 占位覆写：interrupted 复位——工具调用是完整产物，非半截）
    final assistantMsg = _streamingMessage!;
    assistantMsg.toolCalls = calls;
    assistantMsg.interrupted = false;
    _stampTokenUsage(assistantMsg);
    await _db.insertMessage(assistantMsg);
    _messages = [..._messages, assistantMsg];
    _lastToolCallMessageId = assistantMsg.id;
    _streamingMessage = null;

    // 3. 逐个执行工具（toolCalling 态供 UI 显示进度）
    _status = ChatStatus.toolCalling;
    _toolResults = [];
    _notify();

    final results = await _tools!.executeAll(calls);
    // dispose 硬边界：工具执行期间宿主可能已销毁——结果不再落库，
    // loop 终止（已落库的 assistant(tool_calls) 保留，与取消同语义）
    if (_disposed) return false;
    _toolResults = results;

    // 4. 每个结果生成 role='tool' 消息落库
    var at = DateTime.now().millisecondsSinceEpoch;
    for (final r in results) {
      // dispose 硬边界：批量落库中途被销毁，剩余结果不再写库
      if (_disposed) return false;
      final toolMsg = ChatMessage(
        id: _genId(),
        sessionId: _session.id,
        role: 'tool',
        content: r.content,
        toolCallId: r.callId,
        createdAt: at++,
      );
      await _db.insertMessage(toolMsg);
      _messages = [..._messages, toolMsg];
    }

    // 5. 取消检查：用户在工具执行期间点了停止 → 终止 loop（已落库保留）
    if (_cancelToken?.isCancelled == true) {
      _status = ChatStatus.idle;
      _cancelToken = null;
      _notify();
      return false;
    }

    // 6. 刷新记忆注入文本（工具轮可能刚存了新记忆；此处已有大量 await，
    // 不影响「订阅建立前无 await」的时序契约）
    await _refreshMemoryText();

    // 7. 继续下一轮
    _status = ChatStatus.thinking;
    _notify();
    return true;
  }

  /// 停止生成（保留已收内容；双答时同时停两侧）
  void stopGeneration() {
    _cancelToken?.cancel();
    _dualCancelToken?.cancel();
  }

  /// 断流续传（I10）：对最后一条 user 消息重新发起生成
  ///
  /// SSE 无法断点续传（连接已断，服务端不会从断点继续发）——续传 =
  /// 删掉截断的 assistant 消息（已收内容不完整，留着会误导），对同一条
  /// user 消息重新走完整管线（水位检查/记忆注入/loop 全复用）。
  /// 仅在 [lastRoundInterrupted] 时有效；流式中/非中断态为 no-op。
  Future<void> resumeLastGeneration() async {
    if (isStreaming || !_lastRoundInterrupted) return;
    _lastRoundInterrupted = false;

    // 找最后一条 user 消息（截断的 assistant 消息已落库，需删除）
    final lastUser = _messages.lastWhere((m) => m.isUser,
        orElse: () => throw StateError('中断续传：找不到 user 消息'));
    // 截断 assistant 消息在 user 之后：全部删除（含 tool 结果等中间产物）
    final cutoff = _messages.indexOf(lastUser);
    final orphans = _messages.skip(cutoff + 1).toList();
    for (final m in orphans) {
      await _db.deleteMessage(m.id);
    }
    _messages = _messages.sublist(0, cutoff + 1);

    // 重新发送（sendMessage 落库新 assistant 轮；user 消息复用原条，
    // 不重复落库——直接走 loop 启动段）
    await _refreshMemoryText();
    _toolResults = [];
    unawaited(_runLoop().catchError((Object e) {
      debugPrint('ChatProvider loop 后台异常（已忽略）：$e');
    }));
  }

  /// 正常结束：落库 assistant 消息
  ///
  /// 同步改状态 + fire-and-forget 落库（与旧版语义一致：调用方在
  /// completer 完成后立即读内存态；DB 断言经同一队列天然有序）。
  /// 落库带容错：dispose 后 DB 已关时静默（E5 占位残留无害，重启
  /// 扫描会把它标中断，用户重答即清）。
  void _finishStreaming() {
    // dispose 硬边界：dispose 后 DB 已关（或已被下一用例换库），
    // 收尾写库只会污染新库——直接放弃，E5 占位残留由启动扫描兜底
    if (_disposed) return;
    final msg = _streamingMessage;
    if (msg != null) {
      if (msg.content.isNotEmpty ||
          msg.reasoning.isNotEmpty ||
          msg.toolCalls.isNotEmpty) {
        _stampTokenUsage(msg);
        _stampDurations(msg);
        // E5 占位覆写：正常收尾 = interrupted 复位（toMap 写 0，
        // ConflictAlgorithm.replace 覆盖占位的 1）
        msg.interrupted = false;
        _persistQuietly(_db.insertMessage(msg));
        _messages = [..._messages, msg];
      } else {
        // 空消息（取消时刚创建、未收到任何内容）：E5 占位已落库，
        // 删除之，否则启动扫描会误报「已中断」
        _persistQuietly(_db.deleteMessage(msg.id));
      }
    }
    _streamingMessage = null;
    _status = ChatStatus.idle;
    _cancelToken = null;
    _toolCallAccumulators.clear();
    _thinkingStart = null;
    _generationStart = null;
    _lastRoundInterrupted = false;
    _notify();
  }

  /// fire-and-forget 落库的统一容错：失败只 debugPrint（dispose 后
  /// DB 已关是正常时序，绝不让异常逃到 zone 炸测试/崩溃）
  void _persistQuietly(Future<void> future) {
    future.catchError((Object e) {
      debugPrint('ChatProvider 落库失败（已忽略）：$e');
    });
  }

  /// 断流收尾（I10）：保留已收内容落库 + 标记中断态
  ///
  /// 与 [_failStreaming] 的区别：断流不是错误（网络抖动是常态），
  /// 不弹错误条，而是尾部显示「连接中断 · 点击续传」胶囊——
  /// 已收内容照常落库展示，用户可一键续传。
  void _interruptStreaming() {
    // dispose 硬边界：同 _finishStreaming——dispose 后不再写库
    if (_disposed) return;
    final msg = _streamingMessage;
    if (msg != null &&
        (msg.content.isNotEmpty || msg.reasoning.isNotEmpty)) {
      _stampTokenUsage(msg);
      _stampDurations(msg);
      msg.interrupted = true; // E5：中断消息持久标记（重启后仍可识别）
      _persistQuietly(_db.insertMessage(msg));
      _messages = [..._messages, msg];
    }
    _streamingMessage = null;
    _status = ChatStatus.idle;
    _cancelToken = null;
    _toolCallAccumulators.clear();
    _thinkingStart = null;
    _generationStart = null;
    _lastRoundInterrupted = true;
    _notify();
  }

  /// 耗时盖章（I10）：思考秒数 + 生成总秒数写到消息上（落库前调用）。
  /// 思考耗时 = 思考起点到首个正文增量（无正文 = 到收尾）；
  /// 生成耗时 = 本轮生成起点到收尾（工具轮跨轮累计）
  void _stampDurations(ChatMessage msg) {
    final thinkStart = _thinkingStart;
    if (thinkStart != null) {
      // 思考结束点：进入 answering 后 _thinkingStart 不变，这里用
      // 「首个 content 增量到达时刻」近似——收尾时若已有正文，思考
      // 时长按 reasoning 结束计；纯思考无正文按收尾时刻计
      msg.thinkingSeconds = DateTime.now().difference(thinkStart).inSeconds;
    }
    final genStart = _generationStart;
    if (genStart != null) {
      final seconds = DateTime.now().difference(genStart).inSeconds;
      msg.generationSeconds = seconds;
      _lastGenerationSeconds = seconds;
    }
  }

  /// 出错：保留已收内容落库，显示错误
  void _failStreaming(String message) {
    // dispose 硬边界：同 _finishStreaming——dispose 后不再写库
    if (_disposed) return;
    final msg = _streamingMessage;
    if (msg != null && (msg.content.isNotEmpty || msg.reasoning.isNotEmpty)) {
      _stampTokenUsage(msg);
      _stampDurations(msg);
      msg.interrupted = true; // E5：错误半截消息同样标中断（可重答）
      _persistQuietly(_db.insertMessage(msg));
      _messages = [..._messages, msg];
    }
    _streamingMessage = null;
    _status = ChatStatus.error;
    _errorMessage = message;
    _cancelToken = null;
    _toolCallAccumulators.clear();
    _thinkingStart = null;
    _generationStart = null;
    _lastRoundInterrupted = false;
    _notify();
  }

  /// 清除错误状态
  void clearError() {
    if (_status == ChatStatus.error) {
      _status = ChatStatus.idle;
      _errorMessage = '';
      _notify();
    }
  }

  /// 切换推理档位
  Future<void> setEffort(String effort) async {
    if (_session.effort == effort) return;
    _session.effort = effort;
    await _db.updateSessionEffort(_session.id, effort);
    _notify();
  }

  /// 切换会话绑定的 Agent（null = 默认助手）
  ///
  /// 同步按新 Agent 的工具子集重建注册表，下一轮请求即生效。
  Future<void> setAgent(Agent? agent) async {
    if (_agent?.id == agent?.id) return;
    _agent = agent;
    _tools = _buildRegistry(agent, _toolCatalog,
        sessionId: _session.id, runSkillDelegate: _runSkillDelegate);
    await _db.updateSessionAgent(_session.id, agent?.id);
    _notify();
  }

  /// 当前生效的模型名
  String get model => _model;

  /// 切换会话的供应商与模型（流式中禁止）
  ///
  /// 重建 ApiService（baseUrl/Key 可能变化）；供应商 null = 回退默认。
  Future<bool> switchProvider(ProviderProfile profile, String model) async {
    if (isStreaming) return false;
    if (profile.id == _profile.id && model == _model) return true;
    _api.dispose();
    _profile = profile;
    _model = model;
    _api = ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
    await _db.updateSessionProvider(_session.id, profile.id, model);
    _notify();
    return true;
  }

  /// 记忆注入文本缓存（每轮 loop 开始时刷新；null = 未启用/无记忆）
  String? _memoryText;

  /// 刷新记忆注入文本（未启用记忆服务时同步返回，不引入 await 间隙——
  /// 测试在 sendMessage 返回后立即 emit 事件，loop 必须无间隙建立订阅）
  Future<void> _refreshMemoryText() {
    final memory = _memory;
    if (memory == null) {
      _memoryText = null;
      return Future.value();
    }
    return memory.recentText().then((text) => _memoryText = text);
  }

  /// F8：按本轮消息内容检索文档片段，生成注入文本
  ///
  /// 会话内已索引文档时，取用户消息关键词检索 top-K 块组装
  /// 【文档资料】块（含引用标注指令）。无索引服务/无文档/检索空
  /// 均返回 null（不注入，行为与无文档会话一致）。
  Future<String?> _refreshDocContext(String query) async {
    final index = _documentIndex;
    if (index == null) {
      _docContextText = null;
      return null;
    }
    final q = query.trim();
    if (q.isEmpty) {
      _docContextText = null;
      return null;
    }
    final chunks = await _db.searchDocChunks(_session.id, q, limit: 6);
    if (chunks.isEmpty) {
      _docContextText = null;
      return null;
    }
    _docContextText = buildDocContextText(chunks);
    return _docContextText;
  }

  /// 组装【文档资料】注入文本（公开给测试断言格式）
  static String buildDocContextText(List<DocChunk> chunks) {
    final buf = StringBuffer('【文档资料】\n'
        '以下是本会话上传文档中与用户问题最相关的片段（按相关性选取）：\n\n');
    for (final c in chunks) {
      buf.writeln('${c.citation}\n${c.content}\n');
    }
    buf.write('回答时如引用上述内容，请在对应句子末尾标注来源，'
        '格式严格为【文件名·第N页】（如【报销制度.pdf·第3页】），'
        '未在上述片段中的信息不要标注，也不要编造页码。');
    return buf.toString();
  }

  /// 组装 API 请求消息：Agent system prompt 在头部 + 记忆注入 + 前情摘要 + 历史
  ///
  /// [forceSummary] 为 true 时（loop 轮数耗尽）追加系统提示强制模型总结。
  /// 记忆注入：Agent prompt 之后追加一条 system 消息（最近 20 条，
  /// 无记忆或未启用记忆服务时不注入）。
  /// F2 压缩：存在前情摘要时，摘要以 system 消息注入，历史只发送
  /// 摘要边界（firstKeptId）之后的原文——早期历史已被压缩进摘要；
  /// 钉住轮（pinnedIds 清单）在边界之前但原文保留，按原顺序捞回。
  List<Map<String, Object?>> _buildApiMessages({bool forceSummary = false}) {
    final prompt = _agent?.prompt;
    final summary = _contextSummary;
    // 摘要边界之后的历史（边界消息被删时按时间兜底）
    final history = summary == null
        ? _messages
        : _messages
            .skipWhile((m) =>
                m.id != summary.firstKeptId && m.createdAt < summary.firstKeptAt)
            .toList();
    // 钉住轮原文：边界之前的消息按 pinnedIds 清单捞回（保持原顺序）
    final pinnedKept = summary == null || summary.pinnedIds.isEmpty
        ? const <ChatMessage>[]
        : [
            for (final m in _messages)
              if (summary.pinnedIds.contains(m.id) &&
                  m.id != summary.firstKeptId &&
                  m.createdAt < summary.firstKeptAt)
                m,
          ];
    return [
      if (prompt != null && prompt.isNotEmpty)
        {'role': 'system', 'content': prompt},
      if (_memoryText != null && _memoryText!.isNotEmpty)
        {'role': 'system', 'content': _memoryText!},
      if (_docContextText != null && _docContextText!.isNotEmpty)
        {'role': 'system', 'content': _docContextText!},
      if (summary != null && summary.summary.isNotEmpty)
        {
          'role': 'system',
          'content': '【前情摘要】\n以下是本会话早期历史的压缩摘要，'
              '原文已省略。请结合摘要与后续对话继续：\n\n${summary.summary}',
        },
      ...pinnedKept.map((m) => m.toApiMessage()),
      ...history.map((m) => m.toApiMessage()),
      if (forceSummary)
        const {
          'role': 'system',
          'content': '工具调用轮数已达上限，请立即基于已有信息给出最终回答，不要再调用任何工具。',
        },
    ];
  }

  /// 把本轮 token 用量写到 assistant 消息上（落库前调用）
  ///
  /// 优先网关透传的真实 usage；无 usage 时本地估算兜底：
  /// prompt 用订阅前算好的 [_promptEstimate]，completion 按
  /// reasoning+content 字符数估。工具轮的 assistant 消息同样盖章。
  void _stampTokenUsage(ChatMessage msg) {
    msg.promptTokens =
        _roundPromptTokens ?? (_promptEstimate > 0 ? _promptEstimate : null);
    final completionEstimate =
        estimateTextTokens(msg.reasoning + msg.content);
    msg.completionTokens = _roundCompletionTokens ??
        (completionEstimate > 0 ? completionEstimate : null);
  }

  /// F5 上下文透视镜：预览下一轮请求将发送的完整 messages payload
  ///
  /// 复用 [_buildApiMessages]（Agent system prompt + 记忆注入 + 全部历史），
  /// 只读不落库。附件消息按 toApiMessage 的多模态结构原样展示。
  List<Map<String, Object?>> buildPayloadPreview() => _buildApiMessages();

  /// 生效的推理档位：Agent 预设优先于会话设置
  ///
  /// 会话 effort 是用户在聊天中可手动调整的值；Agent 预设只在
  /// 会话仍为初始默认值时生效，用户手动改过则以用户为准。
  /// F4 智能路由开启时：按本轮消息内容规则决策，覆盖以上全部
  /// （路由是「这一条消息该用多大力气」的即时判断，优先级最高）。
  String get _effectiveEffort {
    if (_smartRouteEffort != null) {
      return _smartRouteEffort!;
    }
    final agentEffort = _agent?.effort;
    if (agentEffort != null && _session.effort == 'max') {
      // 会话未手动调整过（保持默认 max），采用 Agent 预设
      return agentEffort;
    }
    return _session.effort;
  }

  /// F4 智能路由的本轮决策结果（null = 未启用或非路由决策）
  String? _smartRouteEffort;

  /// F4 智能路由开关（宿主从 SettingsService 传入；默认关）
  bool _smartRoutingEnabled;

  /// I13 保活通知开关（宿主从 SettingsService 读入；默认关 = 测试/
  /// 未注入场景不启动前台服务）
  bool _keepaliveNotification;

  /// 生效的温度：Agent 预设优先（会话级温度暂未开放手动调整）
  double get _effectiveTemperature => _agent?.temperature ?? 0.7;

  /// 思考用时（秒）
  int get thinkingSeconds {
    final start = _thinkingStart;
    if (start == null) return 0;
    return DateTime.now().difference(start).inSeconds;
  }

  /// 本轮生成用时（秒；I10 流式角标实时显示，思考+回答全程）
  int get generationSeconds {
    final start = _generationStart;
    if (start == null) return 0;
    return DateTime.now().difference(start).inSeconds;
  }

  /// 最近一次收尾的生成耗时（秒；null = 本会话尚无收尾记录）。
  /// 落库消息已带 generationSeconds，这里供流式收尾瞬间 UI 过渡读取
  int? get lastGenerationSeconds => _lastGenerationSeconds;

  /// 最近一轮是否被中断（I10 断流续传：true = 尾部显示「连接中断 ·
  /// 点击续传」）。手动停止/正常完成/出错均复位
  bool get lastRoundInterrupted => _lastRoundInterrupted;
  bool _lastRoundInterrupted = false;

  // ===== F6 同问双答 =====

  /// 双答目标（一次性消费）：sendDualMessage 读取后立即置 null。
  /// null = 用当前会话供应商自答（对照自身风格）；非空 = 跨厂商对照。
  /// 不持久化——双答是即时动作，重启后残留目标无意义
  (ProviderProfile, String)? _dualTarget;

  /// 双答进行中标记（UI：双答 tag 显示「双答中…」并禁点）
  bool _dualRunning = false;

  /// 双答进行中（两侧任一流未收尾都算；UI 显隐依据）
  bool get isDualRunning => _dualRunning;

  /// 待选择态：最后两条 assistant 消息互为姊妹（dualOf 互指）。
  /// 派生值无陈旧风险——chooseDual 删姊妹清标记后自然回到 false
  bool get isAwaitingDualChoice {
    final n = _messages.length;
    if (n < 2) return false;
    final a = _messages[n - 2];
    final b = _messages[n - 1];
    return a.role == 'assistant' &&
        b.role == 'assistant' &&
        a.dualOf == b.id &&
        b.dualOf == a.id;
  }

  /// 设置一次性双答目标（home_page 选择 sheet 调用；流式中禁止）
  Future<void> setDualTarget(ProviderProfile profile, String model) async {
    if (isStreaming || _dualRunning) return;
    _dualTarget = (profile, model);
  }

  String _genId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      (_messages.length.toString()) +
      _randomSuffix();

  /// 随机后缀：同微秒内多条消息（工具结果批量落库）防碰撞
  String _randomSuffix() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random();
    return [for (var i = 0; i < 4; i++) chars[rng.nextInt(chars.length)]].join();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _cancelToken?.cancel();
    _dualCancelToken?.cancel();
    // dispose 硬边界：后台 loop 的挂起链（工具执行/收尾写库）恢复时
    // 检查 _disposed 即退出，不再产生任何 DB 写（CI 取证：挂起链在
    // 测试 tearDown 换库后恢复，把上一用例残留写进新库）
    _streamingMessage = null;
    // 关闭底层 dio 连接池：切换会话会重建 ChatProvider，不关则每次
    // 切换泄漏一个 HttpClient 实例（连接与内存），累积加重 GC 卡顿
    _api.dispose();
    super.dispose();
  }
}

/// 工具调用分片累积器（OpenAI 流式：首片 id/name，后续片 arguments 增量）
class _ToolCallAccumulator {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}

/// T2 run_skill 委派桥宿主实现：从 ChatProvider 运行时状态取
/// profile/model/取消令牌，Skill 从 AgentService 查库
///
/// 宿主在构造后绑定（Dart 初始化列表不能引用 this）——绑定前调用
/// 委派方法抛 StateError（实际不可达：工具只在 loop 执行期间被调）。
class _HostRunSkillDelegate implements RunSkillDelegate {
  _HostRunSkillDelegate(this._agentService);

  final AgentService _agentService;

  ChatProvider? _host;

  /// 构造体补挂宿主（Dart 初始化列表不能引用 this）
  void _bindHost(ChatProvider host) => _host = host;

  @override
  (ProviderProfile, String) currentTarget() =>
      (_host!._profile, _host!._model);

  @override
  ApiService api() => _host!._api;

  @override
  CancelToken? currentCancelToken() => _host?._cancelToken;

  @override
  Future<Agent?> skillById(String id) => _agentService.getById(id);

  @override
  List<ToolHandler> toolCatalog() => _host!._toolCatalog;
}

/// 本地 token 估算：CJK 字符 ≈1 token/字，其他 ≈1 token/4 字符
///
/// 网关不透传 usage 时的兜底（F3）。粗估但量级正确——水位仪表盘
/// 的意义在趋势与相对水位，不在精确对账。
int estimateTextTokens(String text) {
  if (text.isEmpty) return 0;
  var cjk = 0;
  var other = 0;
  for (final rune in text.runes) {
    // CJK 统一表意文字 + 扩展 A + 兼容表意区
    if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0xF900 && rune <= 0xFAFF)) {
      cjk++;
    } else {
      other++;
    }
  }
  return cjk + (other / 4).ceil();
}

/// 估算一条 API 消息的 token 数（content 字符串或多模态数组）
///
/// 多模态：text 部分按文本估算，图片按定额 800 token/张
/// （glm-4v 类视觉模型典型值，量级参考用）。
int estimateMessageTokens(Map<String, Object?> message) {
  final content = message['content'];
  if (content is String) return estimateTextTokens(content);
  if (content is List) {
    var sum = 0;
    for (final part in content) {
      if (part is Map<String, dynamic>) {
        final text = part['text'];
        if (text is String) sum += estimateTextTokens(text);
        if (part['type'] == 'image_url') sum += 800;
      }
    }
    return sum;
  }
  return 0;
}

/// 估算整条请求的 prompt token（system + 记忆 + 历史 + 附加提示）
int estimatePromptTokens(List<Map<String, Object?>> messages) {
  var sum = 0;
  for (final m in messages) {
    sum += estimateMessageTokens(m);
    // 每条消息的角色/结构开销（OpenAI 经验值）
    sum += 4;
  }
  return sum;
}
