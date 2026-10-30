/// Agentic loop 纯 Dart 编排器（E9 ChatProvider 瘦身）
///
/// 复刻 SseParser 的架构决策：把 ChatProvider 内嵌的多轮工具编排
/// （请求 → 流式收包 → 工具执行 → 再请求）抽成不依赖 Flutter 的纯
/// Dart 编排器——可用假 service 单测，ChatProvider 退化为「订阅事件
/// → 映射状态机」的宿主。
///
/// 职责边界：
/// - 编排器拥有：轮次循环、流式订阅、工具分片累积、token/耗时盖章、
///   占位消息生命周期（创建/落库/删除）、每轮取消令牌的登记
/// - 宿主拥有：UI 状态机（ChatStatus/消息列表）、payload 组装
///   （system prompt/记忆/摘要注入）、保活服务、dispose 语义
///
/// 事件通过 [ChatOrchestrator.run] 的回调**同步派发**——保证宿主在
/// 下一轮请求组装前已把工具轮消息并入历史（buildMessages 回调读取
/// 宿主状态，异步流会破坏这一时序）。
///
/// 时序契约：从 [ChatOrchestrator.run] 进入到 stream.listen 建立之间
/// 不允许有任何 await——宿主/测试在触发运行后立即发事件，订阅未建立
/// 会丢事件（广播流不缓冲）。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../models/chat_message.dart';
import '../models/provider_profile.dart';
import '../models/tool_call.dart';
import 'api_service.dart';
import 'sse_parser.dart';
import 'tool_registry.dart';

/// 编排事件基类（同步派发给宿主，宿主据此映射 UI 状态机）
sealed class OrchestratorEvent {
  const OrchestratorEvent();
}

/// 一轮开始：流式占位消息已创建并落库（interrupted 预置 true）。
/// 消息实例由编排器持有并持续变异，宿主直接渲染同一实例
class OrchRoundStarted extends OrchestratorEvent {
  const OrchRoundStarted(this.message);

  final ChatMessage message;
}

/// 思考增量（编排器已把文本追加到占位消息的 reasoning）
class OrchReasoningDelta extends OrchestratorEvent {
  const OrchReasoningDelta(this.text);

  final String text;
}

/// 正文增量（编排器已把文本追加到占位消息的 content）
class OrchContentDelta extends OrchestratorEvent {
  const OrchContentDelta(this.text);

  final String text;
}

/// 工具轮开始：assistant（含 tool_calls）已落库，宿主应并入历史
class OrchToolRoundStarted extends OrchestratorEvent {
  const OrchToolRoundStarted(this.message, this.calls);

  final ChatMessage message;
  final List<ToolCall> calls;
}

/// 工具执行完毕：结果与 role='tool' 消息均已落库，宿主应并入历史
class OrchToolResults extends OrchestratorEvent {
  const OrchToolResults(this.results, this.messages);

  final List<ToolCallResult> results;
  final List<ChatMessage> messages;
}

/// 工具执行期间用户取消：loop 终止，已落库内容保留
///
/// 与 [OrchFinished] 分立的原因：旧实现此路径**不重置**思考/生成
/// 计时与中断标记（逐字段对齐），而正常收尾会重置。
class OrchToolRoundCancelled extends OrchestratorEvent {
  const OrchToolRoundCancelled();
}

/// 正常收尾（完成/手动停止/轮数耗尽）：消息已落库；空占位已删除
///（message 为 null）
class OrchFinished extends OrchestratorEvent {
  const OrchFinished(this.message);

  final ChatMessage? message;
}

/// 断流收尾（I10）：半截内容已落库并标中断；空占位保留在库
///（message 为 null——与旧实现一致，由启动扫描兜底）
class OrchInterrupted extends OrchestratorEvent {
  const OrchInterrupted(this.message);

  final ChatMessage? message;
}

/// 出错收尾：半截内容已落库；空占位保留在库（message 为 null）
class OrchFailed extends OrchestratorEvent {
  const OrchFailed(this.error, this.message);

  final String error;
  final ChatMessage? message;
}

/// agentic loop 编排器（一次性对象：每次生成由宿主新建实例）
///
/// 宿主通过函数依赖注入运行时状态（profile/model 可中途切换，每轮
/// 请求时实时解析）；编排器不感知 UI 与数据库实现。
class ChatOrchestrator {
  ChatOrchestrator({
    required this.api,
    required this.sessionId,
    required this.resolveProfile,
    required this.resolveModel,
    required this.resolveEffort,
    required this.resolveTemperature,
    required this.resolveRegistry,
    required this.resolveToolsPayload,
    required this.buildMessages,
    required this.refreshMemoryText,
    required this.insertMessage,
    required this.deleteMessage,
    required this.genId,
    required this.isDisposed,
    required this.onRoundCancelToken,
  });

  final ApiService api;
  final String sessionId;

  /// 请求参数实时解析（每轮发起请求时求值，与旧实现读实例字段一致）
  final ProviderProfile Function() resolveProfile;
  final String Function() resolveModel;
  final String Function() resolveEffort;
  final double Function() resolveTemperature;

  /// 工具注册表实时解析（setAgent 可在轮间重建注册表）
  final ToolRegistry? Function() resolveRegistry;

  /// 是否随请求发送工具（null = 不发送；能力位 + 注册表判空由宿主合成）
  final List<Map<String, Object?>>? Function() resolveToolsPayload;

  /// 组装请求消息（Agent prompt/记忆/摘要/历史由宿主拼装）
  final List<Map<String, Object?>> Function(bool forceSummary) buildMessages;

  /// 工具轮之间刷新记忆注入文本（工具可能刚存了新记忆）
  final Future<void> Function() refreshMemoryText;

  /// 消息落库（宿主桥接 DB；失败向上抛由宿主兜底日志）
  final Future<void> Function(ChatMessage message) insertMessage;

  /// 删除消息（空占位清理）
  final Future<void> Function(String messageId) deleteMessage;

  /// 消息 id 生成（宿主提供，保证全 App 同一规则）
  final String Function() genId;

  /// dispose 硬边界谓词：每个 await 恢复点检查，置位即退出不再写库
  ///（CI 取证：挂起的工具轮写库链在测试 tearDown 换库后恢复，会把
  /// 上一用例的残留消息写进新库）
  final bool Function() isDisposed;

  /// 每轮取消令牌登记（宿主据此实现停止键与 run_skill 子循环的中止）
  final void Function(CancelToken? token) onRoundCancelToken;

  /// agentic loop 最大轮数（防死循环 + token 膨胀）
  static const maxLoopIterations = 8;

  // ===== 单次生成运行的状态 =====
  ChatMessage? _streamingMessage;

  /// 工具调用分片累积（按 index 拼接，SseToolCallsFinished 时成完整调用）
  final Map<int, _ToolCallAccumulator> _toolCallAccumulators = {};

  /// 本轮 usage 统计（SseUsage 末帧捕获；null = 网关未透传，走估算）
  int? _roundPromptTokens;
  int? _roundCompletionTokens;

  /// 本轮发起请求前的 prompt 估算（订阅前算好，供无 usage 时兜底）
  int _promptEstimate = 0;
  DateTime? _thinkingStart;
  DateTime? _generationStart;
  CancelToken? _cancelToken;
  StreamSubscription<SseEvent>? _subscription;

  /// 本轮是否已走收尾路径（防重复收尾——等价旧实现的 isStreaming 守卫）
  bool _roundSettled = false;

  /// 用户请求停止：只取消当前轮令牌
  ///
  /// 取消令牌 → dio 中止请求 → 流上抛 cancel 错误 → onError 走
  /// 正常收尾（保留已收内容）。**不断开订阅**——收尾错误本身要经
  /// 这条订阅送达（宿主/测试在 stopGeneration 后 emit cancel 错误
  /// 的模式依赖它）；收尾后 loop 会自行取消订阅。dispose 场景的
  /// 「不再消费事件」由各收尾路径的 isDisposed 守卫保证，不靠断订阅。
  void cancel() {
    _cancelToken?.cancel();
  }

  /// 运行 agentic loop：请求 → 流式收包 →（工具调用？执行 → 再请求）→ 收尾
  ///
  /// 每轮创建新的流式 assistant 消息；工具轮结束后 assistant 消息
  /// （含 tool_calls）立即落库，工具结果以 role='tool' 消息落库，
  /// 然后进入下一轮。取消 = 终止整个 loop，已落库内容保留。
  /// [onEvent] 同步派发编排事件（见库注释）。
  Future<void> run(void Function(OrchestratorEvent event) onEvent) async {
    for (var iteration = 0; iteration < maxLoopIterations; iteration++) {
      // dispose 硬边界：宿主已销毁（切会话/测试 tearDown），立即退出，
      // 不再创建占位消息、不再发起请求、不再写库
      if (isDisposed()) return;
      // 超上限保护：最后一轮注入系统提示强制模型总结
      final forceSummary = iteration == maxLoopIterations - 1;
      _roundSettled = false;

      // 创建本轮流式 assistant 消息（E5：interrupted 预置 true——
      // 占位即「未收尾」，正常收尾时覆写复位）
      final placeholder = ChatMessage(
        id: genId(),
        sessionId: sessionId,
        role: 'assistant',
        interrupted: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _streamingMessage = placeholder;
      _thinkingStart ??= DateTime.now();
      // 生成起点首轮记一次（工具轮跨轮累计，不重置）
      _generationStart ??= DateTime.now();
      // E5：流式开始即落库占位（interrupted=1）——App 被杀时消息已在
      // DB，启动扫描能识别「未收尾」；正常收尾时覆写为完整内容
      _persistQuietly(insertMessage(placeholder));
      onEvent(OrchRoundStarted(placeholder));

      // 发起流式请求（此处到 listen 之间不允许有 await——时序契约）
      _cancelToken = CancelToken();
      onRoundCancelToken(_cancelToken);
      final history = buildMessages(forceSummary);
      // F3：本轮 token 统计复位 + prompt 估算（订阅前完成，无 await 间隙）
      _roundPromptTokens = null;
      _roundCompletionTokens = null;
      _promptEstimate = estimatePromptTokens(history);
      final completer = Completer<void>();
      // 本轮是否已进入工具执行流程（防止 [DONE] 尾随分片重复收尾）
      var toolRoundStarted = false;

      _subscription = api
          .chatStream(
        profile: resolveProfile(),
        messages: history,
        model: resolveModel(),
        effort: resolveEffort(),
        cancelToken: _cancelToken!,
        temperature: resolveTemperature(),
        tools: resolveToolsPayload(),
      )
          .listen(
        (event) {
          switch (event) {
            case SseDeltaReasoning(:final text):
              _streamingMessage = _streamingMessage!..reasoning += text;
              onEvent(OrchReasoningDelta(text));
            case SseDeltaContent(:final text):
              _streamingMessage = _streamingMessage!..content += text;
              onEvent(OrchContentDelta(text));
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
              _finishNormal(onEvent);
              if (!completer.isCompleted) completer.complete();
            case SseInterrupted():
              // I10 断流：连接断开未收到 [DONE]——保留已收内容落库，
              // 标记中断态供 UI 显示「连接中断 · 点击续传」
              if (toolRoundStarted) return;
              _finishInterrupted(onEvent);
              if (!completer.isCompleted) completer.complete();
            case SseError(:final message):
              if (toolRoundStarted) return;
              _finishFailed(message, onEvent);
              if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (Object e) {
          if (e is DioException && e.type == DioExceptionType.cancel) {
            _finishNormal(onEvent); // 手动停止：保留已收内容
          } else if (e is ApiException) {
            _finishFailed(e.message, onEvent);
          } else {
            _finishFailed('请求失败：$e', onEvent);
          }
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          // 等价旧实现 isStreaming 守卫：收尾路径已跑过则跳过
          if (!_roundSettled) _finishNormal(onEvent);
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future;
      // 旧订阅不再需要：广播流下不取消会重复消费下一轮事件
      await _subscription?.cancel();
      _subscription = null;

      // 流结束后判定：收尾路径已跑（完成/中断/出错/取消）→ loop 结束；
      // 未收尾 = 工具轮（SseToolCallsFinished）→ 执行工具 → 下一轮
      if (_roundSettled) return;
      final continueLoop = await _executeToolRound(onEvent);
      if (!continueLoop) return;
    }
    // 轮数耗尽（理论上 forceSummary 已让模型收尾，这里兜底）
    _finishNormal(onEvent);
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
  Future<bool> _executeToolRound(
      void Function(OrchestratorEvent) onEvent) async {
    // dispose 硬边界：completer 恢复后宿主可能已销毁（测试 tearDown
    // 关库/切会话），继续走会把上一宿主的消息写进新库
    if (isDisposed()) return false;
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
    await insertMessage(assistantMsg);
    _streamingMessage = null;
    onEvent(OrchToolRoundStarted(assistantMsg, calls));

    // 3. 逐个执行工具（toolCalling 态供 UI 显示进度，由事件宿主映射）
    final registry = resolveRegistry();
    final results = await registry!.executeAll(calls);
    // dispose 硬边界：工具执行期间宿主可能已销毁——结果不再落库，
    // loop 终止（已落库的 assistant(tool_calls) 保留，与取消同语义）
    if (isDisposed()) return false;

    // 4. 每个结果生成 role='tool' 消息落库
    final toolMessages = <ChatMessage>[];
    var at = DateTime.now().millisecondsSinceEpoch;
    for (final r in results) {
      // dispose 硬边界：批量落库中途被销毁，剩余结果不再写库
      if (isDisposed()) return false;
      final toolMsg = ChatMessage(
        id: genId(),
        sessionId: sessionId,
        role: 'tool',
        content: r.content,
        toolCallId: r.callId,
        createdAt: at++,
      );
      await insertMessage(toolMsg);
      toolMessages.add(toolMsg);
    }
    onEvent(OrchToolResults(results, toolMessages));

    // 5. 取消检查：用户在工具执行期间点了停止 → 终止 loop（已落库保留）
    if (_cancelToken?.isCancelled == true) {
      _cancelToken = null;
      onRoundCancelToken(null);
      onEvent(const OrchToolRoundCancelled());
      return false;
    }

    // 6. 刷新记忆注入文本（工具轮可能刚存了新记忆；此处已有大量 await，
    // 不影响「订阅建立前无 await」的时序契约）
    await refreshMemoryText();

    // 7. 继续下一轮
    return true;
  }

  /// 正常结束：落库 assistant 消息（空占位删除）
  ///
  /// 同步改收尾标记 + fire-and-forget 落库（与旧版语义一致：调用方在
  /// completer 完成后立即读事件；DB 断言经同一队列天然有序）。
  void _finishNormal(void Function(OrchestratorEvent) onEvent) {
    if (_roundSettled) return;
    _roundSettled = true;
    // dispose 硬边界：dispose 后 DB 已关（或已被下一用例换库），
    // 收尾写库只会污染新库——直接放弃，E5 占位残留由启动扫描兜底
    if (isDisposed()) return;
    final msg = _streamingMessage;
    ChatMessage? kept;
    if (msg != null) {
      if (msg.content.isNotEmpty ||
          msg.reasoning.isNotEmpty ||
          msg.toolCalls.isNotEmpty) {
        _stampTokenUsage(msg);
        _stampDurations(msg);
        // E5 占位覆写：正常收尾 = interrupted 复位（toMap 写 0，
        // ConflictAlgorithm.replace 覆盖占位的 1）
        msg.interrupted = false;
        _persistQuietly(insertMessage(msg));
        kept = msg;
      } else {
        // 空消息（取消时刚创建、未收到任何内容）：E5 占位已落库，
        // 删除之，否则启动扫描会误报「已中断」
        _persistQuietly(deleteMessage(msg.id));
      }
    }
    _streamingMessage = null;
    _cancelToken = null;
    onRoundCancelToken(null);
    _toolCallAccumulators.clear();
    _thinkingStart = null;
    _generationStart = null;
    onEvent(OrchFinished(kept));
  }

  /// 断流收尾（I10）：保留已收内容落库 + 标记中断态
  ///
  /// 与 [_finishFailed] 的区别：断流不是错误（网络抖动是常态），
  /// 不弹错误条，而是尾部显示「连接中断 · 点击续传」胶囊——
  /// 已收内容照常落库展示，用户可一键续传。
  void _finishInterrupted(void Function(OrchestratorEvent) onEvent) {
    if (_roundSettled) return;
    _roundSettled = true;
    // dispose 硬边界：同 _finishNormal——dispose 后不再写库
    if (isDisposed()) return;
    final msg = _streamingMessage;
    ChatMessage? kept;
    if (msg != null && (msg.content.isNotEmpty || msg.reasoning.isNotEmpty)) {
      _stampTokenUsage(msg);
      _stampDurations(msg);
      msg.interrupted = true; // E5：中断消息持久标记（重启后仍可识别）
      _persistQuietly(insertMessage(msg));
      kept = msg;
    }
    _streamingMessage = null;
    _cancelToken = null;
    onRoundCancelToken(null);
    _toolCallAccumulators.clear();
    _thinkingStart = null;
    _generationStart = null;
    onEvent(OrchInterrupted(kept));
  }

  /// 出错：保留已收内容落库，宿主显示错误
  void _finishFailed(
      String message, void Function(OrchestratorEvent) onEvent) {
    if (_roundSettled) return;
    _roundSettled = true;
    // dispose 硬边界：同 _finishNormal——dispose 后不再写库
    if (isDisposed()) return;
    final msg = _streamingMessage;
    ChatMessage? kept;
    if (msg != null && (msg.content.isNotEmpty || msg.reasoning.isNotEmpty)) {
      _stampTokenUsage(msg);
      _stampDurations(msg);
      msg.interrupted = true; // E5：错误半截消息同样标中断（可重答）
      _persistQuietly(insertMessage(msg));
      kept = msg;
    }
    _streamingMessage = null;
    _cancelToken = null;
    onRoundCancelToken(null);
    _toolCallAccumulators.clear();
    _thinkingStart = null;
    _generationStart = null;
    onEvent(OrchFailed(message, kept));
  }

  /// fire-and-forget 落库的统一容错：失败静默（dispose 后 DB 已关是
  /// 正常时序，绝不让异常逃到 zone 炸测试/崩溃；awaited 落库失败则
  /// 向上传播，由宿主的 loop 级 catchError 兜底日志）
  void _persistQuietly(Future<void> future) {
    unawaited(future.catchError((Object e) {}));
  }

  /// 把本轮 token 用量写到 assistant 消息上（落库前调用）
  ///
  /// 优先网关透传的真实 usage；无 usage 时本地估算兜底：
  /// prompt 用订阅前算好的 [_promptEstimate]，completion 按
  /// reasoning+content 字符数估。工具轮的 assistant 消息同样盖章。
  void _stampTokenUsage(ChatMessage msg) {
    msg.promptTokens =
        _roundPromptTokens ?? (_promptEstimate > 0 ? _promptEstimate : null);
    final completionEstimate = estimateTextTokens(msg.reasoning + msg.content);
    msg.completionTokens = _roundCompletionTokens ??
        (completionEstimate > 0 ? completionEstimate : null);
  }

  /// 耗时盖章（I10）：思考秒数 + 生成总秒数写到消息上（落库前调用）。
  /// 思考耗时 = 思考起点到收尾；生成耗时 = 本轮生成起点到收尾
  ///（工具轮跨轮累计）
  void _stampDurations(ChatMessage msg) {
    final thinkStart = _thinkingStart;
    if (thinkStart != null) {
      msg.thinkingSeconds = DateTime.now().difference(thinkStart).inSeconds;
    }
    final genStart = _generationStart;
    if (genStart != null) {
      final seconds = DateTime.now().difference(genStart).inSeconds;
      msg.generationSeconds = seconds;
    }
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
///（glm-4v 类视觉模型典型值，量级参考用）。
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
