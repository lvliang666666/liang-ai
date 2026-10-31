import 'dart:async';

import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/message_attachment.dart';
import 'package:ai_chat_app/models/context_summary.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/agent_service.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/generation_keepalive.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();
  int chatStreamCalls = 0;

  /// F6 双答按调用序号分流：第 N 次请求（0 起）返回独立流的脚本。
  /// 非空时 chatStream 优先走脚本（独立 controller，事件互不串扰）；
  /// 脚本耗尽的请求回退共享广播流。双答两侧请求几乎同时建立订阅，
  /// 共享流无法区分两侧——脚本流让每侧拿到自己的事件序列
  final List<List<SseEvent>> scriptsByCall = [];

  /// 各次请求的独立 controller（脚本流用，测试后不留悬挂）
  final List<StreamController<SseEvent>> _scriptControllers = [];

  /// 记录最近一次请求的 profile（方言断言用）
  ProviderProfile? lastProfile;

  /// 记录最近一次请求的 tools 参数（工具链路断言用）
  List<Map<String, Object?>>? lastTools;

  /// 记录最近一次请求的 messages（多轮上下文断言用）
  List<Map<String, Object?>>? lastMessages;

  /// 记录最近一次请求的 effort（F4 智能路由断言用）
  String? lastEffort;

  void emit(SseEvent event) => _controller.add(event);

  void emitError(Object error) => _controller.addError(error);

  /// 向第 [callIndex] 次请求的脚本流投递事件（F6 双答用）
  void emitToCall(int callIndex, SseEvent event) {
    if (callIndex < _scriptControllers.length) {
      _scriptControllers[callIndex].add(event);
    }
  }

  /// 向第 [callIndex] 次请求的脚本流投递错误（cancel 模拟等）
  void emitErrorToCall(int callIndex, Object error) {
    if (callIndex < _scriptControllers.length) {
      _scriptControllers[callIndex].addError(error);
    }
  }

  /// 已建立的脚本流数量（轮询双答两侧订阅就绪用）
  int get scriptControllerCount => _scriptControllers.length;

  @override
  Stream<SseEvent> chatStream({
    required ProviderProfile profile,
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required CancelToken cancelToken,
    double temperature = 0.7,
    List<Map<String, Object?>>? tools,
  }) {
    final callIndex = chatStreamCalls;
    chatStreamCalls++;
    lastProfile = profile;
    lastTools = tools;
    lastMessages = messages;
    lastEffort = effort;
    if (callIndex < scriptsByCall.length) {
      final c = StreamController<SseEvent>.broadcast();
      _scriptControllers.add(c);
      // 微任务后投递：调用方拿到流后才能建立订阅（广播流不缓存）
      scheduleMicrotask(() {
        for (final e in scriptsByCall[callIndex]) {
          c.add(e);
        }
        // 不 close：双答侧 completer 由事件驱动收尾，close 会提前触发 onDone
      });
      return c.stream;
    }
    return _controller.stream;
  }

  @override
  void dispose() {}
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late MockApiService api;
  late ChatProvider provider;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);

    api = MockApiService();
    final session = ChatSession(
      id: 's1',
      title: '新对话',
      createdAt: 1000,
      updatedAt: 1000,
    );
    await db.insertSession(session);
    provider = ChatProvider(
      database: db,
      api: api,
      session: session,
      profile: ProviderProfile.builtinCompany(),
      model: 'glm5.1',
    );
  });

  tearDown(() async {
    provider.dispose();
    await db.close();
  });

  group('ChatProvider 状态机', () {
    test('idle → thinking → answering → done 完整流转', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');

      expect(provider.status, ChatStatus.thinking);

      api.emit(const SseDeltaReasoning('思考中'));
      await Future.delayed(Duration.zero);
      expect(provider.status, ChatStatus.thinking);
      expect(provider.streamingMessage!.reasoning, '思考中');

      api.emit(const SseDeltaContent('答案'));
      await Future.delayed(Duration.zero);
      expect(provider.status, ChatStatus.answering);
      expect(provider.streamingMessage!.content, '答案');

      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      expect(provider.status, ChatStatus.idle);
      expect(provider.streamingMessage, isNull);

      // 落库验证
      final msgs = await db.getMessages('s1');
      expect(msgs.length, 2);
      expect(msgs[0].role, 'user');
      expect(msgs[0].content, '你好');
      expect(msgs[1].role, 'assistant');
      expect(msgs[1].content, '答案');
      expect(msgs[1].reasoning, '思考中');
    });

    test('首条消息自动生成会话标题（截断 20 字）', () async {
      final longText = '这是一条非常长的消息用来测试标题截断逻辑是否正确执行到二十个字为止';
      await provider.sendMessage(longText);
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      expect(provider.session.title.length, 20);
      expect(provider.session.title, longText.substring(0, 20));
    });

    test('错误事件：保留已收内容落库并进入 error 状态', () async {
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('部分内容'));
      await Future.delayed(Duration.zero);

      api.emit(const SseError('服务错误'));
      await Future.delayed(Duration.zero);

      expect(provider.status, ChatStatus.error);
      expect(provider.errorMessage, '服务错误');

      final msgs = await db.getMessages('s1');
      expect(msgs.length, 2);
      expect(msgs[1].content, '部分内容');
    });

    test('流错误（ApiException）：进入 error 状态', () async {
      await provider.sendMessage('你好');
      api.emitError(ApiException('API Key 无效或已过期，请在设置中检查'));
      await Future.delayed(Duration.zero);

      expect(provider.status, ChatStatus.error);
      expect(provider.errorMessage, contains('API Key'));
    });

    test('clearError 回到 idle', () async {
      await provider.sendMessage('你好');
      api.emit(const SseError('err'));
      await Future.delayed(Duration.zero);

      provider.clearError();
      expect(provider.status, ChatStatus.idle);
    });

    test('切换推理档位并持久化', () async {
      await provider.setEffort('low');
      expect(provider.session.effort, 'low');
      final s = await db.getSession('s1');
      expect(s!.effort, 'low');
    });

    test('displayMessages 包含流式中消息', () async {
      await provider.loadMessages();
      await provider.sendMessage('hi');
      api.emit(const SseDeltaContent('x'));
      await Future.delayed(Duration.zero);

      expect(provider.displayMessages.length, 2);
      expect(provider.displayMessages.last.content, 'x');
    });
  });

  group('F3 Token 用量捕获', () {
    test('usage 末帧捕获：落库 assistant 消息带真实 prompt/completion',
        () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('答案'));
      api.emit(const SseUsage(promptTokens: 120, completionTokens: 45));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      expect(provider.status, ChatStatus.idle);
      final msgs = await db.getMessages('s1');
      final assistant = msgs.last;
      expect(assistant.role, 'assistant');
      expect(assistant.promptTokens, 120);
      expect(assistant.completionTokens, 45);
    });

    test('无 usage 帧：本地估算兜底（prompt/completion 均 > 0）', () async {
      await provider.loadMessages();
      await provider.sendMessage('这是一段足够长的中文输入用来验证估算逻辑');
      api.emit(const SseDeltaContent('这是模型的回答内容'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      final msgs = await db.getMessages('s1');
      final assistant = msgs.last;
      expect(assistant.promptTokens, greaterThan(0));
      expect(assistant.completionTokens, greaterThan(0));
      // 估算值应明显小于真实大模型值量级（粗估：输入 < 100）
      expect(assistant.promptTokens, lessThan(100));
    });

    test('usage 优先于估算：两者同时可得时用真实值', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('答案'));
      api.emit(const SseUsage(promptTokens: 500, completionTokens: 30));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      final msgs = await db.getMessages('s1');
      expect(msgs.last.promptTokens, 500);
      expect(msgs.last.completionTokens, 30);
    });

    test('totalTokens 汇总全部落库消息的 token', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('第一轮'));
      api.emit(const SseUsage(promptTokens: 100, completionTokens: 20));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      // 第二轮
      await provider.sendMessage('继续');
      api.emit(const SseDeltaContent('第二轮'));
      api.emit(const SseUsage(promptTokens: 200, completionTokens: 30));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      // 100+20 + 200+30 = 350
      expect(provider.totalTokens, 350);
      expect(provider.lastPromptTokens, 200);
    });

    test('工具轮：assistant 消息（含 tool_calls）也带 token 统计', () async {
      await provider.loadMessages();
      await provider.sendMessage('查时间');
      // 真实时序：工具分片 → finish_reason=tool_calls → usage 末帧 → [DONE]，
      // 同一批 emit（广播流按序投递，usage 在 loop 恢复前已被捕获）
      api.emit(const SseToolCallDelta(
        index: 0,
        id: 'call_1',
        name: 'get_current_time',
        argumentsFragment: '',
      ));
      api.emit(const SseToolCallsFinished());
      api.emit(const SseUsage(promptTokens: 80, completionTokens: 10));
      await Future.delayed(Duration.zero);

      final msgs = await db.getMessages('s1');
      final assistantWithCalls =
          msgs.firstWhere((m) => m.role == 'assistant' && m.toolCalls.isNotEmpty);
      expect(assistantWithCalls.promptTokens, 80);
      expect(assistantWithCalls.completionTokens, 10);
    });

    test('老数据（无 token 列值）：totalTokens 不崩溃，lastPromptTokens 为 null',
        () async {
      await db.insertMessage(ChatMessage(
        id: 'legacy1',
        sessionId: 's1',
        role: 'assistant',
        content: '老消息',
        createdAt: 1,
      ));
      await provider.loadMessages();

      expect(provider.totalTokens, 0);
      expect(provider.lastPromptTokens, isNull);
    });
  });

  group('I4 编辑重发', () {
    /// 预置两轮对话并加载（u1/a1/u2/a2），返回第一条 user 消息
    Future<ChatMessage> seedTwoRounds() async {
      await db.insertMessage(ChatMessage(
        id: 'u1', sessionId: 's1', role: 'user', content: '第一问', createdAt: 1000));
      await db.insertMessage(ChatMessage(
        id: 'a1', sessionId: 's1', role: 'assistant', content: '第一答', createdAt: 2000));
      await db.insertMessage(ChatMessage(
        id: 'u2', sessionId: 's1', role: 'user', content: '第二问', createdAt: 3000));
      await db.insertMessage(ChatMessage(
        id: 'a2', sessionId: 's1', role: 'assistant', content: '第二答', createdAt: 4000));
      await provider.loadMessages();
      return provider.messages.first;
    }

    test('编辑第一条 user 消息：其后全部截断，新文本重新发送', () async {
      final u1 = await seedTwoRounds();

      await provider.editAndResend(u1, '改后的第一问');
      api.emit(const SseDeltaContent('新回答'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      // DB：u1/a1/u2/a2 全删，新 user + 新 assistant
      final msgs = await db.getMessages('s1');
      expect(msgs.length, 2);
      expect(msgs[0].role, 'user');
      expect(msgs[0].content, '改后的第一问');
      expect(msgs[1].content, '新回答');

      // 内存同步
      expect(provider.messages.length, 2);
      expect(provider.messages.first.content, '改后的第一问');
    });

    test('编辑中间 user 消息：只截断该消息及其后，早期轮保留', () async {
      await db.insertMessage(ChatMessage(
        id: 'u1', sessionId: 's1', role: 'user', content: '第一问', createdAt: 1000));
      await db.insertMessage(ChatMessage(
        id: 'a1', sessionId: 's1', role: 'assistant', content: '第一答', createdAt: 2000));
      await db.insertMessage(ChatMessage(
        id: 'u2', sessionId: 's1', role: 'user', content: '第二问', createdAt: 3000));
      await db.insertMessage(ChatMessage(
        id: 'a2', sessionId: 's1', role: 'assistant', content: '第二答', createdAt: 4000));
      await db.insertMessage(ChatMessage(
        id: 'u3', sessionId: 's1', role: 'user', content: '第三问', createdAt: 5000));
      await db.insertMessage(ChatMessage(
        id: 'a3', sessionId: 's1', role: 'assistant', content: '第三答', createdAt: 6000));
      await provider.loadMessages();

      final u2 = provider.messages.firstWhere((m) => m.id == 'u2');
      await provider.editAndResend(u2, '第二问改');
      api.emit(const SseDeltaContent('新二答'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      final msgs = await db.getMessages('s1');
      // u1/a1 保留 + 新 u2' + 新 assistant
      expect(msgs.map((m) => m.content).toList(),
          ['第一问', '第一答', '第二问改', '新二答']);
    });

    test('编辑后请求只含截断后的历史（API payload 验证）', () async {
      final u1 = await seedTwoRounds();

      await provider.editAndResend(u1, '改后的问题');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      // 请求 messages：截断后只剩新 user 一条（无 system prompt 场景）
      final sent = api.lastMessages!;
      expect(sent.length, 1);
      expect(sent.single['role'], 'user');
      expect(sent.single['content'], '改后的问题');
    });

    test('流式中编辑被拒绝', () async {
      final u1 = await seedTwoRounds();
      await provider.sendMessage('新问题');
      expect(provider.isStreaming, isTrue);

      await provider.editAndResend(u1, '流式中改');
      // 无变化：消息数不变（4 条 + 新问题 user = 5）
      expect(provider.messages.length, 5);
      expect(provider.messages.first.content, '第一问');

      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
    });

    test('非 user 消息编辑被拒绝', () async {
      await seedTwoRounds();
      final a1 = provider.messages.firstWhere((m) => m.id == 'a1');

      await provider.editAndResend(a1, '改助手消息');
      // 无变化
      expect(provider.messages.length, 4);
      expect(provider.messages.first.content, '第一问');
    });

    test('空文本编辑被拒绝', () async {
      final u1 = await seedTwoRounds();

      await provider.editAndResend(u1, '   ');
      expect(provider.messages.length, 4);
    });

    test('前情摘要边界被删时摘要作废', () async {
      await seedTwoRounds();
      // 预置摘要：边界锚定 u2（编辑 u2 时边界消息被删 → 摘要作废）
      await db.saveContextSummary(ContextSummary(
        id: 'ctx-1',
        sessionId: 's1',
        summary: '【关键事实】\n旧摘要',
        firstKeptId: 'u2',
        firstKeptAt: 3000,
        createdAt: 1000,
      ));
      await provider.loadMessages();
      expect(provider.contextSummary, isNotNull);

      final u2 = provider.messages.firstWhere((m) => m.id == 'u2');
      await provider.editAndResend(u2, '第二问改');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      expect(provider.contextSummary, isNull);
      expect(await db.getContextSummary('s1'), isNull);
    });

    test('前情摘要边界未受影响时摘要保留', () async {
      await seedTwoRounds();
      // 边界锚定 u1（编辑 u2 不影响 u1 → 摘要保留）
      await db.saveContextSummary(ContextSummary(
        id: 'ctx-1',
        sessionId: 's1',
        summary: '【关键事实】\n旧摘要',
        firstKeptId: 'u1',
        firstKeptAt: 1000,
        createdAt: 1000,
      ));
      await provider.loadMessages();

      final u2 = provider.messages.firstWhere((m) => m.id == 'u2');
      await provider.editAndResend(u2, '第二问改');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      expect(provider.contextSummary, isNotNull);
      expect(provider.contextSummary!.summary, contains('旧摘要'));
    });
  });

  group('I10 生成状态可见性', () {
    test('正常完成：消息带耗时盖章，中断态复位', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaReasoning('思考'));
      api.emit(const SseDeltaContent('答案'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      expect(provider.status, ChatStatus.idle);
      expect(provider.lastRoundInterrupted, isFalse);
      final msgs = await db.getMessages('s1');
      final assistant = msgs.last;
      // 耗时已盖章（同毫秒内完成可能为 0，但字段必须非 null）
      expect(assistant.thinkingSeconds, isNotNull);
      expect(assistant.generationSeconds, isNotNull);
      expect(assistant.generationSeconds!, lessThanOrEqualTo(1));
    });

    test('断流（SseInterrupted）：已收内容落库 + 中断态标记', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('收到一半的内容'));
      api.emit(const SseInterrupted());
      await Future.delayed(Duration.zero);

      // 不进 error 态：断流不是错误，是可续传的常态
      expect(provider.status, ChatStatus.idle);
      expect(provider.lastRoundInterrupted, isTrue);
      expect(provider.isStreaming, isFalse);

      // 已收内容照常落库
      final msgs = await db.getMessages('s1');
      expect(msgs.length, 2);
      expect(msgs.last.content, '收到一半的内容');
      expect(msgs.last.generationSeconds, isNotNull);
    });

    test('手动停止不标记中断态', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('部分'));
      provider.stopGeneration();
      // mock 模拟 cancel 错误（与 agent_loop_test 同款）
      api.emitError(DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.cancel));
      await Future.delayed(Duration.zero);

      expect(provider.status, ChatStatus.idle);
      expect(provider.lastRoundInterrupted, isFalse,
          reason: '用户主动停止 ≠ 断流，不显示续传胶囊');
    });

    test('resumeLastGeneration：删截断消息 + 对原 user 消息重新发起', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('收到一半'));
      api.emit(const SseInterrupted());
      await Future.delayed(Duration.zero);
      expect(provider.lastRoundInterrupted, isTrue);
      final callsBefore = api.chatStreamCalls;

      await provider.resumeLastGeneration();
      await Future.delayed(Duration.zero);

      // 截断的 assistant 消息已删（内存），新一轮已发起
      expect(provider.lastRoundInterrupted, isFalse);
      expect(provider.isStreaming, isTrue);
      expect(api.chatStreamCalls, callsBefore + 1);
      // 请求的最后一条消息 = 原 user 消息（不重复落库）
      expect(api.lastMessages!.last['role'], 'user');
      expect(api.lastMessages!.last['content'], '你好');

      // 新一轮正常收尾
      api.emit(const SseDeltaContent('完整回答'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      expect(provider.status, ChatStatus.idle);

      // DB：截断消息已删，最终只有 user + 完整 assistant
      final msgs = await db.getMessages('s1');
      expect(msgs.length, 2);
      expect(msgs[0].content, '你好');
      expect(msgs[1].content, '完整回答');
    });

    test('resumeLastGeneration：非中断态为 no-op', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      final callsBefore = api.chatStreamCalls;

      await provider.resumeLastGeneration();
      expect(api.chatStreamCalls, callsBefore,
          reason: '正常完成后不应触发续传');
    });

    test('resumeLastGeneration：流式中为 no-op', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('流式中'));
      await Future.delayed(Duration.zero);
      final callsBefore = api.chatStreamCalls;

      await provider.resumeLastGeneration();
      expect(api.chatStreamCalls, callsBefore,
          reason: '流式中不应触发续传');

      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
    });

    test('generationSeconds 流式中实时可读', () async {
      await provider.loadMessages();
      expect(provider.generationSeconds, 0);
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('x'));
      await Future.delayed(Duration.zero);
      // 流式中起点已记录（同毫秒内为 0，但 getter 不崩溃）
      expect(provider.generationSeconds, lessThanOrEqualTo(1));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      // 收尾后复位为 0（起点清空）
      expect(provider.generationSeconds, 0);
    });
  });

  group('E5 流式中断恢复', () {
    test('流式开始即落库占位（interrupted=1）——App 被杀可识别', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      // 占位落库是 fire-and-forget：让一拍事件循环等它进队完成
      await Future.delayed(Duration.zero);
      // 占位在流式开始时已落库（不等收尾）
      final during = await db.getMessages('s1');
      expect(during.length, 2);
      expect(during.last.role, 'assistant');
      expect(during.last.interrupted, isTrue,
          reason: '占位标记：进程被杀后启动扫描能识别未收尾');

      // 模拟 App 被杀：直接重建 provider 读库（不 emit 收尾事件）
      final p2 = ChatProvider(
        database: db,
        api: api,
        session: ChatSession(
          id: 's1',
          title: '新对话',
          createdAt: 1000,
          updatedAt: 1000,
        ),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      await p2.loadMessages();
      expect(p2.lastRoundInterrupted, isTrue,
          reason: '启动扫描：占位未收尾 → 恢复中断态');
      p2.dispose();
    });

    test('正常收尾：占位覆写为完整内容，interrupted 复位', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('完整回答'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      final msgs = await db.getMessages('s1');
      expect(msgs.length, 2);
      expect(msgs.last.content, '完整回答');
      expect(msgs.last.interrupted, isFalse);

      // 重启扫描：正常收尾不误报
      final p2 = ChatProvider(
        database: db,
        api: api,
        session: ChatSession(
          id: 's1',
          title: '新对话',
          createdAt: 1000,
          updatedAt: 1000,
        ),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      await p2.loadMessages();
      expect(p2.lastRoundInterrupted, isFalse);
      p2.dispose();
    });

    test('断流收尾：半截内容落库带中断标记，重启可续传', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('收到一半'));
      api.emit(const SseInterrupted());
      await Future.delayed(Duration.zero);

      final msgs = await db.getMessages('s1');
      expect(msgs.last.content, '收到一半');
      expect(msgs.last.interrupted, isTrue);

      // 重启扫描：恢复中断态
      final p2 = ChatProvider(
        database: db,
        api: api,
        session: ChatSession(
          id: 's1',
          title: '新对话',
          createdAt: 1000,
          updatedAt: 1000,
        ),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      await p2.loadMessages();
      expect(p2.lastRoundInterrupted, isTrue);
      p2.dispose();
    });

    test('空占位取消：占位删除，不留幽灵消息', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      // 未收到任何内容就取消
      provider.stopGeneration();
      api.emitError(DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.cancel));
      await Future.delayed(Duration.zero);

      final msgs = await db.getMessages('s1');
      expect(msgs.length, 1, reason: '空占位应删除，只留 user 消息');
      expect(msgs.single.role, 'user');
    });

    test('中断态发新消息：放弃续传，中断态复位', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      api.emit(const SseDeltaContent('收到一半'));
      api.emit(const SseInterrupted());
      await Future.delayed(Duration.zero);
      expect(provider.lastRoundInterrupted, isTrue);

      // 直接发新消息（不走续传）
      await provider.sendMessage('换个话题');
      expect(provider.lastRoundInterrupted, isFalse);
      api.emit(const SseDeltaContent('好的'));
      api.emit(const SseDone());
      // 两拍：第二轮占位落库 + 收尾覆写都要进队完成
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      // DB：半截消息保留原样 + 新 user + 新 assistant
      final msgs = await db.getMessages('s1');
      expect(msgs.length, 4);
      expect(msgs[1].content, '收到一半');
      expect(msgs[1].interrupted, isTrue);
      expect(msgs[2].content, '换个话题');
      expect(msgs[3].content, '好的');
      expect(msgs[3].interrupted, isFalse);
    });

    test('工具轮落库：interrupted 复位（完整产物非半截）', () async {
      await provider.loadMessages();
      await provider.sendMessage('查时间');
      // 真实时序：工具分片 → finish_reason=tool_calls
      api.emit(const SseToolCallDelta(
        index: 0,
        id: 'call_1',
        name: 'get_current_time',
        argumentsFragment: '',
      ));
      api.emit(const SseToolCallsFinished());
      await Future.delayed(Duration.zero);

      // 工具轮 assistant 消息（含 tool_calls）落库，不带中断标记
      final msgs = await db.getMessages('s1');
      final toolMsg =
          msgs.firstWhere((m) => m.role == 'assistant' && m.toolCalls.isNotEmpty);
      expect(toolMsg.interrupted, isFalse);
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
    });
  });

  group('F4 智能路由', () {
    /// 建一个开了智能路由的 provider（复用 setUp 的 db/api）
    ChatProvider routedProvider() => ChatProvider(
          database: db,
          api: api,
          session: ChatSession(
            id: 's-route',
            title: '新对话',
            createdAt: 1000,
            updatedAt: 1000,
          ),
          profile: ProviderProfile.builtinCompany(),
          model: 'glm5.1',
          smartRouting: true,
        );

    test('开关开：max 触发词消息走 max 档', () async {
      final p = routedProvider();
      await p.loadMessages();
      await p.sendMessage('深入分析一下这个问题');
      expect(api.lastEffort, 'max');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      p.dispose();
    });

    test('开关开：短寒暄走 low 档', () async {
      final p = routedProvider();
      await p.loadMessages();
      await p.sendMessage('你好');
      expect(api.lastEffort, 'low');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      p.dispose();
    });

    test('开关开：普通长消息走 high 档', () async {
      final p = routedProvider();
      await p.loadMessages();
      await p.sendMessage('帮我把这段话润色一下，语气正式一点');
      expect(api.lastEffort, 'high');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      p.dispose();
    });

    test('开关关（默认）：effort 走会话设置，路由不介入', () async {
      await provider.loadMessages();
      await provider.sendMessage('你好');
      // setUp 的 provider 未开路由：会话默认 max（builtinCompany 默认档）
      expect(api.lastEffort, isNot('low'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
    });
  });

  group('I13 后台生成保活', () {
    setUp(() {
      GenerationKeepalive.resetForTest();
    });

    tearDown(() {
      GenerationKeepalive.resetForTest();
    });

    /// 建一个指定保活开关的 provider（复用 setUp 的 db/api）
    ChatProvider keepaliveProvider({required bool notification}) =>
        ChatProvider(
          database: db,
          api: api,
          session: ChatSession(
            id: 's-keepalive',
            title: '保活测试',
            createdAt: 1000,
            updatedAt: 1000,
          ),
          profile: ProviderProfile.builtinCompany(),
          model: 'glm5.1',
          keepaliveNotification: notification,
        );

    test('生成开始记录通知开关，结束释放保活态', () async {
      final p = keepaliveProvider(notification: true);
      await p.loadMessages();
      await p.sendMessage('你好');

      // 生成中：保活已激活，通知开关已记录
      await Future.delayed(Duration.zero);
      expect(GenerationKeepalive.active, isTrue);
      expect(GenerationKeepalive.lastNotificationEnabled, isTrue);

      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      // 生成结束：保活释放
      expect(GenerationKeepalive.active, isFalse);
      p.dispose();
    });

    test('通知开关关：不启动前台服务（纯保活态标记）', () async {
      final p = keepaliveProvider(notification: false);
      await p.loadMessages();
      await p.sendMessage('你好');

      await Future.delayed(Duration.zero);
      expect(GenerationKeepalive.active, isTrue);
      expect(GenerationKeepalive.lastNotificationEnabled, isFalse);

      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      expect(GenerationKeepalive.active, isFalse);
      p.dispose();
    });

    test('出错路径也释放保活（finally 兜底）', () async {
      final p = keepaliveProvider(notification: true);
      await p.loadMessages();
      await p.sendMessage('你好');
      await Future.delayed(Duration.zero);
      expect(GenerationKeepalive.active, isTrue);

      api.emitError(Exception('网络错误'));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      expect(GenerationKeepalive.active, isFalse);
      p.dispose();
    });

    test('手动停止生成也释放保活', () async {
      final p = keepaliveProvider(notification: true);
      await p.loadMessages();
      await p.sendMessage('你好');
      await Future.delayed(Duration.zero);
      expect(GenerationKeepalive.active, isTrue);

      p.stopGeneration();
      // mock 模拟 cancel 错误（与「手动停止不标记中断态」同款）
      api.emitError(DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.cancel));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      expect(GenerationKeepalive.active, isFalse);
      p.dispose();
    });
  });

  group('T2 run_skill 注册表接线', () {
    /// 建一个带/不带 AgentService 的 provider（复用 setUp 的 db/api）
    ChatProvider skillProvider({required bool withAgentService}) => ChatProvider(
          database: db,
          api: api,
          session: ChatSession(
            id: 's-skill',
            title: '新对话',
            createdAt: 1000,
            updatedAt: 1000,
          ),
          profile: ProviderProfile.builtinCompany(),
          model: 'glm5.1',
          agentService: withAgentService ? AgentService(database: db) : null,
        );

    test('注入 agentService：注册表含 run_skill', () async {
      final p = skillProvider(withAgentService: true);
      await p.loadMessages();
      expect(p.toolCount, greaterThan(0));
      // run_skill 在注册表里 → 请求的 tools 数组带它
      await p.sendMessage('委派任务');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      final names = [
        for (final t in api.lastTools!)
          (t['function'] as Map)['name'] as String,
      ];
      expect(names, contains('run_skill'));
      p.dispose();
    });

    test('不注入 agentService：注册表不含 run_skill（向后兼容）', () async {
      final p = skillProvider(withAgentService: false);
      await p.loadMessages();
      await p.sendMessage('普通消息');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      if (api.lastTools != null) {
        final names = [
          for (final t in api.lastTools!)
            (t['function'] as Map)['name'] as String,
        ];
        expect(names, isNot(contains('run_skill')));
      }
      p.dispose();
    });

    test('setAgent 切换后 run_skill 仍在（重建注册表不丢委派桥）', () async {
      final p = skillProvider(withAgentService: true);
      await p.loadMessages();
      // 切到只允许 get_current_time 的 Agent
      await p.setAgent(Agent(
        id: 'timer',
        name: '计时器',
        prompt: '只报时间',
        toolNames: ['get_current_time'],
      ));
      await p.sendMessage('现在几点');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      final names = [
        for (final t in api.lastTools!)
          (t['function'] as Map)['name'] as String,
      ];
      expect(names, ['get_current_time', 'run_skill']);
      p.dispose();
    });

    test('端到端：主 loop 收到 run_skill 调用 → 子 loop 跑完 → 汇报落库',
        () async {
      final p = skillProvider(withAgentService: true);
      // 预置一个 Skill（子 loop 的 system prompt 来源）
      final service = AgentService(database: db);
      await service.create(
          name: '翻译官', prompt: '你是翻译官，只输出译文。');
      // create 的 id 是时间戳随机串，查回来
      final agents = await service.getAll();
      final translator = agents.firstWhere((a) => a.name == '翻译官');
      await p.loadMessages();
      await p.sendMessage('把这句话翻译成英文：你好');

      // 主 loop 第一轮：模型请求 run_skill
      api.emit(SseToolCallDelta(
        index: 0,
        id: 'call_1',
        name: 'run_skill',
        argumentsFragment:
            '{"skill_id": "${translator.id}", "task": "翻译：你好"}',
      ));
      api.emit(const SseToolCallsFinished());
      await Future.delayed(Duration.zero);

      // 子 loop 是独立请求（复用宿主 api = 同一 MockApiService）：
      // 轮询等它发起请求，再喂子 loop 的最终汇报（广播流不缓存事件）
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (api.chatStreamCalls < 2) {
        if (DateTime.now().isAfter(deadline)) fail('子 loop 未发起请求');
        await Future.delayed(const Duration(milliseconds: 5));
      }
      api.emit(const SseDeltaContent('Hello'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);

      // 主 loop 第二轮：等请求发起（订阅就绪）再喂事件
      final deadline2 = DateTime.now().add(const Duration(seconds: 2));
      while (api.chatStreamCalls < 3) {
        if (DateTime.now().isAfter(deadline2)) fail('主 loop 第二轮未发起');
        await Future.delayed(const Duration(milliseconds: 5));
      }
      api.emit(const SseDeltaContent('翻译完成：Hello'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      // 最终 assistant 落库是异步收尾，轮询等齐 4 条
      List<dynamic> msgs = [];
      final deadline3 = DateTime.now().add(const Duration(seconds: 2));
      while (true) {
        msgs = await db.getMessages('s-skill');
        if (msgs.length >= 4 ||
            DateTime.now().isAfter(deadline3)) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // user + assistant(tool_calls) + tool(汇报) + assistant(最终)
      expect(msgs.length, 4);
      expect(msgs[1].toolCalls.first.name, 'run_skill');
      expect(msgs[2].content, 'Hello'); // 子 loop 最终汇报进主会话
      expect(msgs[3].content, '翻译完成：Hello');
      p.dispose();
    });
  });

  group('F6 同问双答', () {
    /// 建一个带双答 mock 工厂的 provider（对侧请求也走同一 MockApiService，
    /// 事件经 scriptsByCall 按调用序号分流）
    ChatProvider dualProvider() => ChatProvider(
          database: db,
          api: api,
          session: ChatSession(
            id: 's-dual',
            title: '新对话',
            createdAt: 1000,
            updatedAt: 1000,
          ),
          profile: ProviderProfile.builtinCompany(),
          model: 'glm5.1',
          dualApiFactory: (profile) => api,
        );

    /// 轮询等待条件成立（双答收尾是异步链，固定拍数不可靠）
    Future<void> waitUntil(bool Function() cond,
        {String failMessage = '条件未达成'}) async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!cond()) {
        if (DateTime.now().isAfter(deadline)) fail(failMessage);
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    test('双流完成：两侧落库互指 dualOf，进入待选择态', () async {
      final p = dualProvider();
      await p.loadMessages();
      // 第 0 次请求 = 主侧，第 1 次 = 对侧（脚本流各自独立）
      api.scriptsByCall
        ..add([
          const SseDeltaContent('主侧回答'),
          const SseDone(),
        ])
        ..add([
          const SseDeltaContent('对侧回答'),
          const SseDone(),
        ]);

      await p.sendDualMessage('同一个问题');

      // 两侧都收尾后进入待选择态（异步收尾，轮询）
      await waitUntil(() => p.isAwaitingDualChoice,
          failMessage: '双答未进入待选择态');
      expect(p.status, ChatStatus.idle);
      expect(p.isDualRunning, isFalse);

      // DB：user + 两侧 assistant，互指 dualOf + 来源徽标
      final msgs = await db.getMessages('s-dual');
      expect(msgs.length, 3);
      expect(msgs[0].role, 'user');
      expect(msgs[0].content, '同一个问题');
      final left = msgs[1];
      final right = msgs[2];
      expect(left.dualOf, right.id);
      expect(right.dualOf, left.id);
      expect(left.sourceLabel, contains('公司 GLM'));
      expect(right.sourceLabel, contains('公司 GLM'));
      expect(left.content, '主侧回答');
      expect(right.content, '对侧回答');
      p.dispose();
    });

    test('chooseDual：删姊妹清标记，返回对侧切换目标', () async {
      final p = dualProvider();
      await p.loadMessages();
      // 对侧用不同名字的 profile（切换目标反解验证）
      final other = ProviderProfile(
        id: 'ds',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        defaultModel: 'deepseek-chat',
      );
      await db.insertProvider(other);
      api.scriptsByCall
        ..add([const SseDeltaContent('主侧'), const SseDone()])
        ..add([const SseDeltaContent('对侧'), const SseDone()]);

      await p.setDualTarget(other, 'deepseek-chat');
      await p.sendDualMessage('问题');
      await waitUntil(() => p.isAwaitingDualChoice,
          failMessage: '双答未进入待选择态');

      // 选中对侧（右侧）：姊妹删除 + 标记清空 + 返回切换目标
      final msgs = await db.getMessages('s-dual');
      final right = msgs.last;
      final switchTo = await p.chooseDual(right);
      expect(switchTo, isNotNull);
      expect(switchTo!.$1.id, 'ds');
      expect(switchTo.$2, 'deepseek-chat');

      final after = await db.getMessages('s-dual');
      expect(after.length, 2, reason: '姊妹回答已删除');
      expect(after.last.dualOf, isNull, reason: '本侧标记已清');
      expect(p.isAwaitingDualChoice, isFalse);
      p.dispose();
    });

    test('chooseDual：选主侧（当前供应商）返回 null 不切换', () async {
      final p = dualProvider();
      await p.loadMessages();
      api.scriptsByCall
        ..add([const SseDeltaContent('主侧'), const SseDone()])
        ..add([const SseDeltaContent('对侧'), const SseDone()]);

      await p.sendDualMessage('问题');
      await waitUntil(() => p.isAwaitingDualChoice,
          failMessage: '双答未进入待选择态');

      final msgs = await db.getMessages('s-dual');
      final left = msgs[1];
      final switchTo = await p.chooseDual(left);
      expect(switchTo, isNull, reason: '主侧 = 当前供应商，无需切换');

      final after = await db.getMessages('s-dual');
      expect(after.length, 2);
      expect(after[1].dualOf, isNull);
      p.dispose();
    });

    test('对侧失败：错误占位落库，主侧保留，状态 error 可关闭', () async {
      final p = dualProvider();
      await p.loadMessages();
      api.scriptsByCall
        ..add([const SseDeltaContent('主侧正常'), const SseDone()])
        ..add([const SseError('网关 500')]);

      await p.sendDualMessage('问题');
      await waitUntil(() => p.status == ChatStatus.error,
          failMessage: '对侧失败未进入 error 态');

      // 主侧内容保留 + 对侧错误占位（无 dualOf 互指——单侧结果无需选择）
      final msgs = await db.getMessages('s-dual');
      expect(msgs.length, 3);
      expect(msgs[1].content, '主侧正常');
      expect(msgs[1].dualOf, isNull);
      expect(msgs[2].content, contains('请求失败'));
      expect(p.errorMessage, contains('对侧'));
      p.clearError();
      expect(p.status, ChatStatus.idle);
      p.dispose();
    });

    test('双答目标一次性消费：第二次发送回到普通单流', () async {
      final p = dualProvider();
      await p.loadMessages();
      final other = ProviderProfile(
        id: 'ds',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        defaultModel: 'deepseek-chat',
      );
      await db.insertProvider(other);
      api.scriptsByCall
        ..add([const SseDeltaContent('主1'), const SseDone()])
        ..add([const SseDeltaContent('对1'), const SseDone()]);

      await p.setDualTarget(other, 'deepseek-chat');
      await p.sendDualMessage('第一问');
      await waitUntil(() => p.isAwaitingDualChoice,
          failMessage: '第一次双答未完成');
      final callsAfterDual = api.chatStreamCalls;

      // 第二次发送：目标已消费，走普通 sendMessage 单流
      await p.sendMessage('第二问');
      expect(api.chatStreamCalls, callsAfterDual + 1);
      api.emit(const SseDeltaContent('普通回答'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      expect(p.status, ChatStatus.idle);
      p.dispose();
    });

    test('流式中 setDualTarget 被拒绝', () async {
      final p = dualProvider();
      await p.loadMessages();
      await p.sendMessage('普通消息');
      expect(p.isStreaming, isTrue);

      final other = ProviderProfile(
        id: 'ds',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
      );
      await p.setDualTarget(other, 'deepseek-chat');
      // 流式中拒绝：目标未设置，后续 sendDualMessage 走自答
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      // call 0 已被上面的普通消息消费——垫空脚本占位，双答两侧用索引 1/2
      api.scriptsByCall
        ..add(const [])
        ..add([const SseDeltaContent('自答'), const SseDone()])
        ..add([const SseDeltaContent('自答2'), const SseDone()]);
      await p.sendDualMessage('双答');
      await waitUntil(() => p.isAwaitingDualChoice,
          failMessage: '自答双答未完成');
      // 自答 = 同供应商同模型（sourceLabel 相同）
      // 消息序：user(普通) / user(双答) / 自答×2——普通消息只发了
      // SseDone 无内容，空占位被删除，无 assistant 回复
      final msgs = await db.getMessages('s-dual');
      expect(msgs.length, 4);
      expect(msgs[2].sourceLabel, isNotNull);
      expect(msgs[2].sourceLabel, msgs[3].sourceLabel);
      p.dispose();
    });

    test('停止生成：两侧令牌同时取消，已收内容保留', () async {
      final p = dualProvider();
      await p.loadMessages();
      // 脚本只给内容不给收尾事件——停止驱动收尾
      api.scriptsByCall
        ..add([const SseDeltaContent('主侧半截')])
        ..add([const SseDeltaContent('对侧半截')]);

      // sendDualMessage 会 await 到双流收尾（脚本无收尾事件 = 挂起），
      // 不能直接 await——后台启动，轮询等两侧脚本流订阅建立后再停止
      unawaited(p.sendDualMessage('问题'));
      await waitUntil(() => api.scriptControllerCount >= 2,
          failMessage: '双答脚本流未建立');
      expect(p.isDualRunning, isTrue);

      p.stopGeneration();
      // 两侧 cancel 错误经 onError 收尾（保留已收内容）
      api.emitErrorToCall(0, DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.cancel,
      ));
      api.emitErrorToCall(1, DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.cancel,
      ));
      await waitUntil(() => !p.isDualRunning, failMessage: '双答未停止');

      // 已收内容保留（手动停止 ≠ 中断态）
      final msgs = await db.getMessages('s-dual');
      expect(msgs.length, 3);
      expect(msgs[1].content, '主侧半截');
      expect(msgs[2].content, '对侧半截');
      expect(msgs[1].interrupted, isFalse);
      expect(p.isAwaitingDualChoice, isTrue, reason: '两侧都有内容 = 待选择');
      p.dispose();
    });

    test('regenerateFrom 重答双答一侧：姊妹一并删除', () async {
      final p = dualProvider();
      await p.loadMessages();
      api.scriptsByCall
        ..add([const SseDeltaContent('主侧'), const SseDone()])
        ..add([const SseDeltaContent('对侧'), const SseDone()]);

      await p.sendDualMessage('问题');
      await waitUntil(() => p.isAwaitingDualChoice,
          failMessage: '双答未进入待选择态');

      // 重答主侧：姊妹（对侧）一并删除，重新生成
      final msgs = await db.getMessages('s-dual');
      final left = msgs[1];
      await p.regenerateFrom(left);
      api.emit(const SseDeltaContent('重答内容'));
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      final after = await db.getMessages('s-dual');
      // user + 重答 assistant（对侧已删）
      expect(after.length, 2);
      expect(after.last.content, '重答内容');
      expect(after.last.dualOf, isNull);
      p.dispose();
    });

    test('sendMessage 分发：已设双答目标时普通发送走双流（Bug 修复回归）', () async {
      final p = dualProvider();
      await p.loadMessages();
      final other = ProviderProfile(
        id: 'ds',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        defaultModel: 'deepseek-chat',
      );
      await db.insertProvider(other);
      api.scriptsByCall
        ..add([const SseDeltaContent('主侧'), const SseDone()])
        ..add([const SseDeltaContent('对侧'), const SseDone()]);

      // 用户操作序列：点双答 tag → 选对照方 → 直接在输入框发送
      await p.setDualTarget(other, 'deepseek-chat');
      expect(p.isDualArmed, isTrue, reason: '目标已设 = 已武装态');
      await p.sendMessage('这个问题要双答');

      // 关键断言：走的是双流管线（2 次请求 + 待选择态），而非普通单流
      await waitUntil(() => p.isAwaitingDualChoice,
          failMessage: 'sendMessage 未分发到双答管线');
      expect(api.chatStreamCalls, 2, reason: '双流 = 主侧 + 对侧两次请求');
      final msgs = await db.getMessages('s-dual');
      expect(msgs.length, 3);
      expect(msgs[1].content, '主侧');
      expect(msgs[2].content, '对侧');
      expect(msgs[1].dualOf, msgs[2].id);
      // 目标已消费：回到未武装态
      expect(p.isDualArmed, isFalse);
      p.dispose();
    });

    test('sendMessage 带附件时不触发双答，目标保留待下一条消费', () async {
      final p = dualProvider();
      await p.loadMessages();
      final other = ProviderProfile(
        id: 'ds',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        defaultModel: 'deepseek-chat',
      );
      await db.insertProvider(other);
      await p.setDualTarget(other, 'deepseek-chat');

      // 带附件发送：走普通单流管线（附件场景不做对照）
      p.addAttachment(const MessageAttachment(
        type: AttachmentType.image,
        name: 'a.png',
        base64Data: 'aGk=',
      ));
      api.scriptsByCall.add([const SseDeltaContent('普通'), const SseDone()]);
      await p.sendMessage('看这张图');
      api.emit(const SseDone());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(p.isDualArmed, isTrue, reason: '附件消息不消费双答目标');
      expect(api.chatStreamCalls, 1, reason: '普通单流 = 1 次请求');

      // 下一条纯文本消息：双答正常触发
      api.scriptsByCall
        ..add([const SseDeltaContent('主2'), const SseDone()])
        ..add([const SseDeltaContent('对2'), const SseDone()]);
      await p.sendMessage('现在双答');
      await waitUntil(() => p.isAwaitingDualChoice,
          failMessage: '后续纯文本未触发双答');
      expect(p.isDualArmed, isFalse);
      p.dispose();
    });
  });
}
