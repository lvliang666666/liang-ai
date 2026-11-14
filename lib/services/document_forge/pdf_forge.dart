import 'dart:io';
import 'dart:ui' show Rect;

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// PDF 生成器（syncfusion_flutter_pdf，零新依赖）
///
/// 中文免打包 TTF：PdfCjkStandardFont + sinoTypeSongLight（华文宋体）
/// 是包内置 CJK 字体，无需 assets 字体文件。布局策略：按行写入，
/// 每页满行自动换页；空行保留（段落分隔感）。
class PdfForge {
  /// 生成 PDF 到 [path]，返回实际写入的文件
  ///
  /// [title] 作为首行标题（加粗放大）；[lines] 为正文行。
  Future<File> write({
    required String path,
    required String title,
    required List<String> lines,
  }) async {
    final doc = PdfDocument();
    try {
      final font = PdfCjkStandardFont(
        PdfCjkFontFamily.sinoTypeSongLight,
        12,
      );
      final titleFont = PdfCjkStandardFont(
        PdfCjkFontFamily.sinoTypeSongLight,
        20,
        style: PdfFontStyle.bold,
      );
      PdfPage page = doc.pages.add();
      const margin = 50.0;
      var y = page.getClientSize().height - margin;
      const lineHeight = 20.0;

      void drawLine(String text, PdfFont f, {PdfPen? pen}) {
        // 换页：当前行放不下就开新页
        if (y - lineHeight < margin) {
          page = doc.pages.add();
          y = page.getClientSize().height - margin;
        }
        page.graphics.drawString(
          text,
          f,
          brush: PdfBrushes.black,
          pen: pen,
          bounds: Rect.fromLTWH(margin, y - lineHeight,
              page.getClientSize().width - margin * 2, lineHeight),
        );
        y -= lineHeight;
      }

      drawLine(title, titleFont);
      y -= 10; // 标题与正文间距
      for (final line in lines) {
        drawLine(line.isEmpty ? ' ' : line, font);
      }
      final bytes = await doc.save();
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } finally {
      doc.dispose();
    }
  }
}
