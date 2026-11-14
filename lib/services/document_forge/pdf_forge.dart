import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/material.dart' show Color;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'document_palette.dart';

/// PDF 生成器（syncfusion_flutter_pdf，零新依赖）
///
/// 中文免打包 TTF：PdfCjkStandardFont + sinoTypeSongLight（华文宋体）
/// 是包内置 CJK 字体，无需 assets 字体文件。
///
/// 排版美化（Document Palette 主题色快照）：
/// - 标题居中 + 强调色 + 底部装饰线
/// - 正文 1.5 倍行距，空行分段
/// - 竖线行渲染为真表格（表头底色 + 斑马纹 + 边框）
/// - `- `/`* `/`1. ` 开头行渲染为列表（项目符号/编号）
/// - 页脚页码（第 N 页 / 共 M 页，收尾时回填总页数）
class PdfForge {
  /// 生成 PDF 到 [path]，返回实际写入的文件
  ///
  /// [title] 作为首行标题；[lines] 为正文行（竖线行=表格行，
  /// 列表前缀行=列表项，空行=段落分隔）。
  Future<File> write({
    required String path,
    required String title,
    required List<String> lines,
    DocumentPalette? palette,
  }) async {
    final pal = palette ??
        DocumentPalette(accent: const Color(0xFF4F8CFF));
    final doc = PdfDocument();
    try {
      final bodyFont = PdfCjkStandardFont(
        PdfCjkFontFamily.sinoTypeSongLight,
        11,
      );
      final titleFont = PdfCjkStandardFont(
        PdfCjkFontFamily.sinoTypeSongLight,
        22,
        style: PdfFontStyle.bold,
      );
      final headingFont = PdfCjkStandardFont(
        PdfCjkFontFamily.sinoTypeSongLight,
        14,
        style: PdfFontStyle.bold,
      );
      final tableHeaderFont = PdfCjkStandardFont(
        PdfCjkFontFamily.sinoTypeSongLight,
        10.5,
        style: PdfFontStyle.bold,
      );
      final footerFont = PdfCjkStandardFont(
        PdfCjkFontFamily.sinoTypeSongLight,
        9,
      );

      final accentDeep = PdfColor(
        (pal.accentDeep.r * 255).round(),
        (pal.accentDeep.g * 255).round(),
        (pal.accentDeep.b * 255).round(),
      );
      final headerBg = PdfColor(
        (pal.headerBg.r * 255).round(),
        (pal.headerBg.g * 255).round(),
        (pal.headerBg.b * 255).round(),
      );
      final zebraBg = PdfColor(
        (pal.zebraBg.r * 255).round(),
        (pal.zebraBg.g * 255).round(),
        (pal.zebraBg.b * 255).round(),
      );
      final borderColor = PdfColor(
        (pal.border.r * 255).round(),
        (pal.border.g * 255).round(),
        (pal.border.b * 255).round(),
      );

      PdfPage page = doc.pages.add();
      const margin = 54.0;
      var y = page.getClientSize().height - margin;
      final pageWidth = page.getClientSize().width;
      const lineHeight = 19.0;

      void newPage() {
        page = doc.pages.add();
        y = page.getClientSize().height - margin;
      }

      void drawText(String text, PdfFont f,
          {PdfColor? color,
          double left = margin,
          double? width,
          PdfTextAlignment? align}) {
        if (y - lineHeight < margin + 24) newPage(); // 底部留页脚空间
        page.graphics.drawString(
          text,
          f,
          brush: PdfSolidBrush(color ?? PdfColor(0x1F, 0x23, 0x29)),
          bounds: Rect.fromLTWH(left, y - lineHeight,
              width ?? pageWidth - margin * 2, lineHeight),
          format: align == null
              ? null
              : PdfStringFormat(alignment: align),
        );
        y -= lineHeight;
      }

      // ── 标题：居中 + 强调色 + 装饰线 ──
      drawText(title, titleFont, color: accentDeep,
          align: PdfTextAlignment.center);
      y -= 6;
      page.graphics.drawLine(
        PdfPen(PdfColor(
          (pal.accent.r * 255).round(),
          (pal.accent.g * 255).round(),
          (pal.accent.b * 255).round(),
        ), width: 2),
        Offset(pageWidth * 0.3, y),
        Offset(pageWidth * 0.7, y),
      );
      y -= 22;

      // ── 正文逐行解析：表格 / 列表 / 小节标题 / 普通段落 ──
      var i = 0;
      while (i < lines.length) {
        final line = lines[i];
        final trimmed = line.trim();

        if (trimmed.isEmpty) {
          y -= 8; // 段间距
          i++;
          continue;
        }

        // 表格块：连续竖线行
        if (trimmed.contains('|')) {
          final rows = <List<String>>[];
          while (i < lines.length && lines[i].trim().contains('|')) {
            rows.add(
                lines[i].split('|').map((c) => c.trim()).toList());
            i++;
          }
          y = _drawTable(page, rows, y, margin, pageWidth,
              tableHeaderFont, bodyFont, headerBg, zebraBg, borderColor,
              newPage);
          continue;
        }

        // 列表项：- / * / 1. 前缀
        final bullet = RegExp(r'^[-*]\s+(.*)$').firstMatch(trimmed);
        final numbered =
            RegExp(r'^(\d+)[.、]\s*(.*)$').firstMatch(trimmed);
        if (bullet != null) {
          drawText('•  ${bullet.group(1)!}', bodyFont,
              left: margin + 8);
          i++;
          continue;
        }
        if (numbered != null) {
          drawText('${numbered.group(1)}. ${numbered.group(2)!}',
              bodyFont,
              left: margin + 8);
          i++;
          continue;
        }

        // 小节标题：`## ` 前缀或「：」结尾的短行
        if (trimmed.startsWith('#')) {
          drawText(
              trimmed.replaceAll(RegExp(r'^#+\s*'), ''), headingFont,
              color: accentDeep);
          y -= 4;
          i++;
          continue;
        }

        drawText(trimmed, bodyFont);
        i++;
      }

      // ── 页脚页码（全部页回填：第 N 页 / 共 M 页）──
      final total = doc.pages.count;
      for (var p = 0; p < total; p++) {
        doc.pages[p].graphics.drawString(
              '第 ${p + 1} 页 / 共 $total 页',
              footerFont,
              brush: PdfSolidBrush(PdfColor(0x8A, 0x90, 0x99)),
              bounds: Rect.fromLTWH(0, margin - 26, pageWidth, 14),
              format: PdfStringFormat(alignment: PdfTextAlignment.center),
            );
      }

      final bytes = await doc.save();
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } finally {
      doc.dispose();
    }
  }

  /// 画一个表格，返回画完后的 y（跨页自动续表：表头重复）
  double _drawTable(
    PdfPage page,
    List<List<String>> rows,
    double startY,
    double margin,
    double pageWidth,
    PdfFont headerFont,
    PdfFont cellFont,
    PdfColor headerBg,
    PdfColor zebraBg,
    PdfColor borderColor,
    void Function() newPage,
  ) {
    var y = startY;
    final colCount = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    final tableWidth = pageWidth - margin * 2;
    final colWidth = tableWidth / (colCount == 0 ? 1 : colCount);
    const rowHeight = 22.0;

    for (var r = 0; r < rows.length; r++) {
      if (y - rowHeight < margin + 24) {
        newPage();
        y = page.getClientSize().height - margin;
        // 跨页续表：重复表头
        if (r > 0 && rows.isNotEmpty) {
          _drawRow(page, rows.first, 0, y, margin, colWidth, rowHeight,
              headerFont, headerBg, borderColor, pageWidth);
          y -= rowHeight;
        }
      }
      _drawRow(page, rows[r], r, y, margin, colWidth, rowHeight, cellFont,
          r == 0 ? headerBg : (r.isEven ? zebraBg : null), borderColor,
          pageWidth,
          isHeader: r == 0,
          headerFont: headerFont);
      y -= rowHeight;
    }
    return y - 10; // 表格后留白
  }

  void _drawRow(
    PdfPage page,
    List<String> cells,
    int rowIndex,
    double y,
    double margin,
    double colWidth,
    double rowHeight,
    PdfFont font,
    PdfColor? bg,
    PdfColor borderColor,
    double pageWidth, {
    bool isHeader = false,
    PdfFont? headerFont,
  }) {
    final colCount = cells.length;
    // 行底色
    if (bg != null) {
      page.graphics.drawRectangle(
        brush: PdfSolidBrush(bg),
        bounds: Rect.fromLTWH(
            margin, y - rowHeight, colWidth * colCount, rowHeight),
      );
    }
    // 单元格文字 + 边框
    for (var c = 0; c < colCount; c++) {
      final cellRect =
          Rect.fromLTWH(margin + c * colWidth, y - rowHeight, colWidth,
              rowHeight);
      page.graphics.drawRectangle(
        pen: PdfPen(borderColor),
        bounds: cellRect,
      );
      page.graphics.drawString(
        cells[c],
        isHeader ? (headerFont ?? font) : font,
        brush: PdfSolidBrush(
            isHeader ? PdfColor(0x1F, 0x23, 0x29) : PdfColor(0x1F, 0x23, 0x29)),
        bounds: cellRect,
        format: PdfStringFormat(
          alignment: PdfTextAlignment.center,
          lineAlignment: PdfVerticalAlignment.middle,
        ),
      );
    }
  }
}

