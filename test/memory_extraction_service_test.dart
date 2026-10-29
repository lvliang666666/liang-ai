import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/memory_extraction_service.dart';
import 'package:ai_chat_app/services/memory_service.dart';
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
  ProviderProfile? lastProfile;
  List<Map<String, Object?>>? lastMessages;
  String? lastModel;
  String? lastEffort;
  double? lastTemperature;

  /// 每次调用按序返回的响应脚本（null = 抛网络异常）
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
    lastProfile = profile;
    lastMessages = messages;
    lastModel = model;
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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late MockApiService api;
  late MemoryService memory;
  late MemoryExtractionService service;

  setUp(() async {
    final inMemory = await openTestDb();
    final db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    memory = MemoryService(database: db);
    service = MemoryExtractionService(api: api, memory: memory);
  });

  tearDown(() async {
    await DatabaseService.instance.close();
  });

  group('shouldExtract：会话是否值得提取', () {
    test('有 user + assistant 交换：true', () {
      expect(
        MemoryExtractionService.shouldExtract(
            [user('我喜欢简洁回答'), assistant('好的，记住了')]),
        isTrue,
      );
    });

    test('只有 user 无回复：false', () {
      expect(MemoryExtractionService.shouldExtract([user('你好')]), isFalse);
    });

    test('空消息列表：false', () {
      expect(MemoryExtractionService.shouldExtract([]), isFalse);
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
        MemoryExtractionService.shouldExtract([user('  '), tool, assistant('')]),
        isFalse,
      );
    });
  });

  group('buildConversationText：会话文本组装', () {
    test('角色前缀逐行拼接，跳过工具结果与空内容', () {
      final tool = ChatMessage(
        id: 't1',
        sessionId: 's1',
        role: 'tool',
        content: '工具输出',
        toolCallId: 'c1',
        createdAt: 3,
      );
      final text = MemoryExtractionService.buildConversationText(
        [user('你好'), assistant(''), tool, assistant('你好呀')],
        sessionTitle: '测试会话',
      );
      expect(text, '会话主题：测试会话\n用户：你好\n助手：你好呀');
    });

    test('超长会话只取最近 maxMessages 条', () {
      final messages = [
        for (var i = 0; i < MemoryExtractionService.maxMessages + 10; i++)
          user('消息$i'),
      ];
      final text = MemoryExtractionService.buildConversationText(messages);
      expect(text.contains('消息${MemoryExtractionService.maxMessages - 1}'),
          isTrue);
      expect(text.contains('消息0'), isFalse);
    });
  });

  group('parseCandidates：JSON 解析', () {
    test('合法 JSON：解析出候选', () {
      final list = MemoryExtractionService.parseCandidates(
          '{"memories": [{"content": "用户喜欢简洁", "tag": "偏好"}]}');
      expect(list, isNotNull);
      expect(list!.length, 1);
      expect(list[0].content, '用户喜欢简洁');
      expect(list[0].tag, '偏好');
    });

    test('markdown 围栏包裹：剥掉后解析', () {
      final list = MemoryExtractionService.parseCandidates(
          '```json\n{"memories": [{"content": "用户在上海"}]}\n```');
      expect(list, isNotNull);
      expect(list!.single.content, '用户在上海');
      expect(list.single.tag, isNull);
    });

    test('JSON 外带说明文字：截取大括号后解析', () {
      final list = MemoryExtractionService.parseCandidates(
          '好的，以下是提取结果：\n{"memories": [{"content": "用户是程序员"}]}\n希望有帮助');
      expect(list, isNotNull);
      expect(list!.single.content, '用户是程序员');
    });

    test('空 memories 数组：返回空列表（合法输出）', () {
      final list =
          MemoryExtractionService.parseCandidates('{"memories": []}');
      expect(list, isNotNull);
      expect(list, isEmpty);
    });

    test('坏 JSON：返回 null（触发重试）', () {
      expect(MemoryExtractionService.parseCandidates('不是 JSON'), isNull);
      expect(
          MemoryExtractionService.parseCandidates('{"memories": ['), isNull);
    });

    test('缺 memories 键：返回 null', () {
      expect(
          MemoryExtractionService.parseCandidates('{"result": []}'), isNull);
    });

    test('content 非字符串或空白的条目被跳过', () {
      final list = MemoryExtractionService.parseCandidates(
          '{"memories": [{"content": "  "}, {"content": 123}, {"content": "有效"}]}');
      expect(list, isNotNull);
      expect(list!.single.content, '有效');
    });
  });

  group('extractAndSave：端到端', () {
    test('正常提取：候选入库，返回条数', () async {
      api.responses.add(
          '{"memories": [{"content": "用户喜欢简洁回答", "tag": "偏好"},'
          '{"content": "用户在上海工作", "tag": "背景"}]}');

      final saved = await service.extractAndSave(
        messages: [user('我喜欢简洁回答'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sourceAgent: '默认助手',
        sessionTitle: '偏好设置',
      );

      expect(saved, 2);
      final all = await memory.getAll();
      expect(all.length, 2);
      expect(all.map((m) => m.content),
          containsAll(['用户喜欢简洁回答', '用户在上海工作']));
      expect(all.every((m) => m.sourceAgent == '默认助手'), isTrue);
    });

    test('请求参数：low 档低温 + system prompt 在头部', () async {
      api.responses.add('{"memories": []}');
      await service.extractAndSave(
        messages: [user('你好'), assistant('你好呀')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );

      expect(api.chatStreamCalls, 1);
      expect(api.lastEffort, MemoryExtractionService.effort);
      expect(api.lastTemperature, MemoryExtractionService.temperature);
      expect(api.lastModel, 'glm5.1');
      final msgs = api.lastMessages!;
      expect(msgs.first['role'], 'system');
      expect(msgs.first['content'], contains('记忆提取器'));
      expect(msgs.last['role'], 'user');
      expect(msgs.last['content'], contains('用户：你好'));
    });

    test('无 user+assistant 交换：不发请求返回 0', () async {
      final saved = await service.extractAndSave(
        messages: [user('你好')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(saved, 0);
      expect(api.chatStreamCalls, 0);
    });

    test('解析失败：回喂重试一次后成功', () async {
      api.responses
        ..add('好的，我提取到了：用户喜欢简洁回答') // 第一次：非 JSON
        ..add('{"memories": [{"content": "用户喜欢简洁回答"}]}'); // 重试成功

      final saved = await service.extractAndSave(
        messages: [user('我喜欢简洁回答'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );

      expect(saved, 1);
      expect(api.chatStreamCalls, 2);
      // 重试请求包含回喂结构：原对话 + 坏输出 + 纠正指令
      final msgs = api.lastMessages!;
      expect(msgs.length, 4);
      expect(msgs[2]['role'], 'assistant');
      expect(msgs[2]['content'], contains('用户喜欢简洁回答'));
      expect(msgs[3]['role'], 'user');
      expect(msgs[3]['content'], contains('重新输出'));
      expect((await memory.getAll()).single.content, '用户喜欢简洁回答');
    });

    test('两次都解析失败：静默返回 0', () async {
      api.responses
        ..add('还是不是 JSON')
        ..add('依然不是 JSON');

      final saved = await service.extractAndSave(
        messages: [user('我喜欢简洁回答'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(saved, 0);
      expect(api.chatStreamCalls, 2);
      expect(await memory.getAll(), isEmpty);
    });

    test('SseError 事件：静默返回 0，不重试', () async {
      api.responses.add(const SseError('服务错误'));

      final saved = await service.extractAndSave(
        messages: [user('我喜欢简洁回答'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(saved, 0);
      expect(api.chatStreamCalls, 1);
      expect(await memory.getAll(), isEmpty);
    });

    test('网络异常：静默返回 0', () async {
      api.responses.add(null); // 脚本 null = 抛 ApiException

      final saved = await service.extractAndSave(
        messages: [user('我喜欢简洁回答'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(saved, 0);
      expect(await memory.getAll(), isEmpty);
    });

    test('去重复用：与既有记忆归一化相同则合并更新，不新增', () async {
      await memory.save('用户喜欢简洁回答', tag: '偏好');
      api.responses.add('{"memories": [{"content": "用户喜欢简洁回答。"}]}');

      final saved = await service.extractAndSave(
        messages: [user('我喜欢简洁回答'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );

      expect(saved, 1);
      final all = await memory.getAll();
      expect(all.length, 1); // 去重生效：仍是 1 条
    });

    test('超长候选截断到 maxMemoryLength', () async {
      final long = '长' * 500;
      api.responses.add('{"memories": [{"content": "$long"}]}');

      await service.extractAndSave(
        messages: [user('说了一堆'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );

      final all = await memory.getAll();
      expect(all.single.content.length,
          MemoryExtractionService.maxMemoryLength);
    });

    test('空输出（流结束无内容）：静默返回 0', () async {
      api.responses.add(''); // _requestJson 对空串返回 null

      final saved = await service.extractAndSave(
        messages: [user('你好'), assistant('你好呀')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(saved, 0);
      expect(api.chatStreamCalls, 1);
    });
  });
}
