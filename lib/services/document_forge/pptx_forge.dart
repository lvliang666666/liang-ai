import 'dart:io';

import 'package:flutter/material.dart' show Color;

import 'document_palette.dart';
import 'ooxml_writer.dart';

/// PowerPoint（.pptx）生成器：自建 OOXML（三方包全冲突，见 ooxml_writer.dart）
///
/// 最小合法 pptx：包级部件 + 每页一个 slide + theme/master/layout。
///
/// 排版美化（Document Palette 主题色快照）：
/// - 第一页自动变标题页：大标题居中 + 主题色装饰条 + 副标题（若有）
/// - 内容页：顶部主题色标题条 + 要点带 • 符号与层级缩进
/// - theme1.xml 的配色方案直接用主题色（Office 主题色联动）
class PptxForge {
  /// 生成 pptx 到 [path]；[slides] 每项 = 一页（首元素标题，其余为要点）
  Future<File> write({
    required String path,
    required List<List<String>> slides,
    DocumentPalette? palette,
  }) async {
    final pal = palette ?? DocumentPalette(accent: const Color(0xFF4F8CFF));
    final w = OoxmlWriter();

    w.add('[Content_Types].xml', _contentTypes(slides.length));
    w.add('_rels/.rels', _rootRels);
    w.add('ppt/presentation.xml', _presentation(slides.length));
    w.add('ppt/_rels/presentation.xml.rels', _presentationRels(slides.length));
    for (var i = 0; i < slides.length; i++) {
      final n = i + 1;
      // 第一页 = 标题页（仅标题+副标题），其余 = 内容页
      final isFirst = i == 0;
      w.add('ppt/slides/slide$n.xml',
          isFirst ? _titleSlide(slides[i], pal) : _slide(slides[i], pal));
      w.add('ppt/slides/_rels/slide$n.xml.rels', _slideRels(n));
    }
    w.add('ppt/slideLayouts/slideLayout1.xml', _slideLayout);
    w.add('ppt/slideLayouts/_rels/slideLayout1.xml.rels', _layoutRels);
    w.add('ppt/slideMasters/slideMaster1.xml', _slideMaster);
    w.add('ppt/slideMasters/_rels/slideMaster1.xml.rels', _masterRels);
    w.add('ppt/theme/theme1.xml', _theme(pal));

    final file = File(path);
    await file.writeAsBytes(w.build(), flush: true);
    return file;
  }

  String _contentTypes(int count) {
    final overrides = StringBuffer();
    for (var i = 1; i <= count; i++) {
      overrides.write(
          '<Override PartName="/ppt/slides/slide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
    }
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
$overrides
</Types>''';
  }

  String get _rootRels => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
</Relationships>''';

  String _presentation(int count) {
    final ids = StringBuffer();
    for (var i = 1; i <= count; i++) {
      ids.write('<p:sldId id="${256 + i}" r:id="rId$i"/>');
    }
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<p:sldIdLst>$ids</p:sldIdLst>
<p:sldSz cx="12192000" cy="6858000"/>
<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rIdMaster"/></p:sldMasterIdLst>
</p:presentation>''';
  }

  String _presentationRels(int count) {
    final rels = StringBuffer();
    for (var i = 1; i <= count; i++) {
      rels.write(
          '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide$i.xml"/>');
    }
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
$rels
<Relationship Id="rIdMaster" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
<Relationship Id="rIdTheme" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
</Relationships>''';
  }

  /// 标题页：大标题居中（40pt 主题深色）+ 顶部/底部主题色装饰条 + 副标题
  String _titleSlide(List<String> content, DocumentPalette pal) {
    final title = content.isEmpty ? '' : content.first;
    final subtitle =
        content.length > 1 ? content.sublist(1).join(' · ') : '';
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
<p:sp>
<p:nvSpPr><p:cNvPr id="2" name="TopBar"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="180000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="${pal.accentHex}"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="zh-CN"/></a:p></p:txBody>
</p:sp>
<p:sp>
<p:nvSpPr><p:cNvPr id="3" name="Title"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="1094400" y="2400300"/><a:ext cx="10001250" cy="1600200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
<p:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="zh-CN" sz="4000" b="1" dirty="0"><a:solidFill><a:srgbClr val="${pal.accentDeepHex}"/></a:solidFill></a:rPr><a:t>${OoxmlWriter.esc(title)}</a:t></a:r></a:p></p:txBody>
</p:sp>
${subtitle.isEmpty ? '' : '<p:sp><p:nvSpPr><p:cNvPr id="4" name="Subtitle"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="1094400" y="4200525"/><a:ext cx="10001250" cy="600075"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr anchor="t"/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="zh-CN" sz="1600" dirty="0"><a:solidFill><a:srgbClr val="8A9099"/></a:solidFill></a:rPr><a:t>${OoxmlWriter.esc(subtitle)}</a:t></a:r></a:p></p:txBody></p:sp>'}
<p:sp>
<p:nvSpPr><p:cNvPr id="5" name="BottomBar"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="0" y="6678000"/><a:ext cx="12192000" cy="180000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="${pal.accentHex}"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="zh-CN"/></a:p></p:txBody>
</p:sp>
</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>''';
  }

  /// 内容页：顶部主题色标题条（标题白字）+ 要点带 • 符号与二级缩进
  String _slide(List<String> content, DocumentPalette pal) {
    final title = content.isEmpty ? '' : content.first;
    final bullets = content.skip(1).toList();
    final bodyParas = StringBuffer();
    for (final b in bullets) {
      bodyParas.write(
          '<a:p><a:pPr lvl="0" marL="285750" indent="-285750">'
          '<a:buChar char="•"/></a:pPr>'
          '<a:r><a:rPr lang="zh-CN" sz="1800" dirty="0"/>'
          '<a:t>${OoxmlWriter.esc(b)}</a:t></a:r></a:p>');
    }
    if (bullets.isEmpty) {
      bodyParas.write('<a:p><a:endParaRPr lang="zh-CN" dirty="0"/></a:p>');
    }
    return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
<p:sp>
<p:nvSpPr><p:cNvPr id="2" name="TitleBar"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="1000125"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="${pal.accentHex}"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
<p:txBody><a:bodyPr anchor="ctr" lIns="548640"/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="2800" b="1" dirty="0"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:rPr><a:t>${OoxmlWriter.esc(title)}</a:t></a:r></a:p></p:txBody>
</p:sp>
<p:sp>
<p:nvSpPr><p:cNvPr id="3" name="Content"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="914400" y="1300000"/><a:ext cx="10363200" cy="5100000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
<p:txBody><a:bodyPr/><a:lstStyle/>$bodyParas</p:txBody>
</p:sp>
</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>''';
  }

  String _slideRels(int n) => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
</Relationships>''';

  String get _slideLayout => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" type="obj" preserve="1">
<p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>
<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sldLayout>''';

  String get _layoutRels => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
</Relationships>''';

  String get _slideMaster => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>
<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
</p:sldMaster>''';

  String get _masterRels => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
</Relationships>''';

  /// theme：accent1 直接用主题强调色（Office 主题色联动）
  String _theme(DocumentPalette pal) => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office">
<a:themeElements>
<a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="${pal.accentHex}"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>
<a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>
<a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>
</a:themeElements>
</a:theme>''';
}
