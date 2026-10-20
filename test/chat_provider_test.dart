import 'dart:async';

import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    final inMemory = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              effort TEXT NOT NULL DEFAULT 'max',
              agent_id TEXT,
              skill_id TEXT,
              provider_id TEXT,
              model TEXT
            )
          ''');
          await d.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              role TEXT NOT NULL,
              content TEXT NOT NULL DEFAULT '',
              reasoning TEXT NOT NULL DEFAULT '',
              attachments TEXT NOT NULL DEFAULT '[]',
              tool_calls TEXT NOT NULL DEFAULT '[]',
              tool_call_id TEXT,
              created_at INTEGER NOT NULL
            )
          ''');
          await d.execute(
            'CREATE INDEX idx_messages_session ON messages(session_id, created_at)',
          );
          await d.execute('''
            CREATE TABLE skills (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              icon TEXT NOT NULL DEFAULT '🤖',
              description TEXT NOT NULL DEFAULT '',
              prompt TEXT NOT NULL DEFAULT '',
              temperature REAL,
              effort TEXT,
              tools TEXT,
              is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await d.execute('''
            CREATE TABLE providers (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              base_url TEXT NOT NULL DEFAULT '',
              api_key TEXT NOT NULL DEFAULT '',
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
}
