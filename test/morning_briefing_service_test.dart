import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/memory.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/morning_briefing_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock：按脚本逐次返回响应（与 M2/M4 测试同模式）
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

const validJson = '{"greeting": "早上好，今天也要加油", '
    '"almanac": "宜出行会友，忌动土开仓", '
    '"fortune": "上签，宜稳步推进", '
    '"memory": "你最近在准备考试，加油", '
    '"flashback": "上周今天聊了报销流程"}';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late MockApiService api;
  late DatabaseService db;
  late MorningBriefingService service;

  /// 固定时钟：2026-10-30 08:00（周五）
  DateTime now() => DateTime(2026, 10, 30, 8, 0);

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    service = MorningBriefingService(api: api, database: db);
  });

  tearDown(() async {
    await db.close();
  });

  ProviderProfile profile() => ProviderProfile.builtinCompany();

  /// 预置：一条 7 天前的会话（含消息）+ 一条活跃记忆
  Future<void> seedData() async {
    final anchor = DateTime(2026, 10, 23, 14, 0); // 7 天前
    final ms = anchor.millisecondsSinceEpoch;
    await db.insertSession(ChatSession(
      id: 's-old',
      title: '报销流程讨论',
      createdAt: ms,
      updatedAt: ms,
    ));
    await db.insertMessage(ChatMessage(
      id: 'm1',
      sessionId: 's-old',
      role: 'user',
      content: '差旅报销流程是什么',
      createdAt: ms,
    ));
    await db.insertMessage(ChatMessage(
      id: 'm2',
      sessionId: 's-old',
      role: 'assistant',
      content: '需要发票与审批单',
      createdAt: ms + 1000,
    ));
    await db.insertMemory(Memory(
      id: 'mem1',
      content: '用户喜欢简洁回答',
      createdAt: ms,
      updatedAt: ms,
    ));
  }

  group('generate：LLM 生成路径', () {
    test('合法 JSON：五段全解析，fromLlm=true', () async {
      await seedData();
      api.responses.add(validJson);

      final b = await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      expect(b.fromLlm, isTrue);
      expect(b.dateKey, '2026-10-30');
      expect(b.greeting, '早上好，今天也要加油');
      expect(b.almanac, '宜出行会友，忌动土开仓');
      expect(b.fortune, '上签，宜稳步推进');
      expect(b.memory, '你最近在准备考试，加油');
      expect(b.flashback, '上周今天聊了报销流程');
      // 玄学原文随简报返回（详情展开用）
      expect(b.huangliRaw, contains('黄历'));
      expect(b.huangliRaw, contains('宜：'));
      expect(b.fortuneRaw, contains('观音灵签'));
    });

    test('请求走 low 档低温；素材含黄历/记忆/上周会话', () async {
      await seedData();
      api.responses.add(validJson);

      await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      expect(api.chatStreamCalls, 1);
      expect(api.lastEffort, 'low');
      expect(api.lastTemperature, 0.2);
      final userMsg = api.lastMessages!.last['content'] as String;
      expect(userMsg, contains('2026-10-30'));
      expect(userMsg, contains('周五'));
      expect(userMsg, contains('【黄历】'));
      expect(userMsg, contains('【今日灵签】'));
      expect(userMsg, contains('用户喜欢简洁回答'));
      expect(userMsg, contains('报销流程讨论'));
      expect(userMsg, contains('差旅报销流程是什么'));
    });

    test('markdown 围栏包裹：剥壳后正常解析', () async {
      api.responses.add('```json\n$validJson\n```');

      final b = await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      expect(b.fromLlm, isTrue);
      expect(b.greeting, '早上好，今天也要加油');
    });

    test('JSON 外带说明文字：截取花括号容错', () async {
      api.responses.add('好的：\n$validJson\n希望有帮助');

      final b = await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      expect(b.fromLlm, isTrue);
      expect(b.greeting, '早上好，今天也要加油');
    });

    test('解析失败：回喂重试一次后成功', () async {
      api.responses..add('不是 JSON')..add(validJson);

      final b = await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      expect(api.chatStreamCalls, 2);
      expect(b.fromLlm, isTrue);
      // 重试请求包含坏输出（assistant 轮）与纠正指令
      final msgs = api.lastMessages!;
      expect(msgs.length, 4);
      expect(msgs[2]['role'], 'assistant');
      expect(msgs[3]['role'], 'user');
      expect(msgs[3]['content'], contains('重新输出'));
    });

    test('skipFortune=true：素材不含灵签段', () async {
      api.responses.add(validJson);

      await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
        skipFortune: true,
      );

      final userMsg = api.lastMessages!.last['content'] as String;
      expect(userMsg, contains('【黄历】'));
      expect(userMsg, isNot(contains('【今日灵签】')));
      expect(api.lastMessages!.last['content'], isA<String>());
    });
  });

  group('generate：本地回退路径', () {
    test('网络失败：本地拼装简报，fromLlm=false', () async {
      await seedData();
      api.responses.add(null); // 网络异常

      final b = await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      expect(b.fromLlm, isFalse);
      expect(b.dateKey, '2026-10-30');
      expect(b.greeting, isNotEmpty);
      // 宜忌从黄历原文提取
      expect(b.almanac, contains('宜：'));
      expect(b.almanac, contains('忌：'));
      // 灵签签号行提取
      expect(b.fortune, matches(RegExp(r'第 \d+ 签')));
      // 记忆与上周会话直出
      expect(b.memory, contains('用户喜欢简洁回答'));
      expect(b.flashback, contains('报销流程讨论'));
    });

    test('解析两次失败：同样本地回退', () async {
      api.responses..add('坏输出')..add('还是坏输出');

      final b = await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      expect(api.chatStreamCalls, 2);
      expect(b.fromLlm, isFalse);
    });

    test('空库（无记忆无上周会话）：回退简报对应段为空', () async {
      api.responses.add(null);

      final b = await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      expect(b.fromLlm, isFalse);
      expect(b.memory, isEmpty);
      expect(b.flashback, isEmpty);
      expect(b.almanac, isNotEmpty, reason: '黄历是确定性工具，永远有值');
    });
  });

  group('素材收集边界', () {
    test('上周窗口外（9 天前/3 天前）的会话不参与', () async {
      // 锚点 = 7 天前（10-23），±1 天窗口 = 6/7/8 天前；9 天前与 3 天前都出窗
      final d9 = DateTime(2026, 10, 21, 10, 0).millisecondsSinceEpoch;
      final d3 = DateTime(2026, 10, 27, 10, 0).millisecondsSinceEpoch;
      await db.insertSession(ChatSession(
        id: 's-9d',
        title: '九天前的会话',
        createdAt: d9,
        updatedAt: d9,
      ));
      await db.insertSession(ChatSession(
        id: 's-3d',
        title: '三天前的会话',
        createdAt: d3,
        updatedAt: d3,
      ));
      api.responses.add(validJson);

      await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      final userMsg = api.lastMessages!.last['content'] as String;
      expect(userMsg, isNot(contains('九天前的会话')));
      expect(userMsg, isNot(contains('三天前的会话')));
    });

    test('窗口边界（6 天前与 8 天前）的会话参与', () async {
      final d6 = DateTime(2026, 10, 24, 10, 0).millisecondsSinceEpoch;
      final d8 = DateTime(2026, 10, 22, 10, 0).millisecondsSinceEpoch;
      await db.insertSession(ChatSession(
        id: 's-6d',
        title: '六天前的会话',
        createdAt: d6,
        updatedAt: d6,
      ));
      await db.insertSession(ChatSession(
        id: 's-8d',
        title: '八天前的会话',
        createdAt: d8,
        updatedAt: d8,
      ));
      api.responses.add(validJson);

      await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      final userMsg = api.lastMessages!.last['content'] as String;
      expect(userMsg, contains('六天前的会话'));
      expect(userMsg, contains('八天前的会话'));
    });

    test('归档记忆与衰减事件记忆不参与素材', () async {
      final old = DateTime(2026, 9, 1).millisecondsSinceEpoch;
      await db.insertMemory(Memory(
        id: 'mem-arch',
        content: '归档摘要行',
        tag: Memory.archiveTag,
        createdAt: old,
        updatedAt: old,
      ));
      await db.insertMemory(Memory(
        id: 'mem-decayed',
        content: '很久以前的事件',
        layer: Memory.layerEvent,
        createdAt: old,
        updatedAt: old,
      ));
      api.responses.add(validJson);

      await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      final userMsg = api.lastMessages!.last['content'] as String;
      expect(userMsg, isNot(contains('归档摘要行')));
      expect(userMsg, isNot(contains('很久以前的事件')));
    });

    test('工具结果消息不进上周会话预览', () async {
      final ms = DateTime(2026, 10, 23, 14, 0).millisecondsSinceEpoch;
      await db.insertSession(ChatSession(
        id: 's-old',
        title: '带工具的会话',
        createdAt: ms,
        updatedAt: ms,
      ));
      await db.insertMessage(ChatMessage(
        id: 'm1',
        sessionId: 's-old',
        role: 'user',
        content: '查一下天气',
        createdAt: ms,
      ));
      await db.insertMessage(ChatMessage(
        id: 'm2',
        sessionId: 's-old',
        role: 'tool',
        content: '{"temp": 25}',
        createdAt: ms + 500,
      ));
      api.responses.add(validJson);

      await service.generate(
        profile: profile(),
        model: 'glm5.1',
        now: now(),
      );

      final userMsg = api.lastMessages!.last['content'] as String;
      expect(userMsg, contains('查一下天气'));
      expect(userMsg, isNot(contains('{"temp": 25}')));
    });
  });

  group('parseDraft：模型输出解析', () {
    test('全空字段（模型没理解任务）：返回 null', () {
      expect(
        MorningBriefingService.parseDraft(
            '{"greeting": "", "almanac": "", "fortune": ""}'),
        isNull,
      );
    });

    test('非 JSON 文本：返回 null', () {
      expect(MorningBriefingService.parseDraft('今天天气不错'), isNull);
    });

    test('只有 greeting：有效（其余段可空）', () {
      final d = MorningBriefingService.parseDraft('{"greeting": "早"}');
      expect(d, isNotNull);
      expect(d!.greeting, '早');
      expect(d.almanac, isNull);
    });
  });
}
