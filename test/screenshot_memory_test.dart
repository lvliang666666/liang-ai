import 'dart:async';

import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/memory.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/fts_service.dart';
import 'package:ai_chat_app/services/screenshot_memory_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程 ApiService mock：按调用序号返回脚本事件（同 chat_provider_test 模式）
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();
  int chatStreamCalls = 0;
  final List<List<SseEvent>> scriptsByCall = [];
  final List<Map<String, Object?>> capturedBodies = [];

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
    capturedBodies.add({
      'messages': messages,
      'model': model,
      'effort': effort,
      'temperature': temperature,
    });
    final callIndex = chatStreamCalls;
    chatStreamCalls++;
    if (callIndex < scriptsByCall.length) {
      final c = StreamController<SseEvent>.broadcast();
      scheduleMicrotask(() {
        for (final e in scriptsByCall[callIndex]) {
          c.add(e);
        }
        // 脚本流发完即关闭：ScreenshotMemoryService.describe 的
        // await for 靠流关闭收尾（不像 ChatProvider 靠 SseDone break）
        c.close();
      });
      return c.stream;
    }
    return _controller.stream;
  }

  @override
  void dispose() {}
}

/// F7 截图视觉记忆服务测试：描述生成 / FTS 索引 / 记忆沉淀
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late MockApiService api;
  late ScreenshotMemoryService service;
  final profile = ProviderProfile.builtinCompany();

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    service = ScreenshotMemoryService(api: api, db: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('describe 视觉理解', () {
    test('流式收集完整描述文本', () async {
      api.scriptsByCall.add([
        const SseDeltaContent('一张报销流程'),
        const SseDeltaContent('说明截图'),
      ]);
      final desc = await service.describe(
        imageBase64: 'aGVsbG8=',
        profile: profile,
        model: 'glm5.1',
      );
      expect(desc, '一张报销流程说明截图');
    });

    test('请求走多模态数组 + low 档低温', () async {
      api.scriptsByCall.add([const SseDeltaContent('描述')]);
      await service.describe(
        imageBase64: 'aGVsbG8=',
        profile: profile,
        model: 'glm5.1',
        hint: '报销相关',
      );
      final body = api.capturedBodies.first;
      expect(body['effort'], 'low');
      expect(body['temperature'], 0.2);
      final messages = body['messages'] as List;
      final user = messages.last as Map<String, Object?>;
      expect(user['role'], 'user');
      final content = user['content'] as List;
      expect(content.first, {
        'type': 'text',
        'text': contains('报销相关'),
      });
      expect((content.last as Map)['type'], 'image_url');
      expect(
          ((content.last as Map)['image_url']
              as Map)['url'], // ignore: unnecessary_string_escapes
          contains('data:image/jpeg;base64,aGVsbG8='));
    });

    test('SseError 返回 null（不抛异常）', () async {
      api.scriptsByCall.add([const SseError('服务端错误')]);
      final desc = await service.describe(
        imageBase64: 'aGVsbG8=',
        profile: profile,
        model: 'glm5.1',
      );
      expect(desc, isNull);
    });

    test('空输出返回 null', () async {
      api.scriptsByCall.add([const SseDone()]);
      final desc = await service.describe(
        imageBase64: 'aGVsbG8=',
        profile: profile,
        model: 'glm5.1',
      );
      expect(desc, isNull);
    });

    test('超长描述按 rune 截断到 800', () async {
      api.scriptsByCall.add([
        SseDeltaContent('长' * 900),
      ]);
      final desc = await service.describe(
        imageBase64: 'aGVsbG8=',
        profile: profile,
        model: 'glm5.1',
      );
      expect(desc!.runes.length, ScreenshotMemoryService.maxDescriptionLength);
    });
  });

  group('indexDescription FTS 索引', () {
    test('描述入 messages 表 + FTS 可搜', () async {
      final id = await service.indexDescription(
        description: '报销流程说明：先贴发票再填单子',
        sessionId: 's1',
      );
      // 消息落库（【截图描述】前缀）
      final msgs = await db.getMessages('s1');
      expect(msgs, isNotEmpty);
      expect(msgs.last.id, id);
      expect(msgs.last.content, contains('【截图描述】'));
      expect(msgs.last.content, contains('报销流程'));
      // FTS 可搜（bigram 分词）
      final fts = FtsService(db);
      final hits = await fts.searchMessages('报销流程', sessionId: 's1');
      expect(hits.map((m) => m.id), contains(id));
    });

    test('sessionId 为空串也能索引（空闲态分享）', () async {
      final id = await service.indexDescription(description: '会议纪要截图');
      expect(id, startsWith('shot_'));
      // 空会话 id 不炸（消息落库 sessionId=''）
      final db2 = await db.database;
      final rows = await db2.query('messages',
          where: 'id = ?', whereArgs: [id]);
      expect(rows, isNotEmpty);
      expect(rows.first['session_id'], '');
    });

    test('同毫秒两次索引 id 不撞车（长度位区分）', () async {
      final id1 = await service.indexDescription(description: '短描述');
      final id2 = await service.indexDescription(description: '这是一段长一些的描述文本');
      expect(id1, isNot(id2));
    });
  });

  group('saveToMemory 记忆沉淀', () {
    test('描述入记忆池，tag=截图，来源=截图记忆', () async {
      final memory = await service.saveToMemory('用户常看报销流程文档');
      expect(memory.tag, Memory.screenshotTag);
      expect(memory.sourceAgent, '截图记忆');
      expect(memory.content, '用户常看报销流程文档');
      // 可从记忆池读回
      final all = await db.getAllMemories();
      expect(all.map((m) => m.id), contains(memory.id));
    });

    test('截图记忆参与注入（非归档层）', () async {
      await service.saveToMemory('截图里的项目截止日期是周五');
      final all = await db.getAllMemories();
      expect(all, hasLength(1));
      expect(all.first.isArchived, isFalse);
    });
  });

  group('端到端：描述 → 索引 → 沉淀', () {
    test('分享图片三步链路全通', () async {
      api.scriptsByCall.add([
        const SseDeltaContent('一张讲 Dart Stream 背压处理的教程截图'),
      ]);
      final desc = await service.describe(
        imageBase64: 'aGVsbG8=',
        profile: profile,
        model: 'glm5.1',
      );
      expect(desc, isNotNull);
      final id = await service.indexDescription(
          description: desc!, sessionId: 's1');
      final memory = await service.saveToMemory(desc);

      // 搜索能找回
      final fts = FtsService(db);
      final hits = await fts.searchMessages('背压处理', sessionId: 's1');
      expect(hits.map((m) => m.id), contains(id));
      // 记忆池有沉淀
      final all = await db.getAllMemories();
      expect(all.map((m) => m.id), contains(memory.id));
    });
  });

  group('ChatSession 引用（会话删除级联）', () {
    test('描述消息随会话删除被级联清理', () async {
      await db.insertSession(ChatSession(
          id: 's9', title: '测试', createdAt: 1, updatedAt: 1));
      await service.indexDescription(
          description: '将被删除的描述', sessionId: 's9');
      expect((await db.getMessages('s9')), hasLength(1));
      await db.deleteSession('s9');
      expect((await db.getMessages('s9')), isEmpty);
    });
  });
}
