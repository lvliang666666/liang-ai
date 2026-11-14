import 'dart:convert';
import 'dart:io';

import 'package:ai_chat_app/services/document_forge/document_forge_service.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// Document Forge 服务单测：五种格式真实落盘 + 内容断言
///
/// 纯 test 真实文件 IO（写临时目录，tearDown 清理）——无 platform
/// channel，无 fakeAsync 问题。
void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('doc_forge_test');
  });

  tearDown(() {
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  DocumentForgeService svc() => DocumentForgeService(outputDir: tmpDir);

  group('格式分发与文件名', () {
    test('不支持的格式抛 ArgumentError', () async {
      expect(
        () => svc().generate(
            format: 'doc', title: 't', lines: [], fileName: 'f'),
        throwsArgumentError,
      );
    });

    test('输出目录不存在时自动创建', () async {
      final nested = Directory('${tmpDir.path}/a/b');
      final f = await DocumentForgeService(outputDir: nested).generate(
          format: 'csv', title: 't', lines: ['x'], fileName: 'f');
      expect(f.existsSync(), isTrue);
    });

    test('扩展名按格式映射', () async {
      final cases = {
        'pdf': 'pdf',
        'word': 'docx',
        'excel': 'xlsx',
        'ppt': 'pptx',
        'csv': 'csv',
      };
      for (final entry in cases.entries) {
        final f = await svc().generate(
            format: entry.key,
            title: '标题',
            lines: ['内容'],
            fileName: 'test_${entry.key}');
        expect(f.path.endsWith('.${entry.value}'), isTrue,
            reason: '${entry.key} 应产出 .${entry.value}');
      }
    });
  });

  group('PDF', () {
    test('生成合法 PDF（%PDF 头 + 中文标题写入）', () async {
      final f = await svc().generate(
          format: 'pdf',
          title: '测试文档',
          lines: ['第一段', '', '第二段'],
          fileName: 't');
      final bytes = f.readAsBytesSync();
      expect(bytes.length, greaterThan(100));
      // PDF 文件头魔数
      expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
    });

    test('多行自动换页不崩溃', () async {
      final f = await svc().generate(
          format: 'pdf',
          title: '长文档',
          lines: List.generate(120, (i) => '第 $i 行内容'),
          fileName: 'long');
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(1000));
    });
  });

  group('DOCX', () {
    test('zip 结构含三个必需部件 + 标题/正文转义正确', () async {
      final f = await svc().generate(
          format: 'word',
          title: '报告<标题>',
          lines: ['第一段 & 内容', ''],
          fileName: 't');
      final archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
      final names = archive.files.map((e) => e.name).toList();
      expect(names, containsAll([
        '[Content_Types].xml',
        '_rels/.rels',
        'word/document.xml',
      ]));
      final doc =
          utf8.decode(archive.findFile('word/document.xml')!.content);
      expect(doc, contains('报告&lt;标题&gt;'));
      expect(doc, contains('第一段 &amp; 内容'));
      expect(doc, contains('Heading1'));
    });
  });

  group('XLSX', () {
    test('inlineStr 单元格 + 列号字母递进', () async {
      final f = await svc().generate(
          format: 'excel',
          title: 't',
          lines: ['姓名|年龄|城市', '张三|28|北京'],
          fileName: 't');
      final archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
      final sheet = utf8.decode(archive.findFile('xl/worksheets/sheet1.xml')!.content);
      expect(sheet, contains('<c r="A1" t="inlineStr">'));
      expect(sheet, contains('<c r="C2" t="inlineStr">'));
      expect(sheet, contains('张三'));
      expect(sheet, contains('北京'));
      final wb = utf8.decode(archive.findFile('xl/workbook.xml')!.content);
      expect(wb, contains('Sheet1'));
    });

    test('26 列以上列号进位（AA）', () async {
      final f = await svc().generate(
          format: 'excel',
          title: 't',
          lines: ['${List.filled(27, 'x').join('|')}'],
          fileName: 't');
      final archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
      final sheet = utf8.decode(archive.findFile('xl/worksheets/sheet1.xml')!.content);
      expect(sheet, contains('r="AA1"'));
    });
  });

  group('PPTX', () {
    test('空行分页：两页 slide + 标题要点', () async {
      final f = await svc().generate(
          format: 'ppt',
          title: 't',
          lines: ['封面标题', '要点一', '', '第二页标题', '要点 A', '要点 B'],
          fileName: 't');
      final archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
      final names = archive.files.map((e) => e.name).toList();
      expect(names, contains('ppt/slides/slide1.xml'));
      expect(names, contains('ppt/slides/slide2.xml'));
      expect(names, isNot(contains('ppt/slides/slide3.xml')));
      final s1 = utf8.decode(archive.findFile('ppt/slides/slide1.xml')!.content);
      expect(s1, contains('封面标题'));
      expect(s1, contains('要点一'));
      final s2 = utf8.decode(archive.findFile('ppt/slides/slide2.xml')!.content);
      expect(s2, contains('第二页标题'));
      expect(s2, contains('要点 B'));
      final pres = utf8.decode(archive.findFile('ppt/presentation.xml')!.content);
      expect(pres, contains('rId1'));
      expect(pres, contains('rId2'));
    });
  });

  group('CSV', () {
    test('UTF-8 BOM 必须带（Excel 中文兼容）', () async {
      final f = await svc().generate(
          format: 'csv',
          title: 't',
          lines: ['姓名,城市', '张三,北京'],
          fileName: 't');
      final bytes = f.readAsBytesSync();
      // EF BB BF
      expect(bytes[0], 0xEF);
      expect(bytes[1], 0xBB);
      expect(bytes[2], 0xBF);
      final text = utf8.decode(bytes.sublist(3));
      expect(text, contains('张三'));
    });

    test('含逗号/引号/换行的字段按 RFC 4180 转义', () async {
      final f = await svc().generate(
          format: 'csv',
          title: 't',
          lines: ['a,b', '含"引号"', '含,逗号'],
          fileName: 't');
      final text = utf8.decode(f.readAsBytesSync().sublist(3));
      expect(text, contains('"含""引号"""'));
      expect(text, contains('"含,逗号"'));
    });
  });
}
