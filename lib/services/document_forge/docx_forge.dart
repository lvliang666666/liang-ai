import 'dart:io';

import 'package:flutter/material.dart' show Color;

import 'document_palette.dart';
import 'ooxml_writer.dart';

/// Word（.docx）生成器：自建 OOXML（三方包全冲突，见 ooxml_writer.dart）
///
/// 最小合法 docx：[Content_Types].xml + _rels/.rels + word/document.xml
/// （+ 排版美化新增 word/styles.xml）。
///
/// 排版美化（Document Palette 主题色快照）：
/// - styles.xml 定义 Title/Heading1/Normal（字体字号颜色间距）
/// - 标题居中 + 主题色 + 底部装饰线（pBdr）
/// - 竖线行渲染为真表格（w:tbl：表头底色 + 斑马纹 + 细边框）
/// - 列表项用编号符号段落（• / 1. 原文保留）
class DocxForge {
  /// 生成 docx 到 [path]
  Future<File> write({
    required String path,
    required String title,
    required List<String> lines,
    DocumentPalette? palette,
  }) async {
    final pal = palette ?? DocumentPalette(accent: const Color(0xFF4F8CFF));
    final w = OoxmlWriter();

    w.add('[Content_Types].xml', _contentTypes);
    w.add('_rels/.rels', _rootRels);
    w.add('word/styles.xml', _styles(pal));
    w.add('word/document.xml', _document(title, lines, pal));

    final file = File(path);
    await file.writeAsBytes(w.build(), flush: true);
    return file;
  }

  String get _contentTypes => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>''';

  String get _rootRels => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

  String _styles(DocumentPalette pal) => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:eastAsia="宋体" w:hAnsi="Calibri"/><w:sz w:val="22"/><w:color w:val="1F2329"/></w:rPr></w:rPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:styleId="Title" w:default="0"><w:name w:val="Title"/><w:pPr><w:jc w:val="center"/><w:spacing w:after="240"/><w:pBdr><w:bottom w:val="single" w:sz="12" w:space="6" w:color="${pal.accentHex}"/></w:pBdr></w:pPr><w:rPr><w:b/><w:sz w:val="44"/><w:color w:val="${pal.accentDeepHex}"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1" w:default="0"><w:name w:val="heading 1"/><w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="${pal.accentDeepHex}"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Normal" w:default="1"><w:name w:val="Normal"/><w:pPr><w:spacing w:after="120" w:line="360" w:lineRule="auto"/></w:pPr></w:style>
</w:styles>''';

  String _document(String title, List<String> lines, DocumentPalette pal) {
    final body = StringBuffer();
    body.write(_titleParagraph(title));
    var i = 0;
    while (i < lines.length) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty) {
        body.write('<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>');
        i++;
        continue;
      }
      // 表格块：连续竖线行
      if (trimmed.contains('|')) {
        final rows = <List<String>>[];
        while (i < lines.length && lines[i].trim().contains('|')) {
          rows.add(lines[i].split('|').map((c) => c.trim()).toList());
          i++;
        }
        body.write(_table(rows, pal));
        continue;
      }
      // 小节标题
      if (trimmed.startsWith('#')) {
        body.write(_paragraph(
            trimmed.replaceAll(RegExp(r'^#+\s*'), ''),
            style: 'Heading1'));
        i++;
        continue;
      }
      // 列表项：悬挂缩进 + 项目符号
      final bullet = RegExp(r'^[-*]\s+(.*)$').firstMatch(trimmed);
      final numbered = RegExp(r'^(\d+)[.、]\s*(.*)$').firstMatch(trimmed);
      if (bullet != null) {
        body.write(_listParagraph('•  ${bullet.group(1)!}'));
        i++;
        continue;
      }
      if (numbered != null) {
        body.write(
            _listParagraph('${numbered.group(1)}. ${numbered.group(2)!}'));
        i++;
        continue;
      }
      body.write(_paragraph(trimmed));
      i++;
    }
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>$body<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body>
</w:document>''';
  }

  /// 标题段：Title 样式（居中 + 主题色 + 底部装饰线在样式里定义）
  String _titleParagraph(String text) =>
      '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr>'
      '<w:r><w:t xml:space="preserve">${OoxmlWriter.esc(text)}</w:t></w:r></w:p>';

  /// 一个正文段落（Normal 样式：1.5 倍行距在样式里定义）
  String _paragraph(String text, {String? style}) {
    final props = style == null
        ? '<w:pPr><w:pStyle w:val="Normal"/></w:pPr>'
        : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>';
    final run = text.isEmpty
        ? ''
        : '<w:r><w:t xml:space="preserve">${OoxmlWriter.esc(text)}</w:t></w:r>';
    return '<w:p>$props$run</w:p>';
  }

  /// 列表段：左缩进 360 twips（0.25 英寸）
  String _listParagraph(String text) =>
      '<w:p><w:pPr><w:pStyle w:val="Normal"/><w:ind w:left="360"/></w:pPr>'
      '<w:r><w:t xml:space="preserve">${OoxmlWriter.esc(text)}</w:t></w:r></w:p>';

  /// 真表格：表头行（首行）主题色底 + 斑马纹 + 细边框 + 内容居中
  String _table(List<List<String>> rows, DocumentPalette pal) {
    final colCount = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    // 表格宽度 = 页宽（11906 twips）减页边距，均分列
    final colW = ((11906 - 1800) / (colCount == 0 ? 1 : colCount)).round();
    final grid =
        '<w:tblGrid>${List.filled(colCount, '<w:gridCol w:w="$colW"/>').join()}</w:tblGrid>';

    final rowsXml = StringBuffer();
    for (var r = 0; r < rows.length; r++) {
      final isHeader = r == 0;
      final shade = isHeader
          ? pal.headerBgHex
          : (r.isEven ? pal.zebraBgHex : 'FFFFFF');
      final cells = StringBuffer();
      for (var c = 0; c < colCount; c++) {
        final text = c < rows[r].length ? rows[r][c] : '';
        cells.write(
            '<w:tc><w:tcPr><w:shd w:val="clear" w:fill="$shade"/>'
            '<w:vAlign w:val="center"/></w:tcPr>'
            '<w:p><w:pPr><w:jc w:val="center"/>'
            '<w:spacing w:after="40" w:line="240" w:lineRule="auto"/></w:pPr>'
            '<w:r>${isHeader ? '<w:rPr><w:b/></w:rPr>' : ''}'
            '<w:t xml:space="preserve">${OoxmlWriter.esc(text)}</w:t></w:r></w:p></w:tc>');
      }
      rowsXml.write('<w:tr>$cells</w:tr>');
    }

    return '<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/>'
        '<w:tblW w:w="0" w:type="auto"/>'
        '<w:tblBorders>'
        '<w:top w:val="single" w:sz="4" w:color="${pal.borderHex}"/>'
        '<w:left w:val="single" w:sz="4" w:color="${pal.borderHex}"/>'
        '<w:bottom w:val="single" w:sz="4" w:color="${pal.borderHex}"/>'
        '<w:right w:val="single" w:sz="4" w:color="${pal.borderHex}"/>'
        '<w:insideH w:val="single" w:sz="4" w:color="${pal.borderHex}"/>'
        '<w:insideV w:val="single" w:sz="4" w:color="${pal.borderHex}"/>'
        '</w:tblBorders></w:tblPr>$grid$rowsXml</w:tbl>'
        '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>';
  }
}
