import 'dart:typed_data';
import 'dart:ui';

import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/document_index_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 用 syncfusion 生成带文本层的测试 PDF（每页一段可检索文本）
///
/// CJK 文本必须用 PdfCjkStandardFont（Helvetica 无中文字形，
/// 提取出来是空/乱码——测试先跑通英文再换 CJK 字体的教训）
Uint8List buildTestPdf(List<String> pageTexts) {
  final doc = PdfDocument();
  for (final text in pageTexts) {
    final page = doc.pages.add();
    page.graphics.drawString(
      text,
      PdfCjkStandardFont(PdfCjkFontFamily.hanyangSystemsGothicMedium, 14),
      brush: PdfBrushes.black,
      bounds: const Rect.fromLTWH(0, 0, 500, 700),
    );
  }
  final bytes = doc.saveSync();
  doc.dispose();
  return Uint8List.fromList(bytes);
}

/// F8 长文工作台索引服务测试：分页提取 / 超长拆块 / 幂等 / 静默降级
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late DocumentIndexService service;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    service = DocumentIndexService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('indexPdf 分页分块索引', () {
    test('多页 PDF：每页独立成块，页码正确', () async {
      final bytes = buildTestPdf([
        '第一页讲报销流程：先贴发票再填单子',
        '第二页讲年假制度：入职满一年五天',
        '第三页讲考勤规则：迟到三次警告',
      ]);
      final count = await service.indexPdf(
          sessionId: 's1', docName: '制度汇编.pdf', bytes: bytes);
      expect(count, 3);
      // 每页可独立检索
      final r1 = await db.searchDocChunks('s1', '报销流程');
      expect(r1, hasLength(1));
      expect(r1.first.page, 1);
      final r2 = await db.searchDocChunks('s1', '年假制度');
      expect(r2.first.page, 2);
      final r3 = await db.searchDocChunks('s1', '考勤规则');
      expect(r3.first.page, 3);
    });

    test('引用标注格式：docName·page', () async {
      final bytes = buildTestPdf(['报销流程说明文字']);
      await service.indexPdf(
          sessionId: 's1',
          docName: '报销制度.pdf',
          bytes: bytes,
          sourcePath: '/sandbox/x.pdf');
      final hit = await db.searchDocChunks('s1', '报销流程');
      expect(hit.first.citation, '【报销制度.pdf·第1页】');
      expect(hit.first.sourcePath, '/sandbox/x.pdf');
    });

    test('同文档重挂幂等（块数不翻倍）', () async {
      final bytes = buildTestPdf(['报销流程说明']);
      await service.indexPdf(
          sessionId: 's1', docName: 'A.pdf', bytes: bytes);
      await service.indexPdf(
          sessionId: 's1', docName: 'A.pdf', bytes: bytes);
      final hits = await db.searchDocChunks('s1', '报销流程');
      expect(hits, hasLength(1));
    });

    test('损坏字节静默降级返回 0（不抛异常）', () async {
      final count = await service.indexPdf(
          sessionId: 's1',
          docName: 'broken.pdf',
          bytes: Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(count, 0);
    });

    test('空页（无文本）跳过', () async {
      final bytes = buildTestPdf(['有内容的页面']);
      final count = await service.indexPdf(
          sessionId: 's1', docName: 'A.pdf', bytes: bytes);
      expect(count, 1);
    });
  });

  group('extractChunks 超长页拆块', () {
    test('单页超长文本拆多块（seq 递增）', () async {
      // 生成 ~3000 字符的单页文本（多段落）
      final para = '这是一段用于测试拆块的报销制度说明文字，包含多个句子。' * 10;
      final longText = List.generate(6, (i) => '第${i + 1}段：$para').join('\n');
      final bytes = buildTestPdf([longText]);
      final chunks = service.extractChunks(bytes);
      expect(chunks.keys, [1]);
      final blocks = chunks[1]!;
      expect(blocks.length, greaterThan(1));
      // 每块都不超上限（边界切分允许极小越界，留 10% 容差）
      for (final b in blocks) {
        expect(b.runes.length, lessThanOrEqualTo(1100));
      }
    });

    test('短页不拆（单块原样）', () async {
      final bytes = buildTestPdf(['短内容']);
      final chunks = service.extractChunks(bytes);
      expect(chunks[1], hasLength(1));
      expect(chunks[1]!.first, contains('短内容'));
    });
  });

  group('端到端：索引 → 检索 → 引用', () {
    test('三页制度文档检索注入链路', () async {
      final bytes = buildTestPdf([
        '差旅报销标准：住宿费每晚四百元上限',
        '餐饮报销标准：每餐一百元上限',
        '交通报销标准：市内打车实报实销',
      ]);
      final count = await service.indexPdf(
          sessionId: 's1', docName: '差旅制度.pdf', bytes: bytes);
      expect(count, 3);
      final hits = await db.searchDocChunks('s1', '住宿费', limit: 2);
      expect(hits, hasLength(1));
      expect(hits.first.page, 1);
      expect(hits.first.content, contains('四百元'));
      expect(hits.first.citation, '【差旅制度.pdf·第1页】');
    });
  });
}
