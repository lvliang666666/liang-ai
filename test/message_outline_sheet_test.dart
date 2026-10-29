import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/widgets/home/message_outline_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// I8 消息大纲测试：目录数据源过滤 / 预览截断 / 时间标签 / 浮层交互
///
/// 浮层交互测试直接 pump [MessageOutlineSheet]（SheetScaffold 内容），
/// 不走 showModalBottomSheet——pop 行为由外层包装函数负责，这里验证
/// onSelect 回调与列表渲染。
void main() {
  ChatMessage user(String id, String content, {int at = 1000}) => ChatMessage(
        id: id,
        sessionId: 's1',
        role: 'user',
        content: content,
        createdAt: at,
      );

  ChatMessage assistant(String id, String content, {int at = 2000}) =>
      ChatMessage(
        id: id,
        sessionId: 's1',
        role: 'assistant',
        content: content,
        createdAt: at,
      );

  ChatMessage toolResult(String id, {String toolCallId = 'c1'}) => ChatMessage(
        id: id,
        sessionId: 's1',
        role: 'tool',
        content: '工具输出',
        toolCallId: toolCallId,
        createdAt: 3000,
      );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('outlineEntries：目录数据源过滤', () {
    test('只保留有内容的 user 消息', () {
      final entries = MessageOutlineSheet.outlineEntries([
        user('u1', '第一个问题'),
        assistant('a1', '回答'),
        toolResult('t1'),
        user('u2', '   '), // 空白内容跳过
        user('u3', '第二个问题'),
      ]);
      expect(entries.map((m) => m.id), ['u1', 'u3']);
    });

    test('空列表返回空', () {
      expect(MessageOutlineSheet.outlineEntries([]), isEmpty);
    });

    test('纯助手会话返回空', () {
      expect(
        MessageOutlineSheet.outlineEntries([assistant('a1', '只有回答')]),
        isEmpty,
      );
    });
  });

  group('previewOf：首行截断', () {
    test('单行短文本原样', () {
      expect(
        MessageOutlineSheet.previewOf(user('u1', '报销流程是什么')),
        '报销流程是什么',
      );
    });

    test('多行文本只取首行', () {
      expect(
        MessageOutlineSheet.previewOf(user('u1', '第一行\n第二行\n第三行')),
        '第一行',
      );
    });

    test('超长截断到上限加省略号', () {
      final long = '长' * 60;
      final preview = MessageOutlineSheet.previewOf(user('u1', long));
      expect(preview.length, kOutlinePreviewLength + 1); // 截断 + …
      expect(preview.endsWith('…'), isTrue);
    });

    test('首尾空白先修剪', () {
      expect(
        MessageOutlineSheet.previewOf(user('u1', '  前后有空格  ')),
        '前后有空格',
      );
    });
  });

  group('timeLabel：微信式时间', () {
    test('今天显示时分', () {
      final now = DateTime.now();
      final ts = DateTime(now.year, now.month, now.day, 9, 5)
          .millisecondsSinceEpoch;
      expect(MessageOutlineSheet.timeLabel(ts), '09:05');
    });

    test('昨天显示「昨天 时分」', () {
      final now = DateTime.now();
      final ts = DateTime(now.year, now.month, now.day - 1, 14, 30)
          .millisecondsSinceEpoch;
      expect(MessageOutlineSheet.timeLabel(ts), '昨天 14:30');
    });

    test('今年更早显示「M月D日 时分」', () {
      final now = DateTime.now();
      final ts = DateTime(now.year, 1, 15, 8, 0).millisecondsSinceEpoch;
      expect(MessageOutlineSheet.timeLabel(ts), '1月15日 08:00');
    });

    test('往年显示完整日期', () {
      final ts =
          DateTime(2020, 12, 3, 10, 20).millisecondsSinceEpoch;
      expect(MessageOutlineSheet.timeLabel(ts), '2020年12月3日 10:20');
    });
  });

  group('MessageOutlineSheet 浮层', () {
    testWidgets('目录条目：序号 + 预览 + 时间，按时间正序', (tester) async {
      await tester.pumpWidget(wrap(MessageOutlineSheet(
        messages: [
          user('u1', '第一个问题', at: 1000),
          assistant('a1', '回答', at: 2000),
          user('u2', '第二个问题', at: 3000),
        ],
        onSelect: (_) {},
      )));
      await tester.pump();

      expect(find.text('消息大纲'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('第一个问题'), findsOneWidget);
      expect(find.text('第二个问题'), findsOneWidget);
      // 助手消息不进目录
      expect(find.text('回答'), findsNothing);
    });

    testWidgets('点条目触发 onSelect 并携带对应消息', (tester) async {
      ChatMessage? picked;
      await tester.pumpWidget(wrap(MessageOutlineSheet(
        messages: [
          user('u1', '第一个问题', at: 1000),
          user('u2', '第二个问题', at: 3000),
        ],
        onSelect: (msg) => picked = msg,
      )));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('outline-u2')));
      await tester.pump();

      expect(picked?.id, 'u2');
    });

    testWidgets('空目录显示「还没有提问」', (tester) async {
      await tester.pumpWidget(wrap(MessageOutlineSheet(
        messages: [assistant('a1', '只有回答')],
        onSelect: (_) {},
      )));
      await tester.pump();

      expect(find.text('还没有提问'), findsOneWidget);
    });

    testWidgets('点关闭键触发 pop', (tester) async {
      var popped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (context) => MessageOutlineSheet(
                    messages: [user('u1', '问题')],
                    onSelect: (_) {},
                  ),
                ).then((_) => popped = true),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      expect(popped, isTrue);
    });
  });

  group('showMessageOutlineSheet 包装', () {
    testWidgets('点条目 pop 并返回该消息', (tester) async {
      ChatMessage? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showMessageOutlineSheet(
                    context,
                    [user('u1', '第一个问题'), user('u2', '第二个问题')],
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('outline-u1')));
      await tester.pumpAndSettle();

      expect(result?.id, 'u1');
    });
  });
}
