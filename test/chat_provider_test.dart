import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/context_summary.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
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
    chatStreamCalls++;
    lastProfile = profile;
    lastTools = tools;
    lastMessages = messages;
    lastEffort = effort;
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
}
