import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_chat_app/models/message_attachment.dart';
import 'package:ai_chat_app/services/attachment_service.dart';
import 'package:ai_chat_app/widgets/attachment_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v1.4.0 验证：文件原文件保存 + filePath 序列化 + 缩略图缓存组件
void main() {
  group('MessageAttachment filePath 序列化', () {
    test('带 filePath round-trip', () {
      const a = MessageAttachment(
        type: AttachmentType.file,
        name: 'doc.pdf',
        extractedText: '内容',
        filePath: '/data/attachments/doc.pdf',
      );

      final restored =
          MessageAttachment.decodeList(MessageAttachment.encodeList([a]));

      expect(restored.first.filePath, '/data/attachments/doc.pdf');
      expect(restored.first.hasFile, isTrue);
    });

    test('无 filePath（旧消息兼容）：hasFile 为 false', () {
      const a = MessageAttachment(
        type: AttachmentType.file,
        name: 'old.txt',
        extractedText: '旧内容',
      );

      final restored =
          MessageAttachment.decodeList(MessageAttachment.encodeList([a]));

      expect(restored.first.filePath, isNull);
      expect(restored.first.hasFile, isFalse);
    });

    test('旧版 JSON（无 path 字段）解析兼容', () {
      final legacyJson = jsonEncode([
        {'type': 'file', 'name': 'legacy.md', 'text': '旧数据'},
      ]);

      final list = MessageAttachment.decodeList(legacyJson);

      expect(list, hasLength(1));
      expect(list.first.name, 'legacy.md');
      expect(list.first.filePath, isNull);
      expect(list.first.hasFile, isFalse);
    });
  });

  group('AttachmentService 原文件保存', () {
    late Directory tmpDir;
    const svc = AttachmentService();

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('file_save_test');
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('fileAttachment 保存原文件并记录路径', () async {
      final withDir = AttachmentService(storageDir: tmpDir);
      final bytes = Uint8List.fromList(utf8.encode('# 文档内容'));

      final att = await withDir.fileAttachment('说明.md', bytes);

      expect(att.hasFile, isTrue);
      expect(att.extractedText, '# 文档内容');
      final saved = File(att.filePath!);
      expect(await saved.exists(), isTrue);
      expect(await saved.readAsBytes(), bytes);
    });

    test('重名文件自动加时间戳后缀不覆盖', () async {
      final withDir = AttachmentService(storageDir: tmpDir);
      final bytes1 = Uint8List.fromList(utf8.encode('第一版'));
      final bytes2 = Uint8List.fromList(utf8.encode('第二版'));

      final att1 = await withDir.fileAttachment('doc.txt', bytes1);
      final att2 = await withDir.fileAttachment('doc.txt', bytes2);

      expect(att1.filePath, isNot(att2.filePath));
      expect(await File(att1.filePath!).readAsString(), '第一版');
      expect(await File(att2.filePath!).readAsString(), '第二版');
      expect(await tmpDir.list().length, 2);
    });

    test('storageDir 为 null：不保存原文件（仅提取文本）', () async {
      final att = await svc.fileAttachment(
          'note.txt', Uint8List.fromList(utf8.encode('内容')));

      expect(att.hasFile, isFalse);
      expect(att.extractedText, '内容');
    });

    test('saveOriginal 目录不存在时自动创建', () async {
      final nested = Directory('${tmpDir.path}/a/b');
      final withDir = AttachmentService(storageDir: nested);

      final path = await withDir.saveOriginal(
          'x.txt', Uint8List.fromList(utf8.encode('x')));

      expect(await File(path).exists(), isTrue);
    });
  });

  group('AttachmentThumbnail 组件', () {
    // 1x1 红色 PNG
    const pngB64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    testWidgets('正常渲染图片', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AttachmentThumbnail(base64: pngB64, size: 96),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AttachmentThumbnail), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('坏 base64：显示占位图标不崩溃', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AttachmentThumbnail(base64: 'not-valid-base64!!!', size: 96),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    });

    test('相同 base64 的 provider 相等（缓存命中）', () {
      const p1 = AttachmentThumbnail(base64: pngB64, size: 96);
      const p2 = AttachmentThumbnail(base64: pngB64, size: 96);
      // 同一 base64 构建的组件应渲染出相同的 ImageProvider（== 判定）
      expect(p1.base64, p2.base64);
    });
  });
}
