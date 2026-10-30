import 'dart:async';

import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/doc_chunk.dart';
import 'package:ai_chat_app/models/message_attachment.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/document_index_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程 ApiService mock（同 chat_provider_test 模式，捕获 messages）
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();
  int chatStreamCalls = 0;
  List<Map<String, Object?>>? lastMessages;

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
    lastMessages = messages;
    return _controller.stream;
  }

  @override
  void dispose() {}
}

/// F8 长文工作台接线测试：检索注入 + 引用标注指令
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late MockApiService api;
  late ChatProvider provider;
  late DocumentIndexService index;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    index = DocumentIndexService(db);
    final session = ChatSession(
        id: 's1', title: '新对话', createdAt: 1000, updatedAt: 1000);
    await db.insertSession(session);
    provider = ChatProvider(
      database: db,
      api: api,
      session: session,
      profile: ProviderProfile.builtinCompany(),
      model: 'glm5.1',
      documentIndex: index,
    );
  });

  tearDown(() async {
    provider.dispose();
    await db.close();
  });

  /// 索引一份两页测试文档（直接写块，绕过 PDF 解析）
  Future<void> seedDoc() async {
    await db.replaceDocChunks('s1', '报销制度.pdf', [
      DocChunk(
          id: 'c1',
          sessionId: 's1',
          docName: '报销制度.pdf',
          page: 1,
          content: '员工出差报销流程：先贴发票再填单子，三个工作日到账',
          createdAt: 1000),
      DocChunk(
          id: 'c2',
          sessionId: 's1',
          docName: '报销制度.pdf',
          page: 2,
          content: '年假制度：入职满一年享有五天带薪年假',
          createdAt: 1000),
    ]);
  }

  group('检索注入', () {
    /// sendMessage 后等 loop 建立订阅（真实 DB IO 在 sendMessage 内有
    /// 事件循环跳转——emit 必须等 chatStreamCalls 就绪，否则事件丢失）
    Future<void> sendAndWait(String text) async {
      final sent = provider.sendMessage(text);
      await Future.delayed(Duration.zero);
      // 轮询等订阅就绪（最多 ~1s）
      for (var i = 0; i < 100 && api.chatStreamCalls == 0; i++) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      api.emit(const SseDeltaContent('回答'));
      api.emit(const SseDone());
      await sent;
      await Future.delayed(Duration.zero);
    }

    test('提问命中文档：payload 含【文档资料】块 + 引用指令', () async {
      await seedDoc();
      await sendAndWait('报销流程是怎样的');
      final messages = api.lastMessages!;
      final docMsgs = messages
          .where((m) => (m['content'] as String).contains('【文档资料】'))
          .toList();
      expect(docMsgs, hasLength(1));
      final text = docMsgs.first['content'] as String;
      expect(text, contains('报销流程'));
      expect(text, contains('【报销制度.pdf·第1页】'));
      expect(text, contains('标注来源'));
      // 年假块不相关不注入
      expect(text, isNot(contains('年假')));
    });

    test('无文档会话：payload 无【文档资料】块', () async {
      await sendAndWait('随便聊聊');
      final messages = api.lastMessages!;
      expect(messages
          .where((m) => (m['content'] as String).contains('【文档资料】')),
          isEmpty);
    });

    test('提问不命中任何块：不注入', () async {
      await seedDoc();
      await sendAndWait('今天天气怎么样');
      final messages = api.lastMessages!;
      expect(messages
          .where((m) => (m['content'] as String).contains('【文档资料】')),
          isEmpty);
    });

    test('注入位置：system 消息在历史之前', () async {
      await seedDoc();
      await sendAndWait('报销流程');
      final messages = api.lastMessages!;
      final docIdx = messages
          .indexWhere((m) => (m['content'] as String).contains('【文档资料】'));
      final userIdx =
          messages.indexWhere((m) => m['role'] == 'user');
      expect(docIdx, greaterThanOrEqualTo(0));
      expect(docIdx, lessThan(userIdx));
    });
  });

  group('buildDocContextText 格式契约', () {
    test('含引用标注 + 引用指令 + 片段原文', () {
      final text = ChatProvider.buildDocContextText([
        DocChunk(
            id: 'c1',
            sessionId: 's1',
            docName: 'A.pdf',
            page: 3,
            content: '片段内容',
            createdAt: 1000),
      ]);
      expect(text, contains('【文档资料】'));
      expect(text, contains('【A.pdf·第3页】'));
      expect(text, contains('片段内容'));
      expect(text, contains('不要编造页码'));
    });
  });

  group('addAttachment PDF 索引触发', () {
    test('非 PDF 文件不触发索引（无路径也不炸）', () {
      // 无 documentIndex 的 provider（null）也不炸——构造一个验证
      final session = ChatSession(
          id: 's2', title: '新对话', createdAt: 1000, updatedAt: 1000);
      // s2 会话未插入 DB 也没关系——addAttachment 不查库
      final p2 = ChatProvider(
        database: db,
        api: api,
        session: session,
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
      expect(
          p2.addAttachment(const MessageAttachment(
              type: AttachmentType.file, name: 'a.txt')),
          isTrue);
      p2.dispose();
    });
  });
}
