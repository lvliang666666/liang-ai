import 'dart:io';

import 'ooxml_writer.dart';

/// Excel（.xlsx）生成器：自建 OOXML（三方包全冲突，见 ooxml_writer.dart）
///
/// 最小合法 xlsx：[Content_Types].xml + _rels/.rels + xl/workbook.xml +
/// xl/_rels/workbook.xml.rels + xl/worksheets/sheet1.xml。
/// 单元格用 inlineStr（内联字符串），免建共享字符串表——单 sheet 场景
/// 最简且 Excel/WPS 均正常打开。
class XlsxForge {
  /// 生成 xlsx 到 [path]；[rows] 为二维表（首行当表头，纯数据不设样式）
  Future<File> write({
    required String path,
    required List<List<String>> rows,
  }) async {
    final w = OoxmlWriter();

    w.add('[Content_Types].xml', _contentTypes);
    w.add('_rels/.rels', _rootRels);
    w.add('xl/workbook.xml', _workbook);
    w.add('xl/_rels/workbook.xml.rels', _workbookRels);
    w.add('xl/worksheets/sheet1.xml', _sheet(rows));

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
</Relationships>''';

  String _sheet(List<List<String>> rows) {
    final body = StringBuffer();
    for (var r = 0; r < rows.length; r++) {
      final cells = StringBuffer();
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        // 列号转 Excel 字母列（A/B/.../Z/AA/AB...）
        final ref = '${_colName(c)}${r + 1}';
        cells.write(
            '<c r="$ref" t="inlineStr"><is><t xml:space="preserve">'
            '${OoxmlWriter.esc(row[c])}</t></is></c>');
      }
      body.write('<row r="${r + 1}">$cells</row>');
    }
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
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
