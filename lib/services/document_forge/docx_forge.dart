import 'dart:io';

import 'ooxml_writer.dart';

/// Word（.docx）生成器：自建 OOXML（三方包全冲突，见 ooxml_writer.dart）
///
/// 最小合法 docx：[Content_Types].xml + _rels/.rels + word/document.xml。
/// 段落 = w:p > w:r > w:t；标题用 w:pStyle Heading1（Word 内置样式，
/// styles.xml 缺省时 Word 仍按内置样式名渲染）。
class DocxForge {
  /// 生成 docx 到 [path]
  Future<File> write({
    required String path,
    required String title,
    required List<String> lines,
  }) async {
    final w = OoxmlWriter();

    w.add('[Content_Types].xml', _contentTypes);
    w.add('_rels/.rels', _rootRels);
    w.add('word/document.xml', _document(title, lines));

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
</Types>''';

  String get _rootRels => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

  String _document(String title, List<String> lines) {
    final body = StringBuffer();
    // 标题段：Heading1 样式 + 加粗兜底（无 styles.xml 时 Word 仍可读）
    body.write(_paragraph(title, style: 'Heading1', bold: true));
    for (final line in lines) {
      body.write(_paragraph(line));
    }
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>${body}<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body>
</w:document>''';
  }

  /// 一个段落；空行 = 空段落（保留段落分隔感）
  String _paragraph(String text, {String? style, bool bold = false}) {
    final props = StringBuffer('<w:pPr>');
    if (style != null) props.write('<w:pStyle w:val="$style"/>');
    props.write('</w:pPr>');
    final runProps = bold ? '<w:rPr><w:b/></w:rPr>' : '';
    final run = text.isEmpty
        ? ''
        : '<w:r>$runProps<w:t xml:space="preserve">${OoxmlWriter.esc(text)}</w:t></w:r>';
    return '<w:p>$props$run</w:p>';
  }
}
