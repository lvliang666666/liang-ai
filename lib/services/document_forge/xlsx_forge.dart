import 'dart:io';

import 'package:flutter/material.dart' show Color;

import 'document_palette.dart';
import 'ooxml_writer.dart';

/// Excel（.xlsx）生成器：自建 OOXML（三方包全冲突，见 ooxml_writer.dart）
///
/// 最小合法 xlsx：[Content_Types].xml + _rels/.rels + xl/workbook.xml +
/// xl/_rels/workbook.xml.rels + xl/worksheets/sheet1.xml。
/// 单元格用 inlineStr（内联字符串），免建共享字符串表。
///
/// 排版美化（Document Palette 主题色快照）：
/// - 表头行（首行）加粗 + 主题色底 + 白字
/// - 列宽按内容自适应（中文按 2 字符宽计）
/// - 冻结首行（滚动时表头常驻）
/// - 全表细边框 + 内容居中
class XlsxForge {
  /// 生成 xlsx 到 [path]；[rows] 为二维表（首行当表头）
  Future<File> write({
    required String path,
    required List<List<String>> rows,
    DocumentPalette? palette,
  }) async {
    final pal = palette ?? DocumentPalette(accent: const Color(0xFF4F8CFF));
    final w = OoxmlWriter();

    w.add('[Content_Types].xml', _contentTypes);
    w.add('_rels/.rels', _rootRels);
    w.add('xl/workbook.xml', _workbook);
    w.add('xl/_rels/workbook.xml.rels', _workbookRels);
    w.add('xl/styles.xml', _styles(pal));
    w.add('xl/worksheets/sheet1.xml', _sheet(rows, pal));

    final file = File(path);
    await file.writeAsBytes(w.build(), flush: true);
    return file;
  }

  String get _contentTypes => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>''';

  String get _rootRels => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''';

  String get _workbook => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
</workbook>''';

  String get _workbookRels => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''';

  /// 样式：s=1 表头（加粗白字+主题底+居中+边框）、s=2 斑马纹数据格、
  /// s=3 普通数据格（边框+居中）
  String _styles(DocumentPalette pal) => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="3">
<font><sz val="11"/><name val="Calibri"/></font>
<font><b/><sz val="11"/><color rgb="FF${pal.accentDeepHex}"/><name val="Calibri"/></font>
</fonts>
<fills count="4">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF${pal.headerBgHex}"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF${pal.zebraBgHex}"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="2">
<border><left/><right/><top/><bottom/><diagonal/></border>
<border>
<left style="thin"><color rgb="FF${pal.borderHex}"/></left>
<right style="thin"><color rgb="FF${pal.borderHex}"/></right>
<top style="thin"><color rgb="FF${pal.borderHex}"/></top>
<bottom style="thin"><color rgb="FF${pal.borderHex}"/></bottom>
<diagonal/>
</border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="4">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
</cellXfs>
</styleSheet>''';

  String _sheet(List<List<String>> rows, DocumentPalette pal) {
    final body = StringBuffer();
    for (var r = 0; r < rows.length; r++) {
      final isHeader = r == 0;
      final zebra = !isHeader && r.isEven;
      final styleId = isHeader ? 1 : (zebra ? 2 : 3);
      final cells = StringBuffer();
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        final ref = '${_colName(c)}${r + 1}';
        cells.write(
            '<c r="$ref" t="inlineStr" s="$styleId"><is><t xml:space="preserve">'
            '${OoxmlWriter.esc(row[c])}</t></is></c>');
      }
      body.write('<row r="${r + 1}">$cells</row>');
    }
    // 列宽自适应：按各列最长内容估宽（中文算 2），夹在 8~40 之间
    final colCount = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    final cols = StringBuffer();
    for (var c = 0; c < colCount; c++) {
      var maxLen = 4.0;
      for (final row in rows) {
        if (c < row.length) {
          final w = row[c].codeUnits
              .fold<double>(0, (s, u) => s + (u > 0x2E80 ? 2 : 1));
          if (w > maxLen) maxLen = w;
        }
      }
      final width = (maxLen * 1.15 + 3).clamp(8.0, 40.0);
      cols.write('<col min="${c + 1}" max="${c + 1}" width="$width" customWidth="1"/>');
    }
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
<sheetFormatPr defaultRowHeight="18"/>
<cols>$cols</cols>
<sheetData>$body</sheetData>
</worksheet>''';
  }

  /// 0→A, 1→B, ..., 25→Z, 26→AA
  String _colName(int index) {
    var i = index;
    final buf = StringBuffer();
    while (i >= 0) {
      buf.writeCharCode(65 + (i % 26));
      i = i ~/ 26 - 1;
    }
    return buf.toString().split('').reversed.join();
  }
}
