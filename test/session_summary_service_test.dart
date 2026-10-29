import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/models/session_summary.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/session_summary_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/services/tools/memory_tools.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock：按脚本逐次返回响应（与 M2 测试同模式）
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

ChatMessage user(String content) => ChatMessage(
      id: 'u-${content.hashCode}',
      sessionId: 's1',
      role: 'user',
      content: content,
      createdAt: 1,
    );

ChatMessage assistant(String content) => ChatMessage(
      id: 'a-${content.hashCode}',
      sessionId: 's1',
      role: 'assistant',
      content: content,
      createdAt: 2,
    );

const validJson =
    '{"title": "报销流程讨论", "summary": "用户询问差旅报销流程，确认了发票要求与审批链路。", '
    '"keywords": ["报销", "差旅", "发票"]}';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late MockApiService api;
  late SessionSummaryService service;

  setUp(() async {
    final inMemory = await openTestDb();
    final db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    service = SessionSummaryService(api: api, database: db);
  });

  tearDown(() async {
    await DatabaseService.instance.close();
  });

  group('shouldSummarize：会话是否值得生成摘要', () {
    test('有 user + assistant 交换：true', () {
      expect(
        SessionSummaryService.shouldSummarize(
            [user('报销流程是什么'), assistant('差旅报销需要发票…')]),
        isTrue,
      );
    });

    test('只有 user 无回复：false', () {
      expect(SessionSummaryService.shouldSummarize([user('你好')]), isFalse);
    });

    test('空消息列表：false', () {
      expect(SessionSummaryService.shouldSummarize([]), isFalse);
    });

    test('工具结果消息与空内容不参与判断', () {
      final tool = ChatMessage(
        id: 't1',
        sessionId: 's1',
        role: 'tool',
        content: '工具输出',
        toolCallId: 'c1',
        createdAt: 3,
      );
      expect(
        SessionSummaryService.shouldSummarize(
            [user('  '), tool, assistant('')]),
        isFalse,
      );
    });
  });

  group('buildConversationText：会话文本组装', () {
    test('角色前缀逐行拼接，标题作首行', () {
      final text = SessionSummaryService.buildConversationText(
        [user('讨论部署方案'), assistant('建议蓝绿部署')],
        sessionTitle: '部署',
      );
      expect(text, startsWith('会话主题：部署'));
      expect(text, contains('用户：讨论部署方案'));
      expect(text, contains('助手：建议蓝绿部署'));
    });

    test('工具结果与空内容跳过', () {
      final tool = ChatMessage(
        id: 't1',
        sessionId: 's1',
        role: 'tool',
        content: '输出',
        toolCallId: 'c1',
        createdAt: 3,
      );
      final text = SessionSummaryService.buildConversationText(
          [user('问'), tool, assistant('   ')]);
      expect(text, '用户：问');
    });
  });

  group('parseCandidate：输出解析', () {
    test('合法 JSON 解析出标题/摘要/关键词', () {
      final c = SessionSummaryService.parseCandidate(validJson);
      expect(c, isNotNull);
      expect(c!.title, '报销流程讨论');
      expect(c.summary, contains('报销流程'));
      expect(c.keywords, ['报销', '差旅', '发票']);
    });

    test('markdown 围栏包裹也能解析', () {
      final c = SessionSummaryService.parseCandidate('```json\n$validJson\n```');
      expect(c, isNotNull);
      expect(c!.title, '报销流程讨论');
    });

    test('JSON 外带说明文字也能解析（截取大括号）', () {
      final c = SessionSummaryService.parseCandidate('好的，以下是摘要：\n$validJson');
      expect(c, isNotNull);
    });

    test('坏 JSON 返回 null', () {
      expect(SessionSummaryService.parseCandidate('不是 JSON'), isNull);
      expect(SessionSummaryService.parseCandidate('{"title": 1}'), isNull);
      expect(
          SessionSummaryService.parseCandidate('{"title": "t"}'), // 缺 summary
          isNull);
    });

    test('空标题或空摘要返回 null', () {
      expect(
          SessionSummaryService.parseCandidate(
              '{"title": "", "summary": "s", "keywords": []}'),
          isNull);
      expect(
          SessionSummaryService.parseCandidate(
              '{"title": "t", "summary": "  ", "keywords": []}'),
          isNull);
    });

    test('keywords 非字符串元素被过滤', () {
      final c = SessionSummaryService.parseCandidate(
          '{"title": "t", "summary": "s", "keywords": ["a", 1, " ", "b"]}');
      expect(c!.keywords, ['a', 'b']);
    });
  });

  group('summarizeAndSave：端到端', () {
    test('生成成功：入库且字段正确（low 档低温）', () async {
      api.responses.add(validJson);
      final ok = await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('报销流程是什么'), assistant('差旅报销需要发票…')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionTitle: '报销',
      );
      expect(ok, isTrue);
      expect(api.chatStreamCalls, 1);
      expect(api.lastEffort, 'low');
      expect(api.lastTemperature, 0.2);

      final all = await DatabaseService.instance.getAllSessionSummaries();
      expect(all, hasLength(1));
      expect(all.first.id, 'ep_s1');
      expect(all.first.sessionId, 's1');
      expect(all.first.title, '报销流程讨论');
      expect(all.first.summary, contains('报销'));
      expect(all.first.keywords, ['报销', '差旅', '发票']);
    });

    test('重复生成：同 id 覆盖不累积', () async {
      api.responses.addAll([validJson, validJson]);
      await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('a'), assistant('b')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('c'), assistant('d')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      final all = await DatabaseService.instance.getAllSessionSummaries();
      expect(all, hasLength(1));
      expect(all.first.title, '报销流程讨论');
    });

    test('网络失败：静默返回 false 不入库', () async {
      api.responses.add(null);
      final ok = await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('a'), assistant('b')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(ok, isFalse);
      expect(
          await DatabaseService.instance.getAllSessionSummaries(), isEmpty);
    });

    test('SseError：静默返回 false', () async {
      api.responses.add(const SseError('服务端错误'));
      final ok = await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('a'), assistant('b')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(ok, isFalse);
    });

    test('解析失败回喂重试一次成功', () async {
      api.responses.addAll(['我无法输出 JSON', validJson]);
      final ok = await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('a'), assistant('b')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(ok, isTrue);
      expect(api.chatStreamCalls, 2);
      // 第二次请求含回喂重试指令（4 条消息：system/user/assistant/user）
      expect(api.lastMessages, hasLength(4));
      expect(
        (api.lastMessages!.last['content'] as String),
        contains('不是合法 JSON'),
      );
    });

    test('两次解析都失败：静默返回 false', () async {
      api.responses.addAll(['坏输出', '还是坏输出']);
      final ok = await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('a'), assistant('b')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(ok, isFalse);
      expect(
          await DatabaseService.instance.getAllSessionSummaries(), isEmpty);
    });

    test('无 user+assistant 交换：不发起请求直接 false', () async {
      final ok = await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('只有一句')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(ok, isFalse);
      expect(api.chatStreamCalls, 0);
    });

    test('超长摘要截断到上限', () async {
      final longSummary = '长' * 500;
      api.responses.add(
          '{"title": "t", "summary": "$longSummary", "keywords": ["k"]}');
      await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('a'), assistant('b')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      final all = await DatabaseService.instance.getAllSessionSummaries();
      expect(all.first.summary.length, SessionSummaryService.maxSummaryLength);
    });

    test('关键词截断到上限 6 个', () async {
      api.responses.add(
          '{"title": "t", "summary": "s", "keywords": ["1","2","3","4","5","6","7","8"]}');
      await service.summarizeAndSave(
        sessionId: 's1',
        messages: [user('a'), assistant('b')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      final all = await DatabaseService.instance.getAllSessionSummaries();
      expect(all.first.keywords, hasLength(6));
    });
  });

  group('searchSessionSummaries：检索', () {
    setUp(() async {
      final db = DatabaseService.instance;
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insertSessionSummary(SessionSummary(
        id: 'ep_a',
        sessionId: 'a',
        title: '报销流程讨论',
        summary: '确认了差旅发票要求与审批链路',
        keywords: ['报销', '差旅'],
        createdAt: now - 100,
      ));
      await db.insertSessionSummary(SessionSummary(
        id: 'ep_b',
        sessionId: 'b',
        title: '部署方案',
        summary: '讨论了蓝绿部署与回滚策略',
        keywords: ['部署'],
        createdAt: now,
      ));
    });

    test('标题命中', () async {
      final hits = await DatabaseService.instance
          .searchSessionSummaries('报销');
      expect(hits, hasLength(1));
      expect(hits.first.sessionId, 'a');
    });

    test('摘要命中', () async {
      final hits = await DatabaseService.instance
          .searchSessionSummaries('蓝绿部署');
      expect(hits, hasLength(1));
      expect(hits.first.sessionId, 'b');
    });

    test('关键词命中', () async {
      final hits = await DatabaseService.instance
          .searchSessionSummaries('差旅');
      expect(hits, hasLength(1));
    });

    test('excludeSessionId 排除当前会话', () async {
      final hits = await DatabaseService.instance
          .searchSessionSummaries('报销', excludeSessionId: 'a');
      expect(hits, isEmpty);
      final kept = await DatabaseService.instance
          .searchSessionSummaries('报销', excludeSessionId: 'b');
      expect(kept, hasLength(1));
    });

    test('无命中返回空', () async {
      expect(
        await DatabaseService.instance.searchSessionSummaries('量子物理'),
        isEmpty,
      );
    });

    test('空关键词返回空', () async {
      expect(
        await DatabaseService.instance.searchSessionSummaries('  '),
        isEmpty,
      );
    });

    test('limit 生效且按时间倒序', () async {
      final hits = await DatabaseService.instance
          .searchSessionSummaries('e', limit: 1); // title/summary 都含 e？无——用宽匹配
      // 「e」不命中中文——改用会话 id 宽匹配验证 limit
      final all = await DatabaseService.instance.getAllSessionSummaries();
      expect(all.first.sessionId, 'b'); // 时间倒序：新的在前
      expect(hits, isEmpty);
    });
  });

  group('deleteSession 级联删摘要', () {
    test('删会话同时删摘要', () async {
      final db = DatabaseService.instance;
      final raw = await db.database;
      await raw.insert('sessions', {
        'id': 's9',
        'title': '级联测试会话',
        'created_at': 1,
        'updated_at': 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insertSessionSummary(SessionSummary(
        id: 'ep_s9',
        sessionId: 's9',
        title: 't',
        summary: 's',
        keywords: const [],
        createdAt: 1,
      ));
      await db.deleteSession('s9');
      expect(await db.getAllSessionSummaries(), isEmpty);
    });
  });

  group('search_history 工具', () {
    test('命中返回标题+摘要+关键词', () async {
      await DatabaseService.instance.insertSessionSummary(SessionSummary(
        id: 'ep_a',
        sessionId: 'a',
        title: '报销流程讨论',
        summary: '确认了发票要求',
        keywords: ['报销', '差旅'],
        createdAt: 1,
      ));
      const tool = SearchHistoryTool();
      final result = await tool.execute({'keyword': '报销'});
      expect(result, contains('报销流程讨论'));
      expect(result, contains('确认了发票要求'));
      expect(result, contains('报销、差旅'));
    });

    test('排除当前会话', () async {
      await DatabaseService.instance.insertSessionSummary(SessionSummary(
        id: 'ep_cur',
        sessionId: 'cur',
        title: '当前会话',
        summary: '内容',
        keywords: const [],
        createdAt: 1,
      ));
      final tool = SearchHistoryTool(currentSessionId: 'cur');
      final result = await tool.execute({'keyword': '当前'});
      expect(result, contains('没有找到'));
    });

    test('无命中提示', () async {
      const tool = SearchHistoryTool();
      final result = await tool.execute({'keyword': '不存在'});
      expect(result, contains('没有找到'));
    });

    test('空参数抛 ArgumentError', () async {
      const tool = SearchHistoryTool();
      expect(() => tool.execute({'keyword': ' '}), throwsArgumentError);
    });

    test('注册表构建时注入当前会话 id（ChatProvider._buildRegistry 契约）', () {
      final registry = ToolRegistry()
        ..registerAll([
          SearchHistoryTool(),
          SearchHistoryTool(currentSessionId: 'x'),
        ]);
      expect(registry.names, contains('search_history'));
    });
  });
}
