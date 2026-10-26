import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/context_summary.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/context_summary_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock：按脚本逐次返回响应
///
/// 脚本元素语义：String = 以 SseDeltaContent 输出该文本；
/// SseEvent = 原样发出（如 SseError）；null = 抛网络异常。
class MockApiService implements ApiService {
  MockApiService();

  int chatStreamCalls = 0;
  List<Map<String, Object?>>? lastMessages;
  String? lastEffort;
  double? lastTemperature;

  final List<Object?> responses = [];

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
    lastMessages = messages;
    lastEffort = effort;
    lastTemperature = temperature;
    final script = responses.isEmpty ? null : responses.removeAt(0);
    if (script == null) {
      return Stream.error(ApiException('网络失败'));
    }
    if (script is SseEvent) {
      return Stream.value(script);
    }
    return Stream.value(SseDeltaContent(script as String));
  }

  @override
  void dispose() {}
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

ChatMessage assistantWithCalls(String id, String callId,
        {int at = 2}) =>
    ChatMessage(
      id: id,
      sessionId: 's1',
      role: 'assistant',
      content: '',
      toolCalls: [ToolCall(id: callId, name: 'stub', argumentsJson: '{}')],
      createdAt: at,
    );

ChatMessage toolResult(String id, String callId, String content,
        {int at = 3}) =>
    ChatMessage(
      id: id,
      sessionId: 's1',
      role: 'tool',
      content: content,
      toolCallId: callId,
      createdAt: at,
    );

/// 构造 n 个完整轮（user + assistant）；id 以 startId 为基准编号避免拼接时碰撞
List<ChatMessage> simpleRounds(int n, {int startId = 0}) => [
      for (var i = 0; i < n; i++)
        ...[
          user('u${startId + i}', '问题${startId + i}',
              at: startId + i * 10),
          assistant('a${startId + i}', '回答${startId + i}',
              at: startId + i * 10 + 1),
        ],
    ];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late MockApiService api;
  late DatabaseService db;
  late ContextSummaryService service;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    service = ContextSummaryService(api: api, database: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('splitRounds：按轮分组', () {
    test('user 开新轮，assistant/tool 归属同轮', () {
      final rounds = ContextSummaryService.splitRounds([
        user('u0', '问题0'),
        assistant('a0', '回答0'),
        user('u1', '问题1'),
        assistantWithCalls('a1', 'c1'),
        toolResult('t1', 'c1', '结果'),
        assistant('a2', '总结'),
      ]);
      expect(rounds.length, 2);
      expect(rounds[0].messages.map((m) => m.id), ['u0', 'a0']);
      expect(rounds[1].messages.map((m) => m.id), ['u1', 'a1', 't1', 'a2']);
    });

    test('开头无 user 的消息归入第 0 轮', () {
      final rounds = ContextSummaryService.splitRounds([
        assistant('a0', '开场'),
        user('u0', '问题'),
      ]);
      expect(rounds.length, 2);
      expect(rounds[0].messages.map((m) => m.id), ['a0']);
      expect(rounds[1].messages.map((m) => m.id), ['u0']);
    });

    test('空列表：无轮', () {
      expect(ContextSummaryService.splitRounds([]), isEmpty);
    });

    test('isPinned 谓词：轮内任一消息钉住 = 整轮 pinned', () {
      final rounds = ContextSummaryService.splitRounds([
        user('u0', '问题0'),
        assistant('a0', '回答0'),
        user('u1', '问题1'),
        assistant('a1', '回答1'),
      ], isPinned: (m) => m.id == 'a0');
      expect(rounds[0].pinned, isTrue, reason: 'a0 钉住 → 第 0 轮整轮豁免');
      expect(rounds[1].pinned, isFalse);
    });
  });

  group('shouldCompress：水位判断', () {
    test('token 达水位 + 轮数足够：true', () {
      // 10 轮：压缩区 4 轮（10 - keepRounds 6）= minCompressibleRounds
      expect(
        ContextSummaryService.shouldCompress(
          simpleRounds(10),
          lastPromptTokens: ContextSummaryService.watermarkTokens,
        ),
        isTrue,
      );
    });


    test('token 未达水位：false', () {
      expect(
        ContextSummaryService.shouldCompress(
          simpleRounds(10),
          lastPromptTokens: ContextSummaryService.watermarkTokens - 1,
        ),
        isFalse,
      );
    });

    test('无 token 记录（null）：false', () {
      expect(
        ContextSummaryService.shouldCompress(simpleRounds(10)),
        isFalse,
      );
    });

    test('可压缩轮不足（钉住豁免后）：false', () {
      // 6 轮中前 3 轮钉住 → 可压缩只剩 3 轮 < minCompressibleRounds(4)
      final msgs = simpleRounds(6);
      expect(
        ContextSummaryService.shouldCompress(
          msgs,
          lastPromptTokens: ContextSummaryService.watermarkTokens,
          isPinned: (m) => ['u0', 'a0', 'u1', 'a1', 'u2', 'a2'].contains(m.id),
        ),
        isFalse,
      );
    });

    test('总轮数不足（保留窗口吃掉全部）：false', () {
      // keepRounds=6，只有 6 轮 → 无可压缩区
      expect(
        ContextSummaryService.shouldCompress(
          simpleRounds(6),
          lastPromptTokens: ContextSummaryService.watermarkTokens,
        ),
        isFalse,
      );
    });
  });

  group('planRounds：压缩计划', () {
    test('保留最近 keepRounds 轮，其余进压缩区', () {
      final plan = ContextSummaryService.planRounds(simpleRounds(10))!;
      final (compress, kept, pinned) = plan;
      expect(compress.length, 4); // 10 - 6
      expect(compress.first.messages.first.id, 'u0');
      expect(compress.last.messages.first.id, 'u3');
      expect(kept.length, 6);
      expect(kept.first.messages.first.id, 'u4');
      expect(pinned, isEmpty);
    });

    test('钉住轮不占保留名额、永不压缩', () {
      // 11 轮，第 0 轮钉住：非钉住 10 轮 → 压缩区 = u1-u4（4 轮），
      // 保留窗口 = u5-u10（6 轮），钉住的 u0 轮单独返回
      final msgs = simpleRounds(11);
      final plan = ContextSummaryService.planRounds(
        msgs,
        isPinned: (m) => m.id == 'u0' || m.id == 'a0',
      )!;
      final (compress, kept, pinned) = plan;
      expect(
        compress.every((r) => r.messages.first.id != 'u0'),
        isTrue,
        reason: '钉住轮不进压缩区',
      );
      expect(compress.first.messages.first.id, 'u1');
      expect(compress.last.messages.first.id, 'u4');
      expect(kept.first.messages.first.id, 'u5',
          reason: '边界锚定保留窗口首条，钉住轮不作为边界');
      expect(kept.length, 6);
      expect(pinned.length, 1, reason: '钉住轮单独返回');
      expect(pinned.first.messages.first.id, 'u0');
    });

    test('非钉住轮不足：null', () {
      expect(ContextSummaryService.planRounds(simpleRounds(6)), isNull);
    });

    test('压缩区不足 minCompressibleRounds：null', () {
      // 9 轮：压缩区 3 轮 < 4
      expect(ContextSummaryService.planRounds(simpleRounds(9)), isNull);
    });
  });

  group('buildConversationText：对话文本', () {
    test('角色前缀拼接，工具结果带角色，空内容跳过', () {
      final rounds = ContextSummaryService.splitRounds([
        user('u0', '问题0'),
        assistantWithCalls('a0', 'c1'),
        toolResult('t1', 'c1', '工具输出'),
        assistant('a1', ''),
      ]);
      final text = ContextSummaryService.buildConversationText(rounds);
      expect(text, '用户：问题0\n工具结果：工具输出');
    });
  });

  group('compressIfNeeded：端到端', () {
    test('正常压缩：摘要落库，边界指向保留区首条', () async {
      api.responses.add('【关键事实】\n用户在讨论项目排期');

      final summary = await service.compressIfNeeded(
        messages: simpleRounds(10),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );

      expect(summary, isNotNull);
      expect(summary!.summary, contains('关键事实'));
      expect(summary.firstKeptId, 'u4', reason: '保留区首条 = 第 5 轮 user');
      expect(summary.sessionId, 's1');

      // 落库验证
      final stored = await db.getContextSummary('s1');
      expect(stored, isNotNull);
      expect(stored!.summary, summary.summary);
      expect(stored.firstKeptId, 'u4');

      // 请求参数：low 档低温 + system prompt 在头部
      expect(api.chatStreamCalls, 1);
      expect(api.lastEffort, ContextSummaryService.effort);
      expect(api.lastTemperature, ContextSummaryService.temperature);
      expect(api.lastMessages!.first['role'], 'system');
      expect(api.lastMessages!.last['content'], contains('问题0'));
    });

    test('tool_calls 与 tool 结果同轮进摘要文本（成对不拆散）', () async {
      api.responses.add('【关键事实】\n无');
      // 4 简单轮 + 1 工具轮（u4 开轮，assistant tool_calls + tool 结果 +
      // 总结 assistant 同轮）+ 6 简单轮 = 11 轮。
      // 注意 simpleRounds(6, startId: 50) 的 id 从 u5 重新编号
      final msgs = [
        ...simpleRounds(4),
        user('u4', '查时间', at: 40),
        assistantWithCalls('a4', 'c1', at: 41),
        toolResult('t1', 'c1', '12:00', at: 42),
        assistant('a5', '现在是 12 点', at: 43),
        ...simpleRounds(6, startId: 50),
      ];

      final summary = await service.compressIfNeeded(
        messages: msgs,
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );

      expect(summary, isNotNull);
      final sent = api.lastMessages!.last['content'] as String;
      expect(sent, contains('工具结果：12:00'), reason: '工具结果进摘要文本');
      // 11 轮 → 压缩区 5 轮（u0..工具轮），保留区 6 轮（u50..u55）
      expect(summary!.firstKeptId, 'u50', reason: '保留区从第 6 个简单轮开始');
    });

    test('滚动压缩：旧摘要 + 新增轮合并', () async {
      // 第一次压缩：10 轮 → 边界 u4
      api.responses.add('【关键事实】\n第一版摘要');
      final first = await service.compressIfNeeded(
        messages: simpleRounds(10),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );
      expect(first!.firstKeptId, 'u4');

      // 追加 5 轮后再次压缩：scope = u4 之前的消息（10 轮），
      // 压缩区 = 前 4 轮，与旧摘要合并
      api.responses.add('【关键事实】\n合并版摘要');
      final second = await service.compressIfNeeded(
        messages: [...simpleRounds(10), ...simpleRounds(5, startId: 100)],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
        existing: first,
      );

      expect(second, isNotNull);
      final sent = api.lastMessages!.last['content'] as String;
      expect(sent, contains('上一版摘要'), reason: '旧摘要作为合并上下文');
      expect(sent, contains('第一版摘要'));
      expect(second!.summary, '【关键事实】\n合并版摘要');

      // 每会话仅一条：旧摘要被替换
      final stored = await db.getContextSummary('s1');
      expect(stored!.summary, '【关键事实】\n合并版摘要');
    });

    test('钉住轮豁免：钉住消息不进摘要文本，pinnedIds 记录钉住轮', () async {
      api.responses.add('【关键事实】\n无');
      final msgs = simpleRounds(11);
      // 第 0 轮钉住
      final summary = await service.compressIfNeeded(
        messages: msgs,
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
        isPinned: (m) => m.id == 'u0' || m.id == 'a0',
      );

      expect(summary, isNotNull);
      final sent = api.lastMessages!.last['content'] as String;
      expect(sent, isNot(contains('问题0')), reason: '钉住轮不进摘要');
      expect(sent, contains('问题1'));
      // 边界锚定保留窗口首条（u5），钉住轮消息记录在 pinnedIds
      expect(summary!.firstKeptId, 'u5');
      expect(summary.pinnedIds, ['u0', 'a0']);
    });

    test('无可压缩内容：不发请求返回 null', () async {
      final summary = await service.compressIfNeeded(
        messages: simpleRounds(4),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );
      expect(summary, isNull);
      expect(api.chatStreamCalls, 0);
    });

    test('网络失败：静默返回 null，不落库', () async {
      api.responses.add(null);
      final summary = await service.compressIfNeeded(
        messages: simpleRounds(10),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );
      expect(summary, isNull);
      expect(await db.getContextSummary('s1'), isNull);
    });

    test('SseError 事件：静默返回 null', () async {
      api.responses.add(const SseError('服务错误'));
      final summary = await service.compressIfNeeded(
        messages: simpleRounds(10),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );
      expect(summary, isNull);
      expect(await db.getContextSummary('s1'), isNull);
    });

    test('空输出：静默返回 null', () async {
      api.responses.add('');
      final summary = await service.compressIfNeeded(
        messages: simpleRounds(10),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );
      expect(summary, isNull);
    });

    test('滚动压缩 scope 内无可压缩轮：返回 null 不重复压缩', () async {
      // 第一次压缩后边界 u4；scope = 前 10 轮中 u4 之前 = 4 轮可压缩区
      // 已压缩过 → planRounds 对 4 轮 scope 返回 null（4 ≤ keepRounds）
      api.responses.add('【关键事实】\n第一版');
      final first = await service.compressIfNeeded(
        messages: simpleRounds(10),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );
      expect(first, isNotNull);

      // 不新增消息再压：scope = u4 之前 4 轮 → planRounds null
      api.responses.clear();
      final second = await service.compressIfNeeded(
        messages: simpleRounds(10),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
        existing: first,
      );
      expect(second, isNull);
      expect(api.chatStreamCalls, 1, reason: '第二次未发请求');
    });
  });

  group('DB context_summaries CRUD', () {
    test('save 替换旧摘要（每会话仅一条）', () async {
      final s1 = ContextSummary(
        id: 'c1',
        sessionId: 's1',
        summary: '第一版',
        firstKeptId: 'u4',
        firstKeptAt: 40,
        createdAt: 1000,
      );
      await db.saveContextSummary(s1);
      await db.saveContextSummary(s1.copyWith2(summary: '第二版', id: 'c2'));

      final stored = await db.getContextSummary('s1');
      expect(stored!.id, 'c2');
      expect(stored.summary, '第二版');
    });

    test('不同会话摘要隔离', () async {
      await db.saveContextSummary(ContextSummary(
        id: 'c1',
        sessionId: 's1',
        summary: '会话1摘要',
        firstKeptId: 'u4',
        firstKeptAt: 40,
        createdAt: 1000,
      ));
      await db.saveContextSummary(ContextSummary(
        id: 'c2',
        sessionId: 's2',
        summary: '会话2摘要',
        firstKeptId: 'u9',
        firstKeptAt: 90,
        createdAt: 1001,
      ));
      expect((await db.getContextSummary('s1'))!.summary, '会话1摘要');
      expect((await db.getContextSummary('s2'))!.summary, '会话2摘要');
    });

    test('deleteContextSummary 删除', () async {
      await db.saveContextSummary(ContextSummary(
        id: 'c1',
        sessionId: 's1',
        summary: '摘要',
        firstKeptId: 'u4',
        firstKeptAt: 40,
        createdAt: 1000,
      ));
      await db.deleteContextSummary('s1');
      expect(await db.getContextSummary('s1'), isNull);
    });

    test('deleteSession 级联删除摘要', () async {
      await db.insertSession(ChatSession(
        id: 's1',
        title: '会话 s1',
        createdAt: 1000,
        updatedAt: 1000,
      ));
      await db.saveContextSummary(ContextSummary(
        id: 'c1',
        sessionId: 's1',
        summary: '摘要',
        firstKeptId: 'u4',
        firstKeptAt: 40,
        createdAt: 1000,
      ));
      await db.deleteSession('s1');
      expect(await db.getContextSummary('s1'), isNull);
    });
  });
}

/// 测试辅助：copyWith 语义（模型本体保持最小）
extension on ContextSummary {
  ContextSummary copyWith2({String? summary, String? id}) => ContextSummary(
        id: id ?? this.id,
        sessionId: sessionId,
        summary: summary ?? this.summary,
        firstKeptId: firstKeptId,
        firstKeptAt: firstKeptAt,
        createdAt: createdAt,
      );
}
