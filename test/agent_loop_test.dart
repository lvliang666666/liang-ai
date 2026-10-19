import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'chat_provider_test.dart' show MockApiService;

/// 测试工具：返回固定文本
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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late MockApiService api;
  late ChatProvider provider;

  setUp(() async {
    final inMemory = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, title TEXT NOT NULL,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              effort TEXT NOT NULL DEFAULT 'max', agent_id TEXT,
              provider_id TEXT, model TEXT
            )
          ''');
          await d.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
              content TEXT NOT NULL DEFAULT '', reasoning TEXT NOT NULL DEFAULT '',
              attachments TEXT NOT NULL DEFAULT '[]',
              tool_calls TEXT NOT NULL DEFAULT '[]', tool_call_id TEXT,
              created_at INTEGER NOT NULL
            )
          ''');
          await d.execute('''
            CREATE TABLE agents (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              icon TEXT NOT NULL DEFAULT '🤖', description TEXT NOT NULL DEFAULT '',
              prompt TEXT NOT NULL DEFAULT '', temperature REAL, effort TEXT,
              is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await d.execute('''
            CREATE TABLE providers (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              base_url TEXT NOT NULL DEFAULT '', api_key TEXT NOT NULL DEFAULT '',
              default_model TEXT NOT NULL DEFAULT '',
              capabilities TEXT NOT NULL DEFAULT '{}',
              dialect TEXT NOT NULL DEFAULT '{}',
              is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
        },
      ),
    );
    db = DatabaseService.instance;
    await db.initForTest(inMemory);

    api = MockApiService();
    final session = ChatSession(
        id: 's1', title: '新对话', createdAt: 1000, updatedAt: 1000);
    await db.insertSession(session);
    provider = ChatProvider(
      database: db,
      api: api,
      session: session,
      profile: toolProfile(),
      model: 'm1',
      toolRegistry: ToolRegistry()..register(const StubTool('工具结果OK')),
    );
  });

  tearDown(() async {
    provider.dispose();
    await db.close();
  });

  /// 轮询等待条件成立（后台 loop 推进是异步的，固定 tick 次数会竞态）
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

  group('agentic loop 多轮', () {
    test('完整链路：tool_calls → 执行 → tool 结果落库 → 二轮回答', () async {
      await provider.loadMessages();
      await provider.sendMessage('现在几点');

      // 第一轮：模型请求调用工具
      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_1', name: 'stub', argumentsFragment: '{"x":'));
      api.emit(const SseToolCallDelta(
          index: 0, argumentsFragment: '1}'));
      api.emit(const SseToolCallsFinished());

      // 工具执行后进入第二轮 thinking
      await waitUntil(() => api.chatStreamCalls == 2);

      // 第二轮请求应携带 tools 定义 + tool 结果消息
      expect(provider.status, ChatStatus.thinking);
      expect(api.lastTools, isNotNull);
      expect(api.lastTools!.length, 1);
      final toolMsg = api.lastMessages!
          .firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['tool_call_id'], 'call_1');
      expect(toolMsg['content'], '工具结果OK');

      // 第二轮正常回答收尾
      api.emit(const SseDeltaContent('现在是白天'));
      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);

      // 落库验证：user + assistant(tool_calls) + tool + assistant(回答)
      final msgs = await db.getMessages('s1');
      expect(msgs.length, 4);
      expect(msgs[0].role, 'user');
      expect(msgs[1].role, 'assistant');
      expect(msgs[1].toolCalls.length, 1);
      expect(msgs[1].toolCalls[0].id, 'call_1');
      expect(msgs[1].toolCalls[0].name, 'stub');
      expect(msgs[1].toolCalls[0].argumentsJson, '{"x":1}');
      expect(msgs[2].role, 'tool');
      expect(msgs[2].toolCallId, 'call_1');
      expect(msgs[2].content, '工具结果OK');
      expect(msgs[3].role, 'assistant');
      expect(msgs[3].content, '现在是白天');
    });

    test('分片跨 chunk 累积：多工具并行（index 0/1 交错）', () async {
      await provider.loadMessages();
      await provider.sendMessage('查两个');

      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_a', name: 'stub', argumentsFragment: '{"a":'));
      api.emit(const SseToolCallDelta(
          index: 1, id: 'call_b', name: 'stub', argumentsFragment: '{"b":'));
      api.emit(const SseToolCallDelta(index: 0, argumentsFragment: '1}'));
      api.emit(const SseToolCallDelta(index: 1, argumentsFragment: '2}'));
      api.emit(const SseToolCallsFinished());

      // 两个工具都执行了（第二轮请求的 tool 消息有两条）
      await waitUntil(() => api.chatStreamCalls == 2);
      final toolMsgs = api.lastMessages!
          .where((m) => m['role'] == 'tool')
          .toList();
      expect(toolMsgs.length, 2);

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);

      final msgs = await db.getMessages('s1');
      final assistant = msgs.firstWhere((m) => m.role == 'assistant');
      expect(assistant.toolCalls.length, 2);
      expect(assistant.toolCalls[0].argumentsJson, '{"a":1}');
      expect(assistant.toolCalls[1].argumentsJson, '{"b":2}');
    });

    test('工具执行失败：isError 结果交给模型，loop 不中断', () async {
      // 换一个会抛异常的工具
      final failingProvider = ChatProvider(
        database: db,
        api: api,
        session: ChatSession(
            id: 's1', title: '新对话', createdAt: 1000, updatedAt: 1000),
        profile: toolProfile(),
        model: 'm1',
        toolRegistry: ToolRegistry()
          ..register(const StubTool('x', shouldThrow: true)),
      );

      await failingProvider.loadMessages();
      await failingProvider.sendMessage('触发失败');

      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_e', name: 'stub', argumentsFragment: '{}'));
      api.emit(const SseToolCallsFinished());

      // loop 继续（第二轮请求发出）
      await waitUntil(() => api.chatStreamCalls == 2);
      final toolMsg = api.lastMessages!
          .firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['content'], contains('工具执行失败'));
      expect(toolMsg['content'], contains('工具炸了'));

      api.emit(const SseDone());
      await waitUntil(() => failingProvider.status == ChatStatus.idle);
      failingProvider.dispose();
    });

    test('未知工具：isError 结果，loop 不中断', () async {
      await provider.loadMessages();
      await provider.sendMessage('调不存在的');

      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_u', name: 'nope', argumentsFragment: '{}'));
      api.emit(const SseToolCallsFinished());

      await waitUntil(() => api.chatStreamCalls == 2);
      final toolMsg = api.lastMessages!
          .firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['content'], contains('未知工具'));

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);
    });

    test('loop 上限：连续 tool_calls 到第 8 轮注入强制总结提示', () async {
      await provider.loadMessages();
      await provider.sendMessage('无限调用');

      // 连续 7 轮工具调用（第 8 轮是 forceSummary 轮）
      for (var i = 0; i < 7; i++) {
        api.emit(SseToolCallDelta(
            index: 0, id: 'call_$i', name: 'stub', argumentsFragment: '{}'));
        api.emit(const SseToolCallsFinished());
        await waitUntil(() => api.chatStreamCalls == i + 2);
      }

      // 第 8 轮请求应带强制总结 system 消息
      expect(api.chatStreamCalls, 8);
      final lastMsg = api.lastMessages!.last;
      expect(lastMsg['role'], 'system');
      expect(lastMsg['content'], contains('上限'));

      // 模型收尾
      api.emit(const SseDeltaContent('好的我总结'));
      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);
    });

    test('取消：工具执行期间停止 → loop 终止，已落库消息保留', () async {
      await provider.loadMessages();
      await provider.sendMessage('取消测试');

      api.emit(const SseToolCallDelta(
          index: 0, id: 'call_c', name: 'stub', argumentsFragment: '{}'));
      api.emit(const SseToolCallsFinished());

      // 工具执行完、第二轮 thinking 时取消
      await waitUntil(() => api.chatStreamCalls == 2);
      expect(provider.status, ChatStatus.thinking);
      provider.stopGeneration();

      // 第二轮流被取消（mock 模拟 cancel 错误）
      api.emitError(DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.cancel));
      await waitUntil(() => provider.status == ChatStatus.idle);

      expect(api.chatStreamCalls, 2); // 第二轮已发起但被取消

      // 已落库消息保留：user + assistant(tool_calls) + tool
      final msgs = await db.getMessages('s1');
      expect(msgs.length, 3);
      expect(msgs[1].role, 'assistant');
      expect(msgs[2].role, 'tool');
    });

    test('无 tools 能力的 profile：不发送 tools 参数', () async {
      final noToolProvider = ChatProvider(
        database: db,
        api: api,
        session: ChatSession(
            id: 's1', title: '新对话', createdAt: 1000, updatedAt: 1000),
        // 内置 profile 现已声明 toolCalls（v1.6.0），显式关掉模拟无能力供应商
        profile: ProviderProfile.builtinCompany()
            .copyWith(capabilities: const ProviderCapabilities()),
        model: 'glm5.1',
        toolRegistry: ToolRegistry()..register(const StubTool('x')),
      );
      await noToolProvider.loadMessages();
      await noToolProvider.sendMessage('你好');
      api.emit(const SseDone());
      await waitUntil(() => noToolProvider.status == ChatStatus.idle);

      expect(api.lastTools, isNull);
      noToolProvider.dispose();
    });
  });

  group('DB v5 tool 消息', () {
    test('tool_calls + tool_call_id 落库往返', () async {
      const calls = [
        ToolCall(id: 'c1', name: 'get_current_time', argumentsJson: '{}'),
        ToolCall(id: 'c2', name: 'calculate', argumentsJson: '{"expression":"1+1"}'),
      ];
      final assistant = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '',
        toolCalls: calls,
        createdAt: 1000,
      );
      await db.insertMessage(assistant);

      final toolMsg = ChatMessage(
        id: 'm2',
        sessionId: 's1',
        role: 'tool',
        content: '结果文本',
        toolCallId: 'c1',
        createdAt: 1001,
      );
      await db.insertMessage(toolMsg);

      final msgs = await db.getMessages('s1');
      expect(msgs.length, 2);
      expect(msgs[0].toolCalls.length, 2);
      expect(msgs[0].toolCalls[1].name, 'calculate');
      expect(msgs[0].toolCalls[1].argumentsJson, '{"expression":"1+1"}');
      expect(msgs[1].role, 'tool');
      expect(msgs[1].toolCallId, 'c1');
      expect(msgs[1].content, '结果文本');
    });

    test('toApiMessage：assistant 带 tool_calls 输出 OpenAI 格式', () {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's',
        role: 'assistant',
        content: '我来查一下',
        toolCalls: const [
          ToolCall(id: 'c1', name: 'stub', argumentsJson: '{"x":1}'),
        ],
        createdAt: 1,
      );
      final api = msg.toApiMessage();
      expect(api['role'], 'assistant');
      expect(api['content'], '我来查一下');
      final tcs = api['tool_calls'] as List;
      expect(tcs.length, 1);
      expect(tcs[0]['id'], 'c1');
      expect(tcs[0]['type'], 'function');
      expect(tcs[0]['function']['name'], 'stub');
      expect(tcs[0]['function']['arguments'], '{"x":1}');
    });

    test('toApiMessage：tool 角色输出 tool_call_id 格式', () {
      final msg = ChatMessage(
        id: 'm2',
        sessionId: 's',
        role: 'tool',
        content: '结果',
        toolCallId: 'c1',
        createdAt: 1,
      );
      final api = msg.toApiMessage();
      expect(api['role'], 'tool');
      expect(api['tool_call_id'], 'c1');
      expect(api['content'], '结果');
    });

    test('旧数据容错：无 tool 列的消息正常加载', () async {
      // 直接用 SQL 插入不含 tool 列数据的行（模拟旧版本数据）
      final d = await db.database;
      await d.execute(
          "INSERT INTO messages (id, session_id, role, content, created_at) "
          "VALUES ('old1', 's1', 'user', '旧消息', 1000)");

      final msgs = await db.getMessages('s1');
      expect(msgs.length, 1);
      expect(msgs[0].toolCalls, isEmpty);
      expect(msgs[0].toolCallId, isNull);
    });
  });
}
