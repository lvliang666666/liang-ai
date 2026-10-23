import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/message_attachment.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'chat_provider_test.dart' show MockApiService;
import 'helpers/test_db.dart';

/// 阶段 3 验证：ChatProvider 附件队列 + 气泡附件展示
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ChatProvider 附件队列', () {
    late DatabaseService db;
    late MockApiService api;
    late ChatProvider provider;

    setUp(() async {
      final inMemory = await openTestDb();
      db = DatabaseService.instance;
      await db.initForTest(inMemory);
      api = MockApiService();
      provider = ChatProvider(
        database: db,
        api: api,
        session: ChatSession(
            id: 's1', title: '新对话', createdAt: 1, updatedAt: 1),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
      );
    });

    tearDown(() async {
      provider.dispose();
      await db.close();
    });

    test('添加图片附件：3 张后拒绝第 4 张', () {
      expect(provider.addAttachment(const MessageAttachment(
          type: AttachmentType.image, name: '1.jpg', base64Data: 'A')), isTrue);
      expect(provider.addAttachment(const MessageAttachment(
          type: AttachmentType.image, name: '2.jpg', base64Data: 'B')), isTrue);
      expect(provider.addAttachment(const MessageAttachment(
          type: AttachmentType.image, name: '3.jpg', base64Data: 'C')), isTrue);
      expect(provider.addAttachment(const MessageAttachment(
          type: AttachmentType.image, name: '4.jpg', base64Data: 'D')), isFalse);
      expect(provider.pendingAttachments, hasLength(3));
    });

    test('添加文件附件：3 个后拒绝第 4 个', () {
      for (var i = 1; i <= 3; i++) {
        expect(provider.addAttachment(MessageAttachment(
            type: AttachmentType.file,
            name: 'f$i.txt',
            extractedText: 'x')), isTrue);
      }
      expect(provider.addAttachment(MessageAttachment(
          type: AttachmentType.file, name: 'f4.txt', extractedText: 'x')),
          isFalse);
    });

    test('图片和文件上限独立计算', () {
      for (var i = 1; i <= 3; i++) {
        provider.addAttachment(MessageAttachment(
            type: AttachmentType.image, name: 'i$i.jpg', base64Data: 'A'));
      }
      // 图片已满，但文件仍可加
      expect(provider.addAttachment(const MessageAttachment(
          type: AttachmentType.file, name: 'a.txt', extractedText: 't')), isTrue);
      expect(provider.pendingAttachments, hasLength(4));
    });

    test('移除附件', () {
      final a = const MessageAttachment(
          type: AttachmentType.image, name: '1.jpg', base64Data: 'A');
      provider.addAttachment(a);
      provider.addAttachment(const MessageAttachment(
          type: AttachmentType.image, name: '2.jpg', base64Data: 'B'));
      provider.removeAttachment(a);
      expect(provider.pendingAttachments, hasLength(1));
      expect(provider.pendingAttachments.first.name, '2.jpg');
    });

    test('发送后附件随消息落库并清空队列', () async {
      provider.addAttachment(const MessageAttachment(
          type: AttachmentType.image, name: 'p.jpg', base64Data: 'QQ=='));
      provider.addAttachment(const MessageAttachment(
          type: AttachmentType.file, name: 'a.txt', extractedText: '内容'));

      api.emit(const SseDone());
      await provider.sendMessage('看这些');

      expect(provider.pendingAttachments, isEmpty);
      expect(provider.messages, hasLength(1));
      expect(provider.messages.first.attachments, hasLength(2));
      expect(provider.messages.first.attachments.first.base64Data, 'QQ==');

      // 落库验证
      final stored = await db.getMessages('s1');
      expect(stored, hasLength(1));
      expect(stored.first.attachments, hasLength(2));
    });

    test('仅附件无文字也可发送', () async {
      provider.addAttachment(const MessageAttachment(
          type: AttachmentType.image, name: 'p.jpg', base64Data: 'QQ=='));

      api.emit(const SseDone());
      await provider.sendMessage('');

      expect(provider.messages, hasLength(1));
      expect(provider.messages.first.content, isEmpty);
      expect(provider.messages.first.attachments, hasLength(1));
    });

    test('仅附件时自动标题取附件名', () async {
      provider.addAttachment(const MessageAttachment(
          type: AttachmentType.image, name: '旅行照片.jpg', base64Data: 'QQ=='));

      api.emit(const SseDone());
      await provider.sendMessage('');

      expect(provider.session.title, '旅行照片.jpg');
    });
  });

  group('MessageBubble 附件展示', () {
    late SharedPreferences prefs;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Widget wrap(Widget child) => MultiProvider(
          providers: [
            Provider<SettingsService>.value(
                value: SettingsService(prefs)),
            ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider(settings: SettingsService(prefs)),
            ),
          ],
          child: MaterialApp(home: Scaffold(body: child)),
        );

    testWidgets('用户消息带图片：渲染缩略图', (tester) async {
      // 1x1 红色 PNG
      const pngB64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '看图',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.image, name: 'p.png', base64Data: pngB64),
        ],
        createdAt: 1000,
      );

      await tester.pumpWidget(wrap(MessageBubble(message: msg)));
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('看图'), findsOneWidget);
    });

    testWidgets('用户消息带文件：渲染文件卡片', (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '总结',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.file, name: '报告.md', extractedText: 'x'),
        ],
        createdAt: 1000,
      );

      await tester.pumpWidget(wrap(MessageBubble(message: msg)));
      await tester.pump();

      expect(find.text('报告.md'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('纯文本消息：不渲染附件区', (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '你好',
        createdAt: 1000,
      );

      await tester.pumpWidget(wrap(MessageBubble(message: msg)));
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(find.text('你好'), findsOneWidget);
    });
  });
}
