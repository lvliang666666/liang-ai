import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/context_summary.dart';
import '../models/message_attachment.dart';
import '../models/provider_profile.dart';
import '../models/agent.dart';
import '../models/tool_call.dart';
import '../services/api_service.dart';
import '../services/context_summary_service.dart';
import '../services/database_service.dart';
import '../services/generation_keepalive.dart';
import '../services/memory_service.dart';
import '../services/smart_router.dart';
import '../services/sse_parser.dart';
import '../services/tool_registry.dart';
import '../services/tools/builtin_tools.dart';

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
        _tools = _buildRegistry(agent, toolCatalog, sessionId: session.id);

  final DatabaseService _db;
  ApiService _api;
  final ChatSession _session;
  ProviderProfile _profile;
  String _model;

  /// 用户长期记忆服务（null = 不启用记忆注入，兼容现有测试）
  MemoryService? _memory;

  /// F2 上下文压缩服务（水位检查 + 摘要生成）
  final ContextSummaryService _summaryService;

  /// 当前会话的前情摘要（null = 未压缩过；loadMessages 时从 DB 读）
  ContextSummary? _contextSummary;

  /// 当前会话绑定的 Agent（null = 默认助手，无 system prompt + 全部工具）
  Agent? _agent;

  /// 工具目录（Agent 工具子集的选取范围）
  List<ToolHandler> _toolCatalog;

  /// 工具注册表（按 Agent.toolNames 从目录构建；null = 不启用工具；
  /// 是否随请求发送还看 profile 能力）
  ToolRegistry? _tools;

  /// 按 Agent 的工具子集声明从目录构建注册表
  ///
  /// toolNames null = 全部目录工具（默认助手/迁移老数据）；
  /// [] = 无工具；非空 = 指定子集（目录中不存在的名字忽略）。
  /// memory_save 工具按当前 Agent 注入来源名（记忆溯源）；
  /// search_history 工具注入当前会话 id（检索时排除本会话）。
  static ToolRegistry _buildRegistry(
      Agent? agent, List<ToolHandler> catalog,
      {String? sessionId}) {
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

  /// dispose 标记：loop 在后台推进，dispose 后不再通知 UI
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

  /// 页面渲染用的完整消息列表（含流式中消息）
  List<ChatMessage> get displayMessages {
    if (_streamingMessage == null) return _messages;
    return [..._messages, _streamingMessage!];
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
  bool addAttachment(MessageAttachment attachment) {
    final images = _pendingAttachments.where((a) => a.isImage).length;
    final files = _pendingAttachments.where((a) => a.isFile).length;
    if (attachment.isImage && images >= 3) return false;
    if (attachment.isFile && files >= 3) return false;
    _pendingAttachments = [..._pendingAttachments, attachment];
    _notify();
    return true;
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

    // 删除该 assistant 消息及其后全部消息（含 tool 结果等中间产物）
    final orphans = _messages.skip(idx).toList();
    for (final m in orphans) {
      await _db.deleteMessage(m.id);
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
    _toolResults = results;

    // 4. 每个结果生成 role='tool' 消息落库
    var at = DateTime.now().millisecondsSinceEpoch;
    for (final r in results) {
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

  /// 停止生成（保留已收内容）
  void stopGeneration() {
    _cancelToken?.cancel();
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
    _tools = _buildRegistry(agent, _toolCatalog, sessionId: _session.id);
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
