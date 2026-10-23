import 'dart:async';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/message_attachment.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/models/skill.dart';
import 'package:ai_chat_app/pages/payload_lens_page.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/widgets/token_usage_sheet.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程的 ApiService mock（与 chat_provider_test 同款）
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();

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
    return _controller.stream;
  }

  @override
  void dispose() {}
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late MockApiService api;
  late ChatProvider provider;
  late ChatSession session;

  ChatMessage message(String id, String role, String content,
          {int? prompt, int? completion, int at = 1000}) =>
      ChatMessage(
        id: id,
        sessionId: 's1',
        role: role,
        content: content,
        promptTokens: prompt,
        completionTokens: completion,
        createdAt: at,
      );

  setUpAll(() async {
    // sqflite_ffi 的真实异步 IO 在 widget 测试 fakeAsync 区推不动，
    // DB 初始化也必须发生在 FakeAsync 区外（setUpAll 天然满足）
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
  });

  setUp(() async {
    api = MockApiService();
    session = ChatSession(
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
    );
  });

  tearDown(() async {
    provider.dispose();
    await db.deleteSession('s1');
  });

  /// 预置两轮带 token 的历史并加载（runAsync：真实异步 IO）
  Future<void> seedHistory() async {
    await db.insertMessage(
        message('m1', 'user', '你好', prompt: 100, at: 1000));
    await db.insertMessage(message('m2', 'assistant', '答案',
        prompt: 120, completion: 45, at: 2000));
    await provider.loadMessages();
  }

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('formatTokenCount', () {
    test('千以下原样', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(999), '999');
    });

    test('千以上 k 缩写（去尾 .0）', () {
      expect(formatTokenCount(1000), '1k');
      expect(formatTokenCount(1234), '1.2k');
      expect(formatTokenCount(12345), '12.3k');
      expect(formatTokenCount(32000), '32k');
    });
  });

  group('TokenUsageSheet', () {
    testWidgets('统计卡：累计/输入/输出 汇总正确', (tester) async {
      await tester.runAsync(seedHistory);
      await tester.pumpWidget(wrap(TokenUsageSheet(chat: provider)));
      await tester.pump();

      expect(find.text('Token 用量'), findsOneWidget);
      expect(find.text('累计 token'), findsOneWidget);
      // 统计卡作用域断言（同一数字也会出现在明细行）
      final stats = find.byKey(const ValueKey('token-stats-card'));
      // 100 + 120 + 45 = 265
      expect(find.descendant(of: stats, matching: find.text('265')),
          findsOneWidget);
      // 输入 100 + 120 = 220
      expect(find.descendant(of: stats, matching: find.text('220')),
          findsOneWidget);
      // 输出 45
      expect(find.descendant(of: stats, matching: find.text('45')),
          findsOneWidget);
    });

    testWidgets('水位条：最近一轮 prompt vs 名义上限', (tester) async {
      await tester.runAsync(seedHistory);
      await tester.pumpWidget(wrap(TokenUsageSheet(chat: provider)));
      await tester.pump();

      expect(find.text('上下文水位'), findsOneWidget);
      expect(find.textContaining('120 / 32k'), findsOneWidget);
    });

    testWidgets('明细列表：角色/时间/token，老数据显示 —', (tester) async {
      await tester.runAsync(() async {
        await db.insertMessage(
            message('m1', 'user', '你好', prompt: 100, at: 1000));
        await db.insertMessage(message('m2', 'assistant', '老回复', at: 2000));
        await provider.loadMessages();
      });
      await tester.pumpWidget(wrap(TokenUsageSheet(chat: provider)));
      await tester.pump();

      expect(find.text('消息明细'), findsOneWidget);
      expect(find.text('你'), findsOneWidget);
      expect(find.text('AI'), findsOneWidget);
      // m1 的输入 token（明细行；同数字也在统计卡出现）
      expect(find.text('100'), findsWidgets);
      // 老数据无 token：占位符（m2 的输入/输出两格 + 水位条「暂无数据」
      // 场景外的 m1 无 completion 一格 = 3 处）
      expect(find.text('—'), findsNWidgets(3));
    });

    testWidgets('空会话：0 统计 + 暂无数据', (tester) async {
      await tester.runAsync(provider.loadMessages);
      await tester.pumpWidget(wrap(TokenUsageSheet(chat: provider)));
      await tester.pump();

      final stats = find.descendant(
        of: find.byKey(const ValueKey('token-stats-card')),
        matching: find.text('0'),
      );
      expect(stats, findsNWidgets(3));
      expect(find.text('暂无数据'), findsOneWidget);
    });

    testWidgets('点「查看完整请求 payload」触发回调', (tester) async {
      await tester.runAsync(seedHistory);
      var opened = false;
      await tester.pumpWidget(wrap(TokenUsageSheet(
        chat: provider,
        onOpenPayload: () => opened = true,
      )));
      await tester.pump();

      await tester.tap(find.text('查看完整请求 payload'));
      await tester.pump();

      expect(opened, isTrue);
    });

    testWidgets('流式落库后 Sheet 数字实时更新（ListenableBuilder）',
        (tester) async {
      await tester.runAsync(provider.loadMessages);
      await tester.pumpWidget(wrap(TokenUsageSheet(chat: provider)));
      await tester.pump();

      final stats = find.descendant(
        of: find.byKey(const ValueKey('token-stats-card')),
        matching: find.text('0'),
      );
      expect(stats, findsNWidgets(3));

      // 真实异步区驱动一轮完整对话（DB 写入需要真实事件循环）
      await tester.runAsync(() async {
        await provider.sendMessage('你好');
        api.emit(const SseDeltaContent('答案'));
        api.emit(const SseUsage(promptTokens: 120, completionTokens: 45));
        api.emit(const SseDone());
        // 等落库 + notifyListeners 传播
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      // 120 + 45 = 165（统计卡作用域；120/45 也出现在明细行）
      final statsCard = find.byKey(const ValueKey('token-stats-card'));
      expect(find.descendant(of: statsCard, matching: find.text('165')),
          findsOneWidget);
      expect(find.descendant(of: statsCard, matching: find.text('120')),
          findsOneWidget);
      expect(find.descendant(of: statsCard, matching: find.text('45')),
          findsOneWidget);
    });
  });

  group('PayloadLensPage（F5 上下文透视镜）', () {
    testWidgets('头部元信息：模型/档位/温度/工具数/消息数/估算输入', (tester) async {
      final skill = Skill(id: 'a', name: '架构师', prompt: '你是架构师');
      final withSkill = ChatProvider(
        database: db,
        api: api,
        session: session,
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        skill: skill,
      );
      await tester.runAsync(() async {
        await db.insertMessage(message('m1', 'user', '你好', at: 1000));
        await withSkill.loadMessages();
      });

      await tester.pumpWidget(wrap(PayloadLensPage(chat: withSkill)));
      await tester.pump();

      expect(find.text('下一轮请求将发送'), findsOneWidget);
      expect(find.text('模型 glm5.1'), findsOneWidget);
      expect(find.text('档位 max'), findsOneWidget);
      expect(find.text('温度 0.7'), findsOneWidget);
      expect(find.textContaining('工具'), findsOneWidget);
      // system(Skill prompt) + user = 2 条
      expect(find.text('消息 2 条'), findsOneWidget);
      expect(find.textContaining('估算输入'), findsOneWidget);

      withSkill.dispose();
    });

    testWidgets('消息卡片：system/user 角色徽章 + 内容预览', (tester) async {
      final skill = Skill(id: 'a', name: 'N', prompt: '你是架构师');
      final withSkill = ChatProvider(
        database: db,
        api: api,
        session: session,
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        skill: skill,
      );
      await tester.runAsync(() async {
        await db.insertMessage(message('m1', 'user', '帮我设计登录接口', at: 1000));
        await withSkill.loadMessages();
      });

      await tester.pumpWidget(wrap(PayloadLensPage(chat: withSkill)));
      await tester.pump();

      expect(find.text('system'), findsOneWidget);
      expect(find.text('user'), findsOneWidget);
      expect(find.text('你是架构师'), findsOneWidget);
      expect(find.text('帮我设计登录接口'), findsOneWidget);

      withSkill.dispose();
    });

    testWidgets('点卡片开全文 Sheet：Skill prompt 全文可见', (tester) async {
      final skill = Skill(id: 'a', name: 'N', prompt: '你是架构师，请严谨回答');
      final withSkill = ChatProvider(
        database: db,
        api: api,
        session: session,
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        skill: skill,
      );
      await tester.runAsync(() async {
        await db.insertMessage(message('m1', 'user', '你好', at: 1000));
        await withSkill.loadMessages();
      });

      await tester.pumpWidget(wrap(PayloadLensPage(chat: withSkill)));
      await tester.pump();

      await tester.tap(find.text('你是架构师，请严谨回答'));
      await tester.pumpAndSettle();

      expect(find.text('消息 #1 全文'), findsOneWidget);
      expect(find.text('你是架构师，请严谨回答'), findsNWidgets(2));

      withSkill.dispose();
    });

    testWidgets('多模态消息：图片附件显示 [图片] 占位', (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '看这张图',
        attachments: [
          MessageAttachment(
            type: AttachmentType.image,
            name: 'pic.jpg',
            base64Data: 'aGk=',
          ),
        ],
        createdAt: 1000,
      );
      await tester.runAsync(() async {
        await db.insertMessage(msg);
        await provider.loadMessages();
      });

      await tester.pumpWidget(wrap(PayloadLensPage(chat: provider)));
      await tester.pump();

      expect(find.textContaining('[图片]'), findsOneWidget);
    });
  });
}
