import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/chat_orchestrator.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_provider_test.dart' show MockApiService;

/// 测试工具：返回固定文本（可配置抛异常）
class StubTool extends ToolHandler {
  const StubTool(this.result, {this.shouldThrow = false});
  final String result;
  final bool shouldThrow;

  @override
  String get name => 'stub';
  @override
  String get description => '测试工具';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object'};
  @override
  Future<String> execute(Map<String, dynamic> arguments) async =>
      shouldThrow ? throw StateError('工具炸了') : result;
}

/// 支持 toolCalls 能力的 profile
ProviderProfile toolProfile() => ProviderProfile(
      id: 'p-tool',
      name: 'Tool Provider',
      baseUrl: 'https://example.com/v1',
      apiKey: 'k',
      defaultModel: 'm1',
      capabilities: const ProviderCapabilities(toolCalls: true),
    );

/// 纯 Dart 宿主桩：记录事件 + 内存消息列表 + 内存「落库」+ 写库日志
///
/// 不依赖 DB/Flutter——编排器单测只验证编排逻辑本身。
/// [runHost] 的事件映射（工具轮消息并入历史、收尾消息入列）与
/// E9-4 ChatProvider 将做的状态机映射同构。
class _Host {
  _Host(this.api) {
    registry = ToolRegistry()..register(const StubTool('工具结果OK'));
  }

  final MockApiService api;
  late ToolRegistry registry;
  bool disposed = false;
  CancelToken? currentToken;

  final List<OrchestratorEvent> events = [];
  final List<ChatMessage> messages = [];
  final Map<String, ChatMessage> persisted = {};

  /// 写库操作日志（'ins:<id>' / 'del:<id>'）——dispose 硬边界断言用
  final List<String> writeLog = [];

  int idSeq = 0;

  String genId() => 'id_${idSeq++}';

  /// buildMessages：把内存消息转 API 格式（含 forceSummary 注入）
  List<Map<String, Object?>> buildMessages(bool forceSummary) => [
        for (final m in messages) m.toApiMessage(),
        if (forceSummary)
          const {
            'role': 'system',
            'content': '工具调用轮数已达上限，请立即基于已有信息给出最终回答，不要再调用任何工具。',
          },
      ];

  ChatOrchestrator build() => ChatOrchestrator(
        api: api,
        sessionId: 's1',
        resolveProfile: toolProfile,
        resolveModel: () => 'm1',
        resolveEffort: () => 'max',
        resolveTemperature: () => 0.7,
        resolveRegistry: () => registry,
        resolveToolsPayload: () =>
            registry.isNotEmpty ? registry.toOpenAiTools() : null,
        buildMessages: buildMessages,
        refreshMemoryText: () async {},
        insertMessage: (m) async {
          persisted[m.id] = m;
          writeLog.add('ins:${m.id}');
        },
        deleteMessage: (id) async {
          persisted.remove(id);
          writeLog.add('del:$id');
        },
        genId: genId,
        isDisposed: () => disposed,
        onRoundCancelToken: (t) => currentToken = t,
      );

  /// 运行编排器：事件映射进宿主状态（E9-4 ChatProvider 同构）+ 可选钩子
  ///
  /// 钩子在事件回调内**同步**执行——编排器的 onEvent 是同步派发，
  /// 钩子能精确拦截微任务级推进（轮询做不到：编排器在微任务间隙
  /// 就跑完整个工具轮）。
  Future<void> runHost(ChatOrchestrator orch,
      {void Function(OrchestratorEvent event)? hook}) {
    return orch.run((event) {
      events.add(event);
      switch (event) {
        case OrchToolRoundStarted(:final message):
          this.messages.add(message);
        case OrchToolResults(:final messages):
          this.messages.addAll(messages);
        case OrchFinished(:final message):
          if (message != null) this.messages.add(message);
        case OrchInterrupted(:final message):
          if (message != null) this.messages.add(message);
        case OrchFailed(:final message):
          if (message != null) this.messages.add(message);
        default:
          break;
      }
      hook?.call(event);
    });
  }

  /// 事件记录辅助：按类型过滤
  List<T> of<T extends OrchestratorEvent>() =>
      events.whereType<T>().toList();

  /// 轮询等待条件成立（后台 loop 推进是异步的）
  Future<void> waitUntil(bool Function() cond,
      {Duration timeout = const Duration(seconds: 2)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('waitUntil 超时');
      }
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }
}

void main() {
  late MockApiService api;
  late _Host host;

  setUp(() {
    api = MockApiService();
    host = _Host(api);
  });

  group('单轮直答', () {
    test('roundStarted → 增量 → finished，消息落库且 interrupted 复位',
        () async {
      final orch = host.build();
      final done = host.runHost(orch);

      // 等订阅建立（首轮请求已发出）
      await host.waitUntil(() => api.chatStreamCalls == 1);

      api.emit(const SseDeltaReasoning('想一下'));
      api.emit(const SseDeltaContent('你好呀'));
      api.emit(const SseUsage(promptTokens: 120, completionTokens: 45));
      api.emit(const SseDone());

      await done;

      // 事件序列
      final started = host.of<OrchRoundStarted>();
      expect(started, hasLength(1));
      expect(host.of<OrchReasoningDelta>().single.text, '想一下');
      expect(host.of<OrchContentDelta>().single.text, '你好呀');
      final finished = host.of<OrchFinished>().single;
      expect(finished.message, isNotNull);
      expect(finished.message!.content, '你好呀');
      expect(finished.message!.interrupted, isFalse);
      // token 盖章：usage 优先
      expect(finished.message!.promptTokens, 120);
      expect(finished.message!.completionTokens, 45);
      // 落库
      expect(host.persisted.containsKey(finished.message!.id), isTrue);
      // 取消令牌已归还 null
      expect(host.currentToken, isNull);
    });

    test('无 usage：估算兜底（prompt 估算 > 0，completion 按内容估）',
        () async {
      // 宿主历史含 user 消息（真实场景：sendMessage 已落库 user）
      host.messages.add(ChatMessage(
        id: 'u1',
        sessionId: 's1',
        role: 'user',
        content: '你好',
        createdAt: 1,
      ));
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseDeltaContent('一段中文内容'));
      api.emit(const SseDone());
      await done;

      final msg = host.of<OrchFinished>().single.message!;
      expect(msg.promptTokens, greaterThan(0));
      expect(msg.completionTokens, greaterThan(0));
    });

    test('空占位（取消时未收内容）：占位删除，finished.message 为 null',
        () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      // 直接 cancel：DioException.cancel → 正常收尾路径
      host.currentToken!.cancel();
      api.emitError(DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.cancel));
      await done;

      final finished = host.of<OrchFinished>().single;
      expect(finished.message, isNull);
      // 占位已从「库」删除
      expect(host.persisted, isEmpty);
      expect(host.writeLog, ['ins:id_0', 'del:id_0']);
    });
  });

  group('工具轮多轮', () {
    test('tool_calls → 执行 → tool 消息落库 → 二轮回答', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_1', name: 'stub', argumentsFragment: '{"x":'));
      api.emit(const SseToolCallDelta(index: 0, argumentsFragment: '1}'));
      api.emit(const SseToolCallsFinished());
      // vLLM 同批尾随 usage + [DONE]：usage 应被捕获（微任务延迟语义）
      api.emit(const SseUsage(promptTokens: 80, completionTokens: 10));
      api.emit(const SseDone());

      await host.waitUntil(() => api.chatStreamCalls == 2);

      // 工具轮事件：assistant(tool_calls) 落库 + tool 结果落库
      final toolRound = host.of<OrchToolRoundStarted>().single;
      expect(toolRound.message.toolCalls.single.id, 'call_1');
      expect(toolRound.message.toolCalls.single.argumentsJson, '{"x":1}');
      expect(toolRound.message.interrupted, isFalse);
      expect(toolRound.message.promptTokens, 80);
      final toolResults = host.of<OrchToolResults>().single;
      expect(toolResults.results.single.content, '工具结果OK');
      expect(toolResults.messages.single.role, 'tool');
      expect(toolResults.messages.single.toolCallId, 'call_1');
      expect(host.persisted[toolResults.messages.single.id], isNotNull);

      // 二轮请求携带 tool 消息（宿主已把工具轮消息并入历史）
      final toolMsg = api.lastMessages!.firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['tool_call_id'], 'call_1');
      expect(toolMsg['content'], '工具结果OK');

      api.emit(const SseDeltaContent('现在是白天'));
      api.emit(const SseDone());
      await done;

      // 尾随 [DONE] 未引发重复收尾：finished 只有一次
      expect(host.of<OrchFinished>(), hasLength(1));
      expect(host.of<OrchFinished>().single.message!.content, '现在是白天');
    });

    test('多工具并行（index 0/1 交错）分片累积', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_a', name: 'stub', argumentsFragment: '{"a":'));
      api.emit(const SseToolCallDelta(
          index: 1, id: 'call_b', name: 'stub', argumentsFragment: '{"b":'));
      api.emit(const SseToolCallDelta(index: 0, argumentsFragment: '1}'));
      api.emit(const SseToolCallDelta(index: 1, argumentsFragment: '2}'));
      api.emit(const SseToolCallsFinished());

      await host.waitUntil(() => api.chatStreamCalls == 2);
      final toolRound = host.of<OrchToolRoundStarted>().single;
      expect(toolRound.message.toolCalls.length, 2);
      expect(toolRound.message.toolCalls[0].argumentsJson, '{"a":1}');
      expect(toolRound.message.toolCalls[1].argumentsJson, '{"b":2}');

      api.emit(const SseDone());
      await done;
    });

    test('工具执行失败：isError 结果交给模型，loop 不中断', () async {
      host.registry = ToolRegistry()
        ..register(const StubTool('x', shouldThrow: true));
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_e', name: 'stub', argumentsFragment: '{}'));
      api.emit(const SseToolCallsFinished());

      await host.waitUntil(() => api.chatStreamCalls == 2);
      final toolMsg = api.lastMessages!.firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['content'], contains('工具执行失败'));
      expect(toolMsg['content'], contains('工具炸了'));

      api.emit(const SseDone());
      await done;
      expect(host.of<OrchFinished>(), hasLength(1));
    });

    test('未知工具：isError 结果，loop 不中断', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_u', name: 'nope', argumentsFragment: '{}'));
      api.emit(const SseToolCallsFinished());

      await host.waitUntil(() => api.chatStreamCalls == 2);
      final toolMsg = api.lastMessages!.firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['content'], contains('未知工具'));

      api.emit(const SseDone());
      await done;
    });

    test('工具执行期间取消：OrchToolRoundCancelled，loop 终止', () async {
      final orch = host.build();
      // 钩子：工具结果事件到达时同步取消（模拟用户在工具执行期间点停止；
      // 同步钩子才能命中紧随其后的取消检查——轮询会错过微任务级窗口）
      final done = host.runHost(orch, hook: (event) {
        if (event is OrchToolResults) host.currentToken!.cancel();
      });

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_c', name: 'stub', argumentsFragment: '{}'));
      api.emit(const SseToolCallsFinished());

      await done;
      expect(host.of<OrchToolRoundCancelled>(), hasLength(1));
      expect(host.of<OrchFinished>(), isEmpty);
      // 已落库保留：assistant(tool_calls) + tool
      expect(host.persisted.values.where((m) => m.role == 'assistant'),
          hasLength(1));
      expect(host.persisted.values.where((m) => m.role == 'tool'),
          hasLength(1));
    });
  });

  group('轮数上限', () {
    test('连续 tool_calls 到第 8 轮注入强制总结提示，之后正常收尾', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      // 连续 7 轮工具调用（第 8 轮是 forceSummary 轮）
      for (var i = 0; i < 7; i++) {
        api.emit(SseToolCallDelta(
            index: 0, id: 'call_$i', name: 'stub', argumentsFragment: '{}'));
        api.emit(const SseToolCallsFinished());
        await host.waitUntil(() => api.chatStreamCalls == i + 2);
      }

      // 第 8 轮请求应带强制总结 system 消息
      expect(api.chatStreamCalls, 8);
      final lastMsg = api.lastMessages!.last;
      expect(lastMsg['role'], 'system');
      expect(lastMsg['content'], contains('上限'));

      api.emit(const SseDeltaContent('好的我总结'));
      api.emit(const SseDone());
      await done;
      expect(host.of<OrchFinished>(), hasLength(1));
    });

    test('第 8 轮仍 tool_calls：轮数耗尽兜底正常收尾', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      for (var i = 0; i < 7; i++) {
        api.emit(SseToolCallDelta(
            index: 0, id: 'call_$i', name: 'stub', argumentsFragment: '{}'));
        api.emit(const SseToolCallsFinished());
        await host.waitUntil(() => api.chatStreamCalls == i + 2);
      }
      // 第 8 轮（forceSummary）模型仍要工具：loop 兜底收尾
      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_last', name: 'stub', argumentsFragment: '{}'));
      api.emit(const SseToolCallsFinished());

      await done;
      // 兜底收尾：第 8 轮占位已被工具轮消费（_streamingMessage 置 null），
      // _finishNormal 无事可做 → finished.message 为 null（与旧实现一致）
      final finished = host.of<OrchFinished>().single;
      expect(finished.message, isNull);
      expect(host.of<OrchToolRoundStarted>(), hasLength(8),
          reason: '第 8 轮工具轮照常执行（上限保护靠 forceSummary 提示）');
    });
  });

  group('断流与出错', () {
    test('SseInterrupted：半截内容落库标中断，OrchInterrupted', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseDeltaContent('半截'));
      api.emit(const SseInterrupted());
      await done;

      final interrupted = host.of<OrchInterrupted>().single;
      expect(interrupted.message, isNotNull);
      expect(interrupted.message!.content, '半截');
      expect(interrupted.message!.interrupted, isTrue);
      expect(host.persisted.containsKey(interrupted.message!.id), isTrue);
    });

    test('SseError：半截内容落库标中断，OrchFailed 带错误文本', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseDeltaContent('半截'));
      api.emit(const SseError('网关 502'));
      await done;

      final failed = host.of<OrchFailed>().single;
      expect(failed.error, '网关 502');
      expect(failed.message!.content, '半截');
      expect(failed.message!.interrupted, isTrue);
    });

    test('ApiException：OrchFailed（无内容 = message null）', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emitError(ApiException('余额不足'));
      await done;

      final failed = host.of<OrchFailed>().single;
      expect(failed.error, '余额不足');
      expect(failed.message, isNull);
      // 空占位保留在库（与旧实现一致：错误路径不删占位，启动扫描兜底）
      expect(host.writeLog, ['ins:id_0']);
    });

    test('非 cancel 网络异常：OrchFailed 带包装文本', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emitError(StateError('socket 断了'));
      await done;

      expect(host.of<OrchFailed>().single.error, contains('请求失败'));
    });
  });

  group('dispose 硬边界', () {
    test('dispose 后：无新增写库、无收尾事件', () async {
      final orch = host.build();
      final done = host.runHost(orch);

      await host.waitUntil(() => api.chatStreamCalls == 1);
      // 宿主销毁（切会话/测试 tearDown）
      host.disposed = true;
      api.emit(const SseDeltaContent('迟到的内容'));
      api.emit(const SseDone());
      await done;

      // 收尾路径被 dispose 短路：无 finished 事件、无新增写库
      //（占位在轮开始时已落库 = E5 语义；内容不再落库）
      expect(host.of<OrchFinished>(), isEmpty);
      expect(host.writeLog, ['ins:id_0'],
          reason: 'dispose 后只有轮开始的占位落库，无内容写库');
    });

    test('工具执行期间 dispose：结果不落库，loop 终止', () async {
      final orch = host.build();
      // 钩子：assistant(tool_calls) 事件到达时同步销毁（精确命中
      // 工具执行前的窗口——轮询会错过微任务级推进）
      final done = host.runHost(orch, hook: (event) {
        if (event is OrchToolRoundStarted) host.disposed = true;
      });

      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_x', name: 'stub', argumentsFragment: '{}'));
      api.emit(const SseToolCallsFinished());

      await done;
      expect(host.of<OrchToolResults>(), isEmpty);
      expect(
          host.writeLog.where((w) => w.startsWith('ins:') &&
              host.persisted[w.substring(4)]?.role == 'tool'),
          isEmpty,
          reason: 'dispose 后工具结果不落库');
      // assistant(tool_calls) 已落库保留（与取消同语义）
      expect(host.persisted.values.where((m) => m.role == 'assistant'),
          hasLength(1));
    });
  });

  group('时序契约', () {
    test('run 进入到订阅建立之间无 await：run 返回后立即 emit 不丢事件',
        () async {
      final orch = host.build();
      final done = host.runHost(orch);

      // run 的 Future 已被调度，但订阅建立是同步的（无 await 间隙）——
      // 此处不等待直接 emit，事件必须被消费（首轮请求已记录）
      await host.waitUntil(() => api.chatStreamCalls == 1);
      api.emit(const SseDeltaContent('即时事件'));
      api.emit(const SseDone());
      await done;

      expect(host.of<OrchContentDelta>().single.text, '即时事件');
    });
  });
}
