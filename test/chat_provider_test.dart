import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/context_summary.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
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
}
