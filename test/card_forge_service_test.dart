import 'package:ai_chat_app/models/card.dart';
import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/card_forge_service.dart';
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

ChatMessage msg(String content, {String role = 'user', String id = 'm1'}) =>
    ChatMessage(
      id: id,
      sessionId: 's1',
      role: role,
      content: content,
      createdAt: 1,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late MockApiService api;
  late DatabaseService db;
  late CardForgeService service;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    service = CardForgeService(
      api: api,
      db: db,
    );
  });

  tearDown(() async {
    await db.close();
  });

  ProviderProfile profile() => ProviderProfile.builtinCompany();

  group('parseCard：模型输出解析', () {
    test('合法 JSON：title/content/tags 全解析', () {
      final draft = CardForgeService.parseCard(
          '{"title": "报销发票要求", "content": "发票抬头必须与公司名一致", '
          '"tags": ["财务", "报销"]}');
      expect(draft, isNotNull);
      expect(draft!.title, '报销发票要求');
      expect(draft.content, '发票抬头必须与公司名一致');
      expect(draft.tags, '财务,报销');
    });

    test('markdown 围栏包裹：剥壳后正常解析', () {
      final draft = CardForgeService.parseCard(
          '```json\n{"title": "T", "content": "C", "tags": []}\n```');
      expect(draft, isNotNull);
      expect(draft!.title, 'T');
      expect(draft.tags, isNull, reason: '空 tags 数组 → null');
    });

    test('JSON 外带说明文字：截取花括号容错', () {
      final draft = CardForgeService.parseCard(
          '好的，这是卡片：\n{"title": "T", "content": "C"}\n希望有帮助');
      expect(draft, isNotNull);
      expect(draft!.title, 'T');
    });

    test('坏 JSON：null（触发回喂重试）', () {
      expect(CardForgeService.parseCard('这不是 JSON'), isNull);
      expect(CardForgeService.parseCard('{"title": }'), isNull);
    });

    test('缺 content 字段：null', () {
      expect(CardForgeService.parseCard('{"title": "T"}'), isNull);
    });

    test('空 title/content：null', () {
      expect(
          CardForgeService.parseCard('{"title": " ", "content": "C"}'), isNull);
      expect(
          CardForgeService.parseCard('{"title": "T", "content": ""}'), isNull);
    });

    test('超长 title/content 截断到上限', () {
      final longTitle = '标' * 100;
      final longContent = '内' * 3000;
      final draft = CardForgeService.parseCard(
          '{"title": "$longTitle", "content": "$longContent"}');
      expect(draft!.title.length, CardForgeService.maxTitleLength);
      expect(draft.content.length, CardForgeService.maxContentLength);
    });

    test('tags 超过 3 个只取前 3 个', () {
      final draft = CardForgeService.parseCard(
          '{"title": "T", "content": "C", "tags": ["a", "b", "c", "d", "e"]}');
      expect(draft!.tags, 'a,b,c');
    });
  });

  group('forge：提炼 + 入库', () {
    test('正常提炼：LLM 输出入库，卡片字段齐全', () async {
      api.responses.add(
          '{"title": "Dart Stream 背压", "content": "Stream 有缓冲区上限，'
          '消费慢时暂停生产端", "tags": ["编程", "Dart"]}');

      final card = await service.forge(
        message: msg('帮我总结一下 Dart Stream 的背压机制'),
        profile: profile(),
        model: 'glm5.1',
      );

      expect(card.title, 'Dart Stream 背压');
      expect(card.content, contains('缓冲区上限'));
      expect(card.tags, '编程,Dart');
      expect(card.sessionId, 's1');
      expect(card.sourceMessageId, 'm1');

      // 入库验证
      final all = await db.getAllCards();
      expect(all.length, 1);
      expect(all.single.id, card.id);

      // 请求参数：low 档低温
      expect(api.lastEffort, CardForgeService.effort);
      expect(api.lastTemperature, CardForgeService.temperature);
      expect(api.chatStreamCalls, 1);
    });

    test('坏 JSON 回喂重试一次：第二次成功', () async {
      api.responses.addAll([
        '抱歉我无法输出 JSON',
        '{"title": "重试成功", "content": "第二次输出", "tags": ["标签"]}',
      ]);

      final card = await service.forge(
        message: msg('内容'),
        profile: profile(),
        model: 'glm5.1',
      );

      expect(api.chatStreamCalls, 2, reason: '回喂重试一次');
      expect(card.title, '重试成功');
      expect(card.content, '第二次输出');
    });

    test('两次都失败：本地回退（首行为标题，全文为正文）', () async {
      api.responses.addAll(['坏输出一', '坏输出二']);

      final card = await service.forge(
        message: msg('第一行是标题\n后面是正文内容'),
        profile: profile(),
        model: 'glm5.1',
      );

      expect(api.chatStreamCalls, 2);
      expect(card.title, '第一行是标题');
      expect(card.content, '第一行是标题\n后面是正文内容');
      expect(card.tags, isNull, reason: '本地回退无标签');

      final all = await db.getAllCards();
      expect(all.length, 1, reason: '回退卡片同样入库');
    });

    test('网络失败：本地回退，不抛异常', () async {
      api.responses.add(null); // 抛网络异常

      final card = await service.forge(
        message: msg('离线也能存卡'),
        profile: profile(),
        model: 'glm5.1',
      );

      expect(api.chatStreamCalls, 1, reason: '网络失败不重试（重试也会失败）');
      expect(card.title, '离线也能存卡');
      expect(card.content, '离线也能存卡');
    });

    test('SseError：本地回退', () async {
      api.responses.add(const SseError('服务错误'));

      final card = await service.forge(
        message: msg('内容'),
        profile: profile(),
        model: 'glm5.1',
      );

      expect(card.title, '内容');
    });

    test('空消息：不发请求直接本地回退', () async {
      final card = await service.forge(
        message: msg(''),
        profile: profile(),
        model: 'glm5.1',
      );

      expect(api.chatStreamCalls, 0);
      expect(card.title, '无文字消息');
      expect(card.content, '');
    });

    test('同一消息多次沉淀：各自成卡（用户策展，无去重）', () async {
      api.responses.addAll([
        '{"title": "卡一", "content": "第一次", "tags": []}',
        '{"title": "卡二", "content": "第二次", "tags": []}',
      ]);

      await service.forge(
          message: msg('同一条消息'), profile: profile(), model: 'glm5.1');
      await service.forge(
          message: msg('同一条消息'), profile: profile(), model: 'glm5.1');

      final all = await db.getAllCards();
      expect(all.length, 2);
      expect(all.map((c) => c.title), containsAll(['卡一', '卡二']));
    });
  });

  group('Card 模型', () {
    test('toMap/fromMap 往返一致', () {
      final card = Card(
        id: 'c1',
        sessionId: 's1',
        sourceMessageId: 'm1',
        title: '标题',
        content: '正文',
        tags: 'a,b',
        createdAt: 100,
        updatedAt: 200,
      );
      final parsed = Card.fromMap(card.toMap());
      expect(parsed.id, 'c1');
      expect(parsed.sessionId, 's1');
      expect(parsed.sourceMessageId, 'm1');
      expect(parsed.title, '标题');
      expect(parsed.content, '正文');
      expect(parsed.tags, 'a,b');
      expect(parsed.createdAt, 100);
      expect(parsed.updatedAt, 200);
    });

    test('copyWith：updatedAt 更新，id/createdAt 不变', () {
      final card = Card(
        id: 'c1',
        title: '旧',
        content: '旧',
        createdAt: 100,
        updatedAt: 100,
      );
      final updated = card.copyWith(title: '新', updatedAt: 300);
      expect(updated.id, 'c1');
      expect(updated.createdAt, 100);
      expect(updated.title, '新');
      expect(updated.updatedAt, 300);
    });
  });
}
