import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/context_summary.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/context_summary_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock：聊天与摘要请求共用，按脚本逐次返回
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();
  int chatStreamCalls = 0;
  List<Map<String, Object?>>? lastMessages;
  String? lastEffort;

  /// 全部调用的 messages（按序：[0] = 摘要请求，[1] = 聊天请求…）
  final List<List<Map<String, Object?>>> calls = [];

  /// 每次调用按序返回的响应脚本：
  /// - _ChatScript = 返回广播流（聊天请求，测试手动 emit）
  /// - String = 以 SseDeltaContent 单事件输出（摘要请求）
  /// - null = 抛网络异常
  final List<Object?> responses = [];

  void emit(SseEvent event) => _controller.add(event);

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
    calls.add(messages);
    lastMessages = messages;
    lastEffort = effort;
    final script = responses.isEmpty ? _ChatScript() : responses.removeAt(0);
    if (script is _ChatScript) return _controller.stream;
    if (script == null) return Stream.error(ApiException('网络失败'));
    if (script is SseEvent) return Stream.value(script);
    return Stream.value(SseDeltaContent(script as String));
  }

  @override
  void dispose() {}
}

/// 脚本标记：聊天请求返回广播流（测试手动 emit 驱动）
class _ChatScript {
  const _ChatScript();
}

ChatMessage user(String id, String content, {int at = 1}) => ChatMessage(
      id: id,
      sessionId: 's1',
      role: 'user',
      content: content,
      createdAt: at,
    );

ChatMessage assistant(String id, String content, {int at = 2}) => ChatMessage(
      id: id,
      sessionId: 's1',
      role: 'assistant',
      content: content,
      createdAt: at,
    );

/// n 个完整轮（user + assistant），id 从 start 编号
List<ChatMessage> rounds(int n, {int start = 0}) => [
      for (var i = start; i < start + n; i++) ...[
        user('u$i', '问题$i', at: i * 10),
        assistant('a$i', '回答$i', at: i * 10 + 1),
      ],
    ];

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
        id: 's1', title: '新对话', createdAt: 1000, updatedAt: 1000);
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

  /// 等待条件成立（压缩请求在 sendMessage 内 await，但摘要流事件
  /// 投递是异步的）
  Future<void> waitUntil(bool Function() cond,
      {Duration timeout = const Duration(seconds: 2)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) fail('waitUntil 超时');
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  group('F2 压缩管线', () {
    test('未达水位：不触发压缩，历史全量发送', () async {
      await provider.loadMessages();
      // 预置 10 轮历史（无 token 记录 → lastPromptTokens null → 不触发）
      for (final m in rounds(10)) {
        await db.insertMessage(m);
      }
      await provider.loadMessages();

      await provider.sendMessage('新问题');
      await waitUntil(() => api.chatStreamCalls == 1);

      expect(provider.contextSummary, isNull);
      // 历史 20 条 + 新 user 消息 = 21 条
      expect(api.lastMessages!.length, 21);
      expect(provider.status, ChatStatus.thinking);

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);
    });

    test('达水位：sendMessage 内先压缩，请求注入摘要 + 只发保留区', () async {
      await provider.loadMessages();
      // 10 轮历史，最后一轮 assistant 带 promptTokens = 水位线
      for (final m in rounds(10)) {
        await db.insertMessage(m);
      }
      final last = ChatMessage(
        id: 'a9',
        sessionId: 's1',
        role: 'assistant',
        content: '回答9',
        promptTokens: ContextSummaryService.watermarkTokens,
        createdAt: 99,
      );
      await db.insertMessage(last);
      await provider.loadMessages();

      // 摘要请求脚本（sendMessage 内的压缩请求先于聊天请求）
      api.responses.add('【关键事实】\n用户在讨论十个问题');

      await provider.sendMessage('新问题');
      // 压缩完成 + 聊天请求已发出
      await waitUntil(() => api.chatStreamCalls == 2);

      // 摘要已生成并注入（压缩时新 user 消息已入列 → 11 轮 → 边界 u5）
      expect(provider.contextSummary, isNotNull);
      expect(provider.contextSummary!.summary, contains('十个问题'));
      expect(provider.contextSummary!.firstKeptId, 'u5');

      // 聊天请求：system(Skill 无) + 摘要 system + 保留区 10 条 + 新 user
      final msgs = api.lastMessages!;
      final summaryMsg = msgs.firstWhere(
        (m) => (m['content'] as String).contains('前情摘要'),
      );
      expect(summaryMsg['role'], 'system');
      expect(summaryMsg['content'], contains('十个问题'));
      // 保留区 u5..a9 = 10 条 + 新 user 1 条 = 11 条 + 摘要 1 条 = 12
      expect(msgs.length, 12);
      // 早期消息（u0..a4）不在请求里
      final contents = msgs.map((m) => m['content']).toList();
      expect(contents, isNot(contains('问题0')));
      expect(contents, contains('问题5'));

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);

      // 摘要落库
      final stored = await db.getContextSummary('s1');
      expect(stored, isNotNull);
    });

    test('压缩失败（网络错误）：静默跳过，正常发送全量历史', () async {
      await provider.loadMessages();
      for (final m in rounds(10)) {
        await db.insertMessage(m);
      }
      await db.insertMessage(ChatMessage(
        id: 'a9',
        sessionId: 's1',
        role: 'assistant',
        content: '回答9',
        promptTokens: ContextSummaryService.watermarkTokens,
        createdAt: 99,
      ));
      await provider.loadMessages();

      api.responses.add(null); // 摘要请求网络失败

      await provider.sendMessage('新问题');
      await waitUntil(() => api.chatStreamCalls == 2);

      // 无摘要：全量历史发送
      expect(provider.contextSummary, isNull);
      expect(api.lastMessages!.length, 21);
      expect(provider.status, ChatStatus.thinking);

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);
    });

    test('已有摘要时再次触发：滚动合并，边界前移', () async {
      await provider.loadMessages();
      // 预置旧摘要（边界 u4）
      final old = ContextSummary(
        id: 'ctx-old',
        sessionId: 's1',
        summary: '【关键事实】\n旧摘要内容',
        firstKeptId: 'u4',
        firstKeptAt: 40,
        createdAt: 1000,
      );
      await db.saveContextSummary(old);
      for (final m in rounds(15)) {
        await db.insertMessage(m);
      }
      await db.insertMessage(ChatMessage(
        id: 'a14',
        sessionId: 's1',
        role: 'assistant',
        content: '回答14',
        promptTokens: ContextSummaryService.watermarkTokens,
        createdAt: 149,
      ));
      await provider.loadMessages();

      expect(provider.contextSummary!.firstKeptId, 'u4');

      // 滚动压缩：新增素材 = u4..a10（旧保留区滑出窗口的部分）
      api.responses.add('【关键事实】\n合并后摘要');

      await provider.sendMessage('新问题');
      await waitUntil(() => api.chatStreamCalls == 2);

      // 新摘要边界前移到 u10（16 轮 → 压缩区 10 轮 → 保留 u10..a14）
      expect(provider.contextSummary!.firstKeptId, 'u10');
      expect(provider.contextSummary!.summary, contains('合并后摘要'));

      // 摘要请求（第 1 次调用）只喂新增素材（u4..u9），不重复喂 u0..a3
      final summaryReq = api.calls[0];
      final sent = summaryReq.last['content'] as String;
      expect(sent, contains('上一版摘要'));
      expect(sent, contains('旧摘要内容'));
      expect(sent, contains('问题4'));
      expect(sent, isNot(contains('问题0')));

      // 聊天请求（第 2 次调用）：保留区 u10..a14 = 10 条 + 新 user + 摘要 system
      final chatMsgs = api.calls[1];
      final contents = chatMsgs.map((m) => m['content']).toList();
      expect(contents, isNot(contains('问题0')));
      expect(contents, contains('问题10'));

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);
    });

    test('loadMessages 恢复已压缩会话：请求自动带摘要 + 截断历史', () async {
      // 预置摘要 + 历史
      await db.saveContextSummary(ContextSummary(
        id: 'ctx-1',
        sessionId: 's1',
        summary: '【关键事实】\n历史摘要',
        firstKeptId: 'u4',
        firstKeptAt: 40,
        createdAt: 1000,
      ));
      for (final m in rounds(10)) {
        await db.insertMessage(m);
      }
      await provider.loadMessages();

      expect(provider.contextSummary, isNotNull);

      await provider.sendMessage('继续');
      await waitUntil(() => api.chatStreamCalls == 1);

      // 请求：摘要 system + 保留区 12 条 + 新 user = 14 条
      final msgs = api.lastMessages!;
      expect(msgs.length, 14);
      expect(
        (msgs.first['content'] as String).contains('前情摘要'),
        isTrue,
      );
      final contents = msgs.map((m) => m['content']).toList();
      expect(contents, isNot(contains('问题0')));

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);
    });

    test('buildPayloadPreview 反映摘要注入后的真实 payload', () async {
      await db.saveContextSummary(ContextSummary(
        id: 'ctx-1',
        sessionId: 's1',
        summary: '【关键事实】\n历史摘要',
        firstKeptId: 'u4',
        firstKeptAt: 40,
        createdAt: 1000,
      ));
      for (final m in rounds(10)) {
        await db.insertMessage(m);
      }
      await provider.loadMessages();

      final preview = provider.buildPayloadPreview();
      expect(preview.length, 13); // 摘要 1 + 保留区 12
      expect(
        (preview.first['content'] as String).contains('前情摘要'),
        isTrue,
      );
    });
  });

  group('F2.3 钉住消息', () {
    test('setMessagePinned：内存同步 + DB 落盘', () async {
      await provider.loadMessages();
      final msg = user('u0', '关键约束', at: 1);
      await db.insertMessage(msg);
      await provider.loadMessages();

      await provider.setMessagePinned(provider.messages.first, true);
      expect(provider.messages.first.pinned, isTrue);

      // 落盘验证：重新 load 读回
      await provider.loadMessages();
      expect(provider.messages.first.pinned, isTrue);

      await provider.setMessagePinned(provider.messages.first, false);
      await provider.loadMessages();
      expect(provider.messages.first.pinned, isFalse);
    });

    test('钉住早期轮：压缩边界跳过钉住轮，钉住轮原文保留在请求里', () async {
      // 11 轮历史（u0..a10），最后一轮带水位 token；钉住第 0 轮
      for (final m in rounds(11)) {
        await db.insertMessage(m);
      }
      await db.insertMessage(ChatMessage(
        id: 'a10',
        sessionId: 's1',
        role: 'assistant',
        content: '回答10',
        promptTokens: ContextSummaryService.watermarkTokens,
        createdAt: 109,
      ));
      await db.setMessagePinned('u0', true);
      await db.setMessagePinned('a0', true);
      await provider.loadMessages();

      // sendMessage 追加新 user 后共 12 轮，钉住 1 轮 → 非钉住 11 轮
      // → 压缩区 = u1..u5（5 轮），保留窗口 = u6..a10 + 新 user
      api.responses.add('【关键事实】\n钉住豁免后的摘要');

      await provider.sendMessage('新问题');
      await waitUntil(() => api.chatStreamCalls == 2);

      // 边界 = u6（u1..u5 压缩，u0 钉住豁免，u6..a10 保留窗口）
      expect(provider.contextSummary, isNotNull);
      expect(provider.contextSummary!.firstKeptId, 'u6');
      // 钉住轮消息记录在 pinnedIds
      expect(provider.contextSummary!.pinnedIds, ['u0', 'a0']);

      // 钉住轮原文仍在请求里（未被压缩掉）
      final msgs = api.lastMessages!;
      final contents = msgs.map((m) => m['content']).toList();
      expect(contents, contains('问题0'));
      expect(contents, isNot(contains('问题1')));
      expect(contents, contains('问题6'));

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);
    });

    test('钉住轮不占保留窗口名额：钉住多轮时保留区含钉住轮 + 窗口轮', () async {
      // 12 轮历史（u0..a11），钉住 u0/a0 与 u1/a1 两轮
      for (final m in rounds(12)) {
        await db.insertMessage(m);
      }
      await db.insertMessage(ChatMessage(
        id: 'a11',
        sessionId: 's1',
        role: 'assistant',
        content: '回答11',
        promptTokens: ContextSummaryService.watermarkTokens,
        createdAt: 119,
      ));
      for (final id in ['u0', 'a0', 'u1', 'a1']) {
        await db.setMessagePinned(id, true);
      }
      await provider.loadMessages();

      // sendMessage 追加新 user 后共 13 轮，钉住 2 轮 → 非钉住 11 轮
      // → 压缩区 = u2..u6（5 轮），保留窗口 = u7..a11 + 新 user
      api.responses.add('【关键事实】\n摘要');

      await provider.sendMessage('新问题');
      await waitUntil(() => api.chatStreamCalls == 2);

      expect(provider.contextSummary!.firstKeptId, 'u7');

      final msgs = api.lastMessages!;
      final contents = msgs.map((m) => m['content']).toList();
      // 钉住轮原文保留
      expect(contents, contains('问题0'));
      expect(contents, contains('问题1'));
      // 压缩区消失
      expect(contents, isNot(contains('问题2')));
      expect(contents, isNot(contains('问题6')));
      // 保留窗口在
      expect(contents, contains('问题7'));

      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);
    });
  });
}
