import 'dart:io';

import 'package:ai_chat_app/models/card.dart' as card_model;
import 'package:ai_chat_app/pages/card_detail_page.dart';
import 'package:ai_chat_app/services/card_image_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// W2 卡片详情页 widget 测试：真卡片样式 + 图片分享
///
/// 触发链路：卡片库点卡片 → 整页卡片视图（卡头/正文/卡脚）→
/// AppBar「分享卡片」→ RepaintBoundary 渲染 PNG → 系统分享面板。
/// path_provider / share_plus 走 TestDefaultBinaryMessenger mock
///（widget 测试无系统分享面板与真实临时目录）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  card_model.Card card({
    String title = 'Dart Stream 背压',
    String content = 'Stream 有缓冲区上限，消费慢时暂停生产端。',
    String? tags = '编程,Dart',
    int updatedAt = 1730000000000,
  }) =>
      card_model.Card(
        id: 'c1',
        sessionId: 's1',
        sourceMessageId: 'm1',
        title: title,
        content: content,
        tags: tags,
        createdAt: 1000,
        updatedAt: updatedAt,
      );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('CardDetailPage 卡片视觉', () {
    testWidgets('真卡片结构：品牌行 + 标题 + 标签 + 正文 + 沉淀时间',
        (tester) async {
      await tester.pumpWidget(wrap(CardDetailPage(card: card())));

      expect(find.text('Liang AI 知识卡片'), findsOneWidget);
      expect(find.text('Dart Stream 背压'), findsOneWidget);
      expect(find.text('编程'), findsOneWidget);
      expect(find.text('Dart'), findsOneWidget);
      expect(find.textContaining('缓冲区上限'), findsOneWidget);
      expect(find.textContaining('沉淀于'), findsOneWidget);
    });

    testWidgets('Markdown 代码块渲染：代码内容 + 语言标签 + 复制按钮',
        (tester) async {
      const content = '解题步骤：\n1. 读入 n\n\n```python\nprint(sum(range(10)))\n```';
      await tester.pumpWidget(
          wrap(CardDetailPage(card: card(content: content, tags: null))));

      // 代码块高亮组件（与聊天页同款 CodeBlockWidget）
      expect(find.text('python'), findsOneWidget);
      // HighlightView 内部是 RichText——findRichText: true 才搜得到
      expect(find.textContaining('print(sum', findRichText: true),
          findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      // Markdown 列表结构：有序列表项渲染
      expect(find.textContaining('读入 n'), findsOneWidget);
    });

    testWidgets('无标签卡片：标签区不渲染', (tester) async {
      await tester.pumpWidget(wrap(CardDetailPage(card: card(tags: null))));
      expect(find.text('编程'), findsNothing);
      expect(find.text('Dart'), findsNothing);
    });

    testWidgets('空正文卡片：显示占位文案', (tester) async {
      await tester.pumpWidget(wrap(CardDetailPage(card: card(content: ''))));
      expect(find.text('（无正文）'), findsOneWidget);
    });

    testWidgets('分享按钮在场', (tester) async {
      await tester.pumpWidget(wrap(CardDetailPage(card: card())));
      expect(find.byTooltip('分享卡片'), findsOneWidget);
    });
  });

  group('CardImageService', () {
    testWidgets('renderFromBoundary：RepaintBoundary 渲染出非空 PNG 字节',
        (tester) async {
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(wrap(
        RepaintBoundary(
          key: boundaryKey,
          child: const Text('hello card'),
        ),
      ));

      // toImage 是真实异步光栅化——fakeAsync 区推不动，必须 runAsync。
      // pumpWidget 已完成布局与绘制，无需再等 endOfFrame（等不到下一帧
      // 会挂死）。
      final bytes = await tester.runAsync(
          () => CardImageService.renderFromBoundary(boundaryKey));

      expect(bytes, isNotNull);
      expect(bytes!.lengthInBytes, greaterThan(100));
      // PNG 魔数：89 50 4E 47
      expect(bytes[0], 0x89);
      expect(bytes[1], 0x50);
      expect(bytes[2], 0x4E);
      expect(bytes[3], 0x47);
    });

    testWidgets('renderFromBoundary：未挂载的 key 返回 null 不抛异常',
        (tester) async {
      final bytes = await CardImageService.renderFromBoundary(GlobalKey());
      expect(bytes, isNull);
    });

    testWidgets('shareCardImage 全链：渲染 PNG → 写盘 → mock 分享面板收到图片',
        (tester) async {
      // mock path_provider：临时目录指到测试沙箱
      final tempDir = await tester.runAsync(() => Directory.systemTemp
          .createTemp('card_image_test')
          .then((d) => d.path));
      // Windows 下异步写盘的句柄释放有延迟，删除失败直接吞掉（系统临时
      // 目录，泄漏无害）
      addTearDown(() {
        try {
          Directory(tempDir!).deleteSync(recursive: true);
        } catch (_) {}
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getTemporaryDirectory'
            ? tempDir
            : null,
      );
      // mock share_plus：记录收到的 mimeTypes，返回「已分享」
      final sharedMimeTypes = <List<dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        (call) async {
          if (call.method == 'share') {
            final args = call.arguments as Map<Object?, Object?>?;
            sharedMimeTypes.add((args?['mimeTypes'] as List?) ?? const []);
            return 'dev.fluttercommunity.plus/share/result/accepted';
          }
          return null;
        },
      );
      addTearDown(() {
        final messenger = TestDefaultBinaryMessengerBinding.instance;
        messenger.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
        messenger.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/share'), null);
      });

      // 干净宿主树：只挂测试自己的 RepaintBoundary（详情页整页树会让
      // fakeAsync 区的 tap 驱动链路挂死——文件 IO 段无法在 fakeAsync
      // 区推进，见下方 tap 接线测试的注释）
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(wrap(
        RepaintBoundary(
          key: boundaryKey,
          child: Container(
            width: 200,
            height: 120,
            color: Colors.amber,
            alignment: Alignment.center,
            child: const Text('hello card'),
          ),
        ),
      ));

      // 整链真实异步（光栅化 + 文件 IO + share 通道），必须整体在
      // runAsync 里推进
      final result = await tester.runAsync(
          () => CardImageService.shareCardImage(boundaryKey, card()));

      // 分享成功（渲染 + 写盘 + share 调用全通）
      expect(result, isTrue);
      // 分享面板收到图片类型载荷
      expect(sharedMimeTypes, hasLength(1));
      expect(sharedMimeTypes.single, contains('image/png'));
      // 临时文件确实写出来了
      final file = File('$tempDir/${CardImageService.fileNameBase}.png');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(100));
    });

    testWidgets('详情页分享接线：点分享按钮 → 进入分享中态（spinner 替换图标）',
        (tester) async {
      // 不 mock path_provider：tap 驱动的链路在 fakeAsync 区推进不到
      // 文件 IO 段（真实异步挂死，测试环境已知限制），spinner 永远不会
      // 消失——全链成功路径已由上方 shareCardImage 直调测试覆盖，这里
      // 只验证「点按钮 → _sharing=true」的接线。
      await tester.pumpWidget(wrap(CardDetailPage(card: card())));
      await tester.tap(find.byTooltip('分享卡片'));
      await tester.pump();

      // 分享中态：按钮变 spinner，原图标不在场
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.ios_share), findsNothing,
          reason: '分享中 IconButton 换成了 spinner，图标不在场');
    });
  });
}
