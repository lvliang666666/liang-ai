import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/doc_chunk.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/citation_chips.dart';
import 'package:ai_chat_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  /// MessageBubble 依赖 SettingsService（横滑开关）——同 attachment_ui_test 模式
  Future<Widget> wrapBubble(Widget child) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(prefs)),
        ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(settings: SettingsService(prefs)),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  group('parseCitations 标注解析', () {
    test('提取单个标注', () {
      final refs = parseCitations('报销流程见【报销制度.pdf·第3页】所述');
      expect(refs, hasLength(1));
      expect(refs.first.docName, '报销制度.pdf');
      expect(refs.first.page, 3);
      expect(refs.first.label, '报销制度.pdf · 第3页');
    });

    test('多个标注全提取', () {
      final refs = parseCitations(
          '见【A.pdf·第1页】与【B.pdf·第12页】的说明');
      expect(refs, hasLength(2));
      expect(refs[0].docName, 'A.pdf');
      expect(refs[1].page, 12);
    });

    test('同来源去重（保序）', () {
      final refs = parseCitations(
          '【A.pdf·第1页】开头，【A.pdf·第1页】重复，【B.pdf·第2页】');
      expect(refs, hasLength(2));
      expect(refs[0].page, 1);
      expect(refs[1].page, 2);
    });

    test('无标注返回空', () {
      expect(parseCitations('普通回答没有引用'), isEmpty);
      expect(parseCitations(''), isEmpty);
    });

    test('格式不完整不误匹配（缺页码/缺文件名）', () {
      expect(parseCitations('【A.pdf】'), isEmpty);
      expect(parseCitations('【A.pdf·第页】'), isEmpty);
      expect(parseCitations('【·第3页】'), isEmpty);
    });
  });

  group('CitationChips 渲染与交互', () {
    testWidgets('有标注渲染 chips，点击弹原文 Sheet', (tester) async {
      const content = '报销流程见【报销制度.pdf·第3页】说明';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CitationChips(
            content: content,
            resolveChunk: (docName, page) async => DocChunk(
              id: 'c1',
              sessionId: 's1',
              docName: docName,
              page: page,
              content: '员工出差报销流程：先贴发票再填单子',
              createdAt: 1000,
            ),
          ),
        ),
      ));
      expect(find.byType(ActionChip), findsOneWidget);
      expect(find.text('报销制度.pdf · 第3页'), findsOneWidget);

      await tester.tap(find.byType(ActionChip));
      await tester.pumpAndSettle();
      // Sheet 标题 + 原文
      expect(find.text('报销制度.pdf · 第3页'), findsWidgets);
      expect(find.text('员工出差报销流程：先贴发票再填单子'), findsOneWidget);
      // 无 sourcePath：无「打开原文件」按钮
      expect(find.text('打开原文件'), findsNothing);
    });

    testWidgets('有 sourcePath 显示「打开原文件」按钮', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CitationChips(
            content: '见【A.pdf·第2页】',
            resolveChunk: (docName, page) async => DocChunk(
              id: 'c1',
              sessionId: 's1',
              docName: docName,
              page: page,
              content: '片段',
              sourcePath: '/sandbox/A.pdf',
              createdAt: 1000,
            ),
          ),
        ),
      ));
      await tester.tap(find.byType(ActionChip));
      await tester.pumpAndSettle();
      expect(find.text('打开原文件'), findsOneWidget);
    });

    testWidgets('resolveChunk 返回 null：Toast 提示未找到', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CitationChips(
            content: '见【A.pdf·第9页】',
            resolveChunk: (docName, page) async => null,
          ),
        ),
      ));
      await tester.tap(find.byType(ActionChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('未找到该来源的原文片段'), findsOneWidget);
      // Toast 有 hideTimer，走完防 pending timer
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('无标注不渲染任何 chip', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: CitationChips(content: '普通回答'),
      ));
      expect(find.byType(ActionChip), findsNothing);
      expect(find.byType(CitationChips), findsOneWidget);
    });

    testWidgets('resolveChunk 为 null：chips 不可点', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: CitationChips(content: '见【A.pdf·第1页】'),
        ),
      ));
      expect(find.byType(ActionChip), findsOneWidget);
      final chip = tester.widget<ActionChip>(find.byType(ActionChip));
      expect(chip.onPressed, isNull);
    });
  });

  group('MessageBubble 引用 chips 接线', () {
    testWidgets('assistant 消息含标注：气泡下方出现 chips', (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '报销流程见【报销制度.pdf·第3页】。',
        createdAt: 1000,
      );
      await tester.pumpWidget(await wrapBubble(ListView(
        children: [
          MessageBubble(
            message: msg,
            resolveChunk: (docName, page) async => null,
          ),
        ],
      )));
      expect(find.byType(CitationChips), findsOneWidget);
      expect(find.text('报销制度.pdf · 第3页'), findsOneWidget);
    });

    testWidgets('user 消息不渲染引用 chips', (tester) async {
      final msg = ChatMessage(
        id: 'm2',
        sessionId: 's1',
        role: 'user',
        content: '这是用户消息【A.pdf·第1页】',
        createdAt: 1000,
      );
      await tester.pumpWidget(await wrapBubble(ListView(
        children: [MessageBubble(message: msg)],
      )));
      expect(find.byType(CitationChips), findsNothing);
      // 消息本身照常渲染
      expect(find.text('这是用户消息【A.pdf·第1页】'), findsOneWidget);
    });
  });
}
