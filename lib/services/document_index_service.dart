import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/doc_chunk.dart';
import 'database_service.dart';

/// 长文工作台索引服务（F8）：PDF 按页提取 → 超长页拆块 → doc_chunks + FTS
///
/// 设计要点：
/// - **分页提取**（extractText(startPageIndex/endPageIndex)）而非全文一次
///   提取——页码是引用标注的锚点，丢了页码引用就不可验证
/// - **超长页拆块**：单页文本超 [maxChunkLength] 时按段落边界切多块
///   （seq 递增），保证检索单元粒度均匀（太长的块注入浪费 token，
///   太短的块上下文不足）
/// - **幂等**：同会话同文档重挂 REPLACE（replaceDocChunks 先清后插）
/// - **静默降级**：索引失败（扫描版/损坏文件）只 debugPrint，绝不炸
///   聊天主链路——附件本身仍走 extractedText 全量注入的老路径
class DocumentIndexService {
  DocumentIndexService(this._db);

  final DatabaseService _db;

  /// 单块目标长度（字符）：~1000 字符 ≈ 500-700 token，检索注入
  /// top-6 块 ≈ 3-4k token，在水位预算内
  static const int maxChunkLength = 1000;

  /// 索引一个 PDF 文件（fire-and-forget 调用，内部全量容错）
  ///
  /// [bytes] PDF 原始字节；[sourcePath] 沙箱路径（引用 Sheet 打开原文件）。
  /// 返回索引的块数；失败返回 0（不抛异常）。
  Future<int> indexPdf({
    required String sessionId,
    required String docName,
    required Uint8List bytes,
    String sourcePath = '',
  }) async {
    try {
      final chunks = await extractChunks(bytes);
      if (chunks.isEmpty) return 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final docChunks = <DocChunk>[];
      for (final entry in chunks.entries) {
        final page = entry.key;
        for (var seq = 0; seq < entry.value.length; seq++) {
          docChunks.add(DocChunk(
            id: 'doc_${now}_${entry.key}_$seq',
            sessionId: sessionId,
            docName: docName,
            sourcePath: sourcePath,
            page: page,
            seq: seq,
            content: entry.value[seq],
            createdAt: now,
          ));
        }
      }
      await _db.replaceDocChunks(sessionId, docName, docChunks);
      return docChunks.length;
    } catch (e) {
      debugPrint('DocumentIndexService.indexPdf 失败（静默降级）：$e');
      return 0;
    }
  }

  /// PDF 字节 → {页码: [块文本]}（页码 1 起始）
  ///
  /// 公开给测试；解析失败抛异常（indexPdf 捕获转 0）。
  Map<int, List<String>> extractChunks(Uint8List bytes) {
    final doc = PdfDocument(inputBytes: bytes);
    try {
      final extractor = PdfTextExtractor(doc);
      final result = <int, List<String>>{};
      for (var i = 0; i < doc.pages.count; i++) {
        final text =
            extractor.extractText(startPageIndex: i, endPageIndex: i).trim();
        if (text.isEmpty) continue;
        result[i + 1] = _splitChunk(text);
      }
      return result;
    } finally {
      doc.dispose();
    }
  }

  /// 超长文本按段落边界拆块（≤[maxChunkLength]）
  ///
  /// 优先在换行处切（段落边界语义最完整），无换行的超长段落在
  /// 句号/问号/感叹号处切，再不行硬切。
  List<String> _splitChunk(String text) {
    if (text.runes.length <= maxChunkLength) return [text];
    final out = <String>[];
    var rest = text;
    while (rest.runes.length > maxChunkLength) {
      // 在 maxChunkLength 附近找最近的段落/句子边界
      final cut = _findCutPoint(rest);
      out.add(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trim();
    }
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  /// 在 [text] 前 [maxChunkLength] 字符内找最靠后的边界（换行 > 句号）
  int _findCutPoint(String text) {
    final limit = text.runes.length < maxChunkLength
        ? text.runes.length
        : maxChunkLength;
    final head = String.fromCharCodes(text.runes.take(limit));
    final lineBreak = head.lastIndexOf('\n');
    if (lineBreak > limit ~/ 2) return lineBreak + 1;
    for (final ch in ['。', '！', '？', '.', '!', '?']) {
      final idx = head.lastIndexOf(ch);
      if (idx > limit ~/ 2) return idx + 1;
    }
    return limit; // 硬切
  }

  /// 从沙箱文件索引（已保存原文件的场景）
  Future<int> indexPdfFile({
    required String sessionId,
    required String docName,
    required String sourcePath,
  }) async {
    try {
      final bytes = await File(sourcePath).readAsBytes();
      return indexPdf(
          sessionId: sessionId,
          docName: docName,
          bytes: bytes,
          sourcePath: sourcePath);
    } catch (e) {
      debugPrint('DocumentIndexService.indexPdfFile 失败（静默降级）：$e');
      return 0;
    }
  }
}
