import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/message_attachment.dart';
import 'package:ai_chat_app/services/attachment_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// 阶段 2 验证：多模态 API 消息组装 + 附件文本提取
void main() {
  group('ChatMessage.toApiMessage 多模态组装', () {
    test('纯文本消息：content 为字符串', () {
      final m = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '你好',
        createdAt: 1000,
      );

      final api = m.toApiMessage();
      expect(api['role'], 'user');
      expect(api['content'], '你好');
    });

    test('仅文件附件：提取文本注入正文，content 为字符串', () {
      final m = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '总结一下',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.file, name: 'a.md', extractedText: '# 标题'),
        ],
        createdAt: 1000,
      );

      final api = m.toApiMessage();
      expect(api['content'], '【附件：a.md】\n# 标题\n\n总结一下');
    });

    test('仅图片附件：content 为多模态数组（text + image_url）', () {
      final m = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '看图',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.image, name: 'p.jpg', base64Data: 'QQ=='),
        ],
        createdAt: 1000,
      );

      final api = m.toApiMessage();
      final content = api['content'] as List;
      expect(content, hasLength(2));
      expect(content[0]['type'], 'text');
      expect(content[0]['text'], '看图');
      expect(content[1]['type'], 'image_url');
      expect(content[1]['image_url']['url'], 'data:image/jpeg;base64,QQ==');
    });

    test('图片 + 文件混合：文件注入 text 块，图片追加 image_url', () {
      final m = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '对比一下',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.file, name: 'a.txt', extractedText: 'AAA'),
          MessageAttachment(
              type: AttachmentType.image, name: 'p.jpg', base64Data: 'BB=='),
        ],
        createdAt: 1000,
      );

      final content = m.toApiMessage()['content'] as List;
      expect(content, hasLength(2));
      expect(content[0]['text'], '【附件：a.txt】\nAAA\n\n对比一下');
      expect(content[1]['image_url']['url'], 'data:image/jpeg;base64,BB==');
    });

    test('多张图片按顺序排列', () {
      final m = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '三张图',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.image, name: '1.jpg', base64Data: 'A'),
          MessageAttachment(
              type: AttachmentType.image, name: '2.jpg', base64Data: 'B'),
          MessageAttachment(
              type: AttachmentType.image, name: '3.jpg', base64Data: 'C'),
        ],
        createdAt: 1000,
      );

      final content = m.toApiMessage()['content'] as List;
      expect(content, hasLength(4)); // 1 text + 3 images
      expect(content[1]['image_url']['url'], 'data:image/jpeg;base64,A');
      expect(content[2]['image_url']['url'], 'data:image/jpeg;base64,B');
      expect(content[3]['image_url']['url'], 'data:image/jpeg;base64,C');
    });

    test('assistant 消息不受影响（无附件时）', () {
      final m = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '回复',
        reasoning: '思考',
        createdAt: 1000,
      );

      final api = m.toApiMessage();
      expect(api['role'], 'assistant');
      expect(api['content'], '回复');
      expect(api.containsKey('reasoning'), isFalse);
    });
  });

  group('AttachmentService 文本提取', () {
    const svc = AttachmentService();

    test('txt 文件：UTF-8 直读', () async {
      final bytes = Uint8List.fromList(utf8.encode('你好，世界'));
      final text = await svc.extractText('note.txt', bytes);
      expect(text, '你好，世界');
    });

    test('md 文件：UTF-8 直读', () async {
      final bytes = Uint8List.fromList(utf8.encode('# 标题\n正文'));
      final text = await svc.extractText('readme.md', bytes);
      expect(text, '# 标题\n正文');
    });

    test('非法 UTF-8 字节容错', () async {
      final bytes = Uint8List.fromList([0x61, 0xFF, 0x62]); // a, 非法, b
      final text = await svc.extractText('bad.txt', bytes);
      expect(text, contains('a'));
      expect(text, contains('b'));
    });

    test('pdf 文件：文本层提取', () async {
      // 用 syncfusion 生成一个含中文的 PDF 作为测试输入
      final doc = PdfDocument();
      doc.pages.add().graphics.drawString(
            'PDF 提取测试内容',
            PdfStandardFont(PdfFontFamily.helvetica, 12),
            brush: PdfBrushes.black,
          );
      final pdfBytes = Uint8List.fromList(await doc.save());
      doc.dispose();

      final text = await svc.extractText('doc.pdf', pdfBytes);
      expect(text, isNotEmpty);
    });

    test('扫描版 PDF（无文本层）：抛出可读异常', () async {
      // 生成一个只有图形没有文字的 PDF
      final doc = PdfDocument();
      doc.pages.add().graphics.drawRectangle(
            brush: PdfBrushes.lightBlue,
            bounds: const Rect.fromLTWH(0, 0, 100, 100),
          );
      final pdfBytes = Uint8List.fromList(await doc.save());
      doc.dispose();

      expect(
        () => svc.extractText('scan.pdf', pdfBytes),
        throwsA(isA<AttachmentException>()
            .having((e) => e.message, 'message', contains('文本层'))),
      );
    });

    test('损坏的 PDF：抛出解析失败异常', () async {
      final bytes = Uint8List.fromList(utf8.encode('this is not a pdf'));
      expect(
        () => svc.extractText('broken.pdf', bytes),
        throwsA(isA<AttachmentException>()
            .having((e) => e.message, 'message', contains('解析失败'))),
      );
    });

    test('fileAttachment：文件字节 → 附件对象', () async {
      final bytes = Uint8List.fromList(utf8.encode('文件内容'));
      final att = await svc.fileAttachment('doc.txt', bytes);

      expect(att.isFile, isTrue);
      expect(att.name, 'doc.txt');
      expect(att.extractedText, '文件内容');
      expect(att.base64Data, isNull);
    });

    test('imageAttachment：字节 → base64 图片附件', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final att = svc.imageAttachment('photo.jpg', bytes);

      expect(att.isImage, isTrue);
      expect(att.name, 'photo.jpg');
      expect(att.base64Data, base64Encode(bytes));
      expect(att.extractedText, isNull);
    });
  });
}
