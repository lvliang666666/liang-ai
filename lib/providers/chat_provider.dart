import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/message_attachment.dart';
import '../models/provider_profile.dart';
import '../models/skill.dart';
import '../models/tool_call.dart';
import '../services/api_service.dart';
import '../services/database_service.dart';
import '../services/memory_service.dart';
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
    Skill? skill,
    List<ToolHandler> toolCatalog = builtinTools,
    MemoryService? memory,
  })  : _db = database,
        _api = api,
        _session = session,
        _profile = profile,
        _model = model,
        _skill = skill,
        _toolCatalog = toolCatalog,
        _memory = memory,
        _tools = _buildRegistry(skill, toolCatalog);

  final DatabaseService _db;
  ApiService _api;
  final ChatSession _session;
  ProviderProfile _profile;
  String _model;

  /// 用户长期记忆服务（null = 不启用记忆注入，兼容现有测试）
  MemoryService? _memory;

  /// 当前会话绑定的 Skill（null = 默认助手，无 system prompt + 全部工具）
  Skill? _skill;

  /// 工具目录（Skill 工具子集的选取范围）
  List<ToolHandler> _toolCatalog;

  /// 工具注册表（按 Skill.toolNames 从目录构建；null = 不启用工具；
  /// 是否随请求发送还看 profile 能力）
  ToolRegistry? _tools;

  /// 按 Skill 的工具子集声明从目录构建注册表
  ///
  /// toolNames null = 全部目录工具（默认助手/迁移老数据）；
  /// [] = 无工具；非空 = 指定子集（目录中不存在的名字忽略）。
  /// memory_save 工具按当前 Skill 注入来源名（记忆溯源）。
  static ToolRegistry _buildRegistry(
      Skill? skill, List<ToolHandler> catalog) {
    final registry = ToolRegistry();
    final allowed = skill?.toolNames;
    final selected = allowed == null
        ? catalog
        : catalog.where((t) => allowed.contains(t.name)).toList();
    registry.registerAll([
      for (final t in selected)
        t is MemorySaveTool
            ? MemorySaveTool(sourceSkill: skill?.name)
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
  Skill? get skill => _skill;
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
    _notify();
  }

  /// 发送消息（可带待发送附件队列）
  Future<void> sendMessage(String text) async {
    final content = text.trim();
    if ((content.isEmpty && _pendingAttachments.isEmpty) || isStreaming) {
      return;
    }

    _errorMessage = '';
    final now = DateTime.now().millisecondsSinceEpoch;

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

    // 2. 预取第一轮记忆注入文本（在 loop 启动前完成——loop 从启动到
    // 建立流订阅之间不能有 await，否则测试/调用方在 sendMessage 返回后
    // 立即 emit 的事件会因订阅未建立而丢失）
    await _refreshMemoryText();

    // 3. 启动 agentic loop（fire-and-forget：sendMessage 立即返回，
    // loop 在后台推进，与旧版「启动流即返回」语义一致）
    _toolResults = [];
    unawaited(_runLoop());
  }

  /// agentic loop：请求 → 流式收包 →（工具调用？执行 → 再请求）→ 收尾
  ///
  /// 每轮创建新的流式 assistant 消息；工具轮结束后 assistant 消息
  /// （含 tool_calls）立即落库，工具结果以 role='tool' 消息落库，
  /// 然后进入下一轮。取消 = 终止整个 loop，已落库内容保留。
  Future<void> _runLoop() async {
    for (var iteration = 0; iteration < _maxLoopIterations; iteration++) {
      // 超上限保护：最后一轮注入系统提示强制模型总结
      final forceSummary = iteration == _maxLoopIterations - 1;

      // 创建本轮流式 assistant 消息
      _streamingMessage = ChatMessage(
        id: _genId(),
        sessionId: _session.id,
        role: 'assistant',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _status = ChatStatus.thinking;
      _thinkingStart ??= DateTime.now();
      _notify();

      // 发起流式请求（Agent system prompt 插入消息头部）
      _cancelToken = CancelToken();
      final history = _buildApiMessages(forceSummary: forceSummary);
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
            case SseToolCallsFinished():
              toolRoundStarted = true;
              if (!completer.isCompleted) completer.complete();
            case SseDone():
              // 工具轮后服务端常尾随 [DONE]：此时本轮已交给工具流程，忽略
              if (toolRoundStarted) return;
              _finishStreaming();
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
    final assistantMsg = _streamingMessage!;
    assistantMsg.toolCalls = calls;
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
      _subscription = null;
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

  /// 正常结束：落库 assistant 消息
  void _finishStreaming() {
    final msg = _streamingMessage;
    if (msg != null) {
      // 空消息（取消时刚创建、未收到任何内容）不落库
      if (msg.content.isNotEmpty ||
          msg.reasoning.isNotEmpty ||
          msg.toolCalls.isNotEmpty) {
        _db.insertMessage(msg);
        _messages = [..._messages, msg];
      }
    }
    _streamingMessage = null;
    _status = ChatStatus.idle;
    _subscription = null;
    _cancelToken = null;
    _toolCallAccumulators.clear();
    _thinkingStart = null;
    _notify();
  }

  /// 出错：保留已收内容落库，显示错误
  void _failStreaming(String message) {
    final msg = _streamingMessage;
    if (msg != null && (msg.content.isNotEmpty || msg.reasoning.isNotEmpty)) {
      _db.insertMessage(msg);
      _messages = [..._messages, msg];
    }
    _streamingMessage = null;
    _status = ChatStatus.error;
    _errorMessage = message;
    _subscription = null;
    _cancelToken = null;
    _toolCallAccumulators.clear();
    _thinkingStart = null;
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

  /// 切换会话绑定的 Skill（null = 默认助手）
  ///
  /// 同步按新 Skill 的工具子集重建注册表，下一轮请求即生效。
  Future<void> setSkill(Skill? skill) async {
    if (_skill?.id == skill?.id) return;
    _skill = skill;
    _tools = _buildRegistry(skill, _toolCatalog);
    await _db.updateSessionSkill(_session.id, skill?.id);
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

  /// 组装 API 请求消息：Skill system prompt 在头部 + 记忆注入 + 全部历史
  ///
  /// [forceSummary] 为 true 时（loop 轮数耗尽）追加系统提示强制模型总结。
  /// 记忆注入：Skill prompt 之后追加一条 system 消息（最近 20 条，
  /// 无记忆或未启用记忆服务时不注入）。
  List<Map<String, Object?>> _buildApiMessages({bool forceSummary = false}) {
    final prompt = _skill?.prompt;
    return [
      if (prompt != null && prompt.isNotEmpty)
        {'role': 'system', 'content': prompt},
      if (_memoryText != null && _memoryText!.isNotEmpty)
        {'role': 'system', 'content': _memoryText!},
      ..._messages.map((m) => m.toApiMessage()),
      if (forceSummary)
        const {
          'role': 'system',
          'content': '工具调用轮数已达上限，请立即基于已有信息给出最终回答，不要再调用任何工具。',
        },
    ];
  }

  /// 生效的推理档位：Skill 预设优先于会话设置
  ///
  /// 会话 effort 是用户在聊天中可手动调整的值；Skill 预设只在
  /// 会话仍为初始默认值时生效，用户手动改过则以用户为准。
  String get _effectiveEffort {
    final skillEffort = _skill?.effort;
    if (skillEffort != null && _session.effort == 'max') {
      // 会话未手动调整过（保持默认 max），采用 Skill 预设
      return skillEffort;
    }
    return _session.effort;
  }

  /// 生效的温度：Skill 预设优先（会话级温度暂未开放手动调整）
  double get _effectiveTemperature => _skill?.temperature ?? 0.7;

  /// 思考用时（秒）
  int get thinkingSeconds {
    final start = _thinkingStart;
    if (start == null) return 0;
    return DateTime.now().difference(start).inSeconds;
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
