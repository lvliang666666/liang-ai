import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/commitment.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/commitment_service.dart';
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
    lastMessages = messages;
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
  late DatabaseService db;
  late CommitmentService service;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    service = CommitmentService(api: api, db: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('extractAndSave：承诺提取', () {
    test('无有效对话返回 0（网络都不发）', () async {
      final n = await service.extractAndSave(
        messages: const [],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(n, 0);
      expect(api.chatStreamCalls, 0);
    });

    test('网络失败静默返回 0，不落库', () async {
      api.responses.add(null);
      final n = await service.extractAndSave(
        messages: [user('我周五前发周报'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(n, 0);
      expect(await db.getAllCommitments(), isEmpty);
    });

    test('合法 JSON：提取承诺入库（content + dueDate）', () async {
      api.responses.add(
          '{"commitments": [{"content": "发周报给组长", "dueDate": "2026-10-31"}]}');
      final n = await service.extractAndSave(
        messages: [user('我周五前发周报'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        sessionId: 's1',
      );
      expect(n, 1);
      final all = await db.getAllCommitments();
      expect(all.single.content, '发周报给组长');
      expect(all.single.dueDate, '2026-10-31');
      expect(all.single.sessionId, 's1');
      expect(all.single.status, Commitment.statusPending);
    });

    test('markdown 围栏包裹：剥壳解析', () async {
      api.responses.add('```json\n'
          '{"commitments": [{"content": "改简历", "dueDate": "2026-11-02"}]}\n'
          '```');
      final n = await service.extractAndSave(
        messages: [user('明天把简历改完'), assistant('加油')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(n, 1);
      expect((await db.getAllCommitments()).single.dueDate, '2026-11-02');
    });

    test('非法 JSON：回喂重试一次后成功', () async {
      api.responses.add('这不是 JSON');
      api.responses.add(
          '{"commitments": [{"content": "约牙医", "dueDate": "2026-11-05"}]}');
      final n = await service.extractAndSave(
        messages: [user('下周约牙医'), assistant('记得去')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(n, 1);
      expect(api.chatStreamCalls, 2, reason: '首次 + 回喂重试');
      expect((await db.getAllCommitments()).single.content, '约牙医');
    });

    test('两次都失败：返回 0 不落库', () async {
      api.responses.add('坏输出');
      api.responses.add('还是坏输出');
      final n = await service.extractAndSave(
        messages: [user('我周五前发周报'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(n, 0);
      expect(await db.getAllCommitments(), isEmpty);
    });

    test('空承诺清单：合法输出返回 0', () async {
      api.responses.add('{"commitments": []}');
      final n = await service.extractAndSave(
        messages: [user('今天天气不错'), assistant('是啊')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(n, 0);
    });

    test('超过上限截断到 maxPerExtraction 条', () async {
      api.responses.add('{"commitments": ['
          '{"content": "任务一", "dueDate": "2026-10-31"},'
          '{"content": "任务二", "dueDate": "2026-11-01"},'
          '{"content": "任务三", "dueDate": "2026-11-02"},'
          '{"content": "任务四", "dueDate": "2026-11-03"}]}');
      final n = await service.extractAndSave(
        messages: [user('一堆事'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(n, CommitmentService.maxPerExtraction);
      expect((await db.getAllCommitments()).length,
          CommitmentService.maxPerExtraction);
    });

    test('非法 dueDate 格式置 null（不参与到期扫描）', () async {
      api.responses.add(
          '{"commitments": [{"content": "模糊任务", "dueDate": "下周"}]}');
      await service.extractAndSave(
        messages: [user('下周把那事办了'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      final all = await db.getAllCommitments();
      expect(all.single.dueDate, isNull);
      expect(all.single.needsFollowUp('2026-10-30'), isFalse);
    });

    test('超长内容截断到 maxContentLength', () async {
      api.responses.add(
          '{"commitments": [{"content": "很长的承诺内容${'啊' * 200}", "dueDate": "2026-10-31"}]}');
      await service.extractAndSave(
        messages: [user('承诺'), assistant('好的')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect((await db.getAllCommitments()).single.content.length,
          CommitmentService.maxContentLength);
    });
  });

  group('scanDue：到期扫描', () {
    test('pending + 到期命中，未来/无期限/已了结不命中', () async {
      await db.insertCommitment(_cm('c1', dueDate: '2026-10-29'));
      await db.insertCommitment(_cm('c2', dueDate: '2026-10-30'));
      await db.insertCommitment(_cm('c3', dueDate: '2026-11-01'));
      await db.insertCommitment(_cm('c4', dueDate: null));
      await db.insertCommitment(_cm('c5',
          dueDate: '2026-10-28', status: Commitment.statusDone));

      final due = await service.scanDue(now: DateTime(2026, 10, 30));
      expect(due.map((c) => c.id).toList(), ['c1', 'c2']);
    });
  });

  group('generateFollowUps：跟进语生成', () {
    test('LLM 失败走本地模板兜底 + follow_up_date 落库', () async {
      await db.insertCommitment(_cm('c1', dueDate: '2026-10-30'));
      api.responses.add(null); // LLM 请求失败
      final result = await service.generateFollowUps(
        [(await db.getAllCommitments()).single],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        now: DateTime(2026, 10, 30),
      );

      expect(result.single.followUp, contains('发周报'));
      expect(result.single.followUpDate, '2026-10-30');
      final stored =
          (await db.getAllCommitments()).where((c) => c.id == 'c1').single;
      expect(stored.followUp, isNotNull);
    });

    test('同一天不重复生成（防打扰）', () async {
      await db.insertCommitment(_cm('c1', dueDate: '2026-10-30'));
      api.responses.add(null);
      final first = await service.generateFollowUps(
        [(await db.getAllCommitments()).single],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        now: DateTime(2026, 10, 30),
      );
      final callsAfterFirst = api.chatStreamCalls;

      // 同一天再跑：follow_up_date 命中直接跳过（不再发请求）
      final again = await service.generateFollowUps(
        [(await db.getAllCommitments()).single],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        now: DateTime(2026, 10, 30),
      );
      expect(again.single.followUp, first.single.followUp);
      expect(api.chatStreamCalls, callsAfterFirst,
          reason: '同天已生成过，不再发 LLM 请求');
    });

    test('profile 为 null 全走本地模板（零网络请求）', () async {
      final result = await service.generateFollowUps(
        [_cm('c1', dueDate: '2026-10-30')],
        now: DateTime(2026, 10, 30),
      );
      expect(result.single.followUp, contains('发周报'));
      expect(api.chatStreamCalls, 0);
    });

    test('api 为 null（scanDue 路径构造）也全走本地模板（零网络请求）', () async {
      // v2.30.6 回归：dio 5.11.1 构造即校验 baseUrl，home_page 的
      // scanDue 路径不再传 api——api 为 null 时必须与 profile null
      // 同语义（本地模板兜底），且不因 _api 空引用崩溃
      final noApiService = CommitmentService(db: db);
      final result = await noApiService.generateFollowUps(
        [_cm('c1', dueDate: '2026-10-30')],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        now: DateTime(2026, 10, 30),
      );
      expect(result.single.followUp, contains('发周报'));
      expect(result.single.followUpDate, '2026-10-30');
      expect(api.chatStreamCalls, 0);
    });

    test('LLM 成功：跟进语用生成值（剥引号）', () async {
      await db.insertCommitment(_cm('c1', dueDate: '2026-10-30'));
      api.responses.add('「周报发了吗？别忘了周五的截止时间」');
      final result = await service.generateFollowUps(
        [(await db.getAllCommitments()).single],
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        now: DateTime(2026, 10, 30),
      );
      expect(result.single.followUp, '周报发了吗？别忘了周五的截止时间');
    });

    test('localFollowUp：模板含承诺内容', () {
      expect(CommitmentService.localFollowUp(_cm('c1')), contains('发周报'));
    });
  });

  group('dateKey', () {
    test('补零格式', () {
      expect(CommitmentService.dateKey(DateTime(2026, 3, 5)), '2026-03-05');
      expect(CommitmentService.dateKey(DateTime(2026, 12, 31)), '2026-12-31');
    });
  });
}

Commitment _cm(String id,
        {String? dueDate = '2026-10-30',
        String status = Commitment.statusPending}) =>
    Commitment(
      id: id,
      sessionId: 's1',
      content: '发周报',
      dueDate: dueDate,
      status: status,
      createdAt: 1000,
      updatedAt: 1000,
    );
