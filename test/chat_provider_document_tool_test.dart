import 'dart:async';
import 'dart:io';

import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/services/tools/create_document_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程 ApiService mock（与 chat_provider_test 同款最小实现）
class MockApiService implements ApiService {
  final _controller = StreamController<SseEvent>.broadcast();

  /// 最近一次请求的 messages（附件消息进 API 历史断言用）
  List<Map<String, Object?>>? lastMessages;

  void emit(SseEvent event) => _controller.add(event);

  @override
  Stream<SseEvent> chatStream({
    required profile,
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required cancelToken,
    double temperature = 0.7,
    List<Map<String, Object?>>? tools,
  }) {
    lastMessages = messages;
    return _controller.stream;
  }

  @override
  void dispose() {}
}

/// Document Forge 会话链路测试：create_document 工具轮 → [FILE:] 标记
/// → assistant 附件消息落库上屏（Fake 模式：临时目录注入，无裸 IO）
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late MockApiService api;
  late ChatProvider provider;
  late Directory tmpDir;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('doc_tool_chat_test');
    final inMemory = await openTestDb();
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
      // 注入带临时目录的 create_document（其余内置工具照常进目录）
      toolCatalog: [CreateDocumentTool(outputDir: tmpDir)],
    );
  });

  tearDown(() async {
    provider.dispose();
    await db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  /// 轮询等待条件成立（真实文件 IO + DB 落库跨多拍事件循环，
  /// 固定延时在本机不稳定——50ms 时而不够）
  Future<void> waitUntil(bool Function() cond) async {
    for (var i = 0; i < 100; i++) {
      if (cond()) return;
      await Future.delayed(const Duration(milliseconds: 20));
    }
    fail('waitUntil 超时（2s）：条件未成立');
  }

  group('create_document 会话链路', () {
    test('工具轮后 assistant 附件消息落库（filePath 指向生成文件）',
        () async {
      await provider.loadMessages();
      await provider.sendMessage('帮我生成 PDF');
      // 模型发起 create_document 调用（argumentsJson 走真实解析）
      final args =
          '{"format":"pdf","title":"测试文档","content":"第一行\\n第二行"}';
      api.emit(SseToolCallDelta(
          index: 0, id: 'c1', name: 'create_document', argumentsFragment: args));
      api.emit(const SseToolCallsFinished());
      // 等附件消息出现（工具轮 + FORGE 分支跑完）
      await waitUntil(() =>
          provider.messages.any((m) => m.attachments.isNotEmpty));
      // 工具执行完，模型继续给最终回答
      api.emit(const SseDeltaContent('文档已生成，请查收'));
      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);

      // 落库验证：user + assistant(tool_calls) + tool + 附件 assistant + 最终 assistant
      final msgs = await db.getMessages('s1');
      final attachmentMsgs = msgs
          .where((m) =>
              m.role == 'assistant' && m.attachments.isNotEmpty)
          .toList();
      expect(attachmentMsgs.length, 1,
          reason: '工具结果带 [FILE:] 标记应追加一条 assistant 附件消息');
      final att = attachmentMsgs.single.attachments.single;
      expect(att.isFile, isTrue);
      expect(att.name, endsWith('.pdf'));
      expect(att.filePath, isNotNull);
      expect(File(att.filePath!).existsSync(), isTrue,
          reason: '附件指向的文件应真实存在');
      expect(attachmentMsgs.single.content, contains('已生成文档'));
    });

    test('同一文件不重复发附件消息（模型重试去重）', () async {
      await provider.loadMessages();
      await provider.sendMessage('生成 CSV');
      final args = '{"format":"csv","title":"表","content":"a,b"}';
      // 第一轮工具调用
      api.emit(SseToolCallDelta(
          index: 0, id: 'c1', name: 'create_document', argumentsFragment: args));
      api.emit(const SseToolCallsFinished());
      await waitUntil(() =>
          provider.messages.any((m) => m.attachments.isNotEmpty));
      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);

      final count1 = (await db.getMessages('s1'))
          .where((m) => m.attachments.isNotEmpty)
          .length;
      expect(count1, 1);

      // 第二轮同参数调用（模拟模型重试）——文件名相同（同秒覆盖同文件）
      await provider.sendMessage('再生成一次');
      api.emit(SseToolCallDelta(
          index: 0, id: 'c2', name: 'create_document', argumentsFragment: args));
      api.emit(const SseToolCallsFinished());
      // 等第二轮 FORGE 分支跑完（去重不发新附件消息，attachments 数不变
      // ——用短暂轮询等 tool 消息数增加来确认工具轮完成）
      final toolMsgCount = provider.messages.where((m) => m.role == 'tool').length;
      await waitUntil(() =>
          provider.messages.where((m) => m.role == 'tool').length >
          toolMsgCount);
      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);

      final attachmentMsgs = (await db.getMessages('s1'))
          .where((m) => m.attachments.isNotEmpty)
          .toList();
      expect(attachmentMsgs.length, 1,
          reason: '同路径文件去重：不重复发附件卡片');
    });

    test('无 [FILE:] 标记的工具结果不追加附件消息', () async {
      await provider.loadMessages();
      await provider.sendMessage('查个时间');
      // 直接发最终回答（无工具调用）
      api.emit(const SseDeltaContent('现在是下午三点'));
      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);

      final attachmentMsgs = (await db.getMessages('s1'))
          .where((m) => m.attachments.isNotEmpty)
          .toList();
      expect(attachmentMsgs, isEmpty);
    });

    test('附件消息进 API 历史（content 非空，网关兼容）', () async {
      await provider.loadMessages();
      await provider.sendMessage('生成文档');
      final args = '{"format":"pdf","title":"t","content":"x"}';
      api.emit(SseToolCallDelta(
          index: 0, id: 'c1', name: 'create_document', argumentsFragment: args));
      api.emit(const SseToolCallsFinished());
      // 等工具轮真正完成（附件消息进 provider.messages）
      await waitUntil(() =>
          provider.messages.any((m) => m.attachments.isNotEmpty));
      api.emit(const SseDone());
      await waitUntil(() => provider.status == ChatStatus.idle);

      // 下一轮请求：附件消息以 assistant 角色 + 非空 content 进历史
      await provider.sendMessage('谢谢');
      await waitUntil(() => api.lastMessages != null &&
          api.lastMessages!.any((m) =>
              m['role'] == 'assistant' &&
              (m['content'] as String).contains('已生成文档')));
      final sent = api.lastMessages!;
      final attMsgs = sent
          .where((m) =>
              m['role'] == 'assistant' &&
              (m['content'] as String).contains('已生成文档'))
          .toList();
      expect(attMsgs.length, 1);
      expect((attMsgs.single['content'] as String).isNotEmpty, isTrue);
    });
  });
}
