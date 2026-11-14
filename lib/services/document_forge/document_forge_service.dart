import 'dart:io';

import 'csv_forge.dart';
import 'docx_forge.dart';
import 'document_palette.dart';
import 'pdf_forge.dart';
import 'pptx_forge.dart';
import 'xlsx_forge.dart';

/// 文档生成统一入口（Document Forge）
///
/// 五种格式分发到对应 forge：pdf（syncfusion）/ docx、xlsx、pptx
/// （自建 OOXML，三方包全冲突）/ csv（UTF-8 BOM）。输出目录由宿主
/// 注入（工具层保持纯 Dart 可单测，无 path_provider 依赖）。
/// [palette] 为排版强调色（宿主从当前 App 主题快照注入；null =
/// 各 forge 内置商务蓝兜底）。
class DocumentForgeService {
  DocumentForgeService({required this.outputDir, this.palette});

  /// 生成文件的输出目录（应用沙箱 documents/attachments，与用户
  /// 上传附件同目录——会话附件聚合天然可见）
  final Directory outputDir;

  /// 排版强调色（生成时快照，换主题后旧文档不变）
  final DocumentPalette? palette;

  /// 支持的格式 → 扩展名
  static const formats = {
    'pdf': 'pdf',
    'word': 'docx',
    'excel': 'xlsx',
    'ppt': 'pptx',
    'csv': 'csv',
  };

  /// 生成文档，返回落盘文件
  ///
  /// [format] 取 formats 的 key（pdf/word/excel/ppt/csv）；
  /// [title] 为文档标题（csv 忽略）；[lines] 为正文行（xlsx/ppt/csv
  /// 按 [asTable] 语义解释，见各 forge）；[paletteOverride] 临时覆盖
  /// 构造时的色板（测试用）。
  Future<File> generate({
    required String format,
    required String title,
    required List<String> lines,
    required String fileName,
    DocumentPalette? paletteOverride,
  }) async {
    final pal = paletteOverride ?? palette;
    final ext = formats[format];
    if (ext == null) {
      throw ArgumentError(
          '不支持的格式：$format（可选：${formats.keys.join('/')}）');
    }
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    final path =
        '${outputDir.path}${Platform.pathSeparator}$fileName.$ext';

    switch (format) {
      case 'pdf':
        return PdfForge()
            .write(path: path, title: title, lines: lines, palette: pal);
      case 'word':
        return DocxForge()
            .write(path: path, title: title, lines: lines, palette: pal);
      case 'excel':
        return XlsxForge()
            .write(path: path, rows: _table(lines), palette: pal);
      case 'ppt':
        return PptxForge()
            .write(path: path, slides: _slides(lines), palette: pal);
      case 'csv':
        return CsvForge().write(path: path, rows: _table(lines));
      default:
        throw ArgumentError('不支持的格式：$format');
    }
  }

  /// 表格语义：每行一条，竖线 `|` 分列（模型输出表格的自然写法）
  List<List<String>> _table(List<String> lines) => [
        for (final line in lines)
          line.isEmpty ? <String>[] : line.split('|').map((c) => c.trim()).toList(),
      ];

  /// 幻灯片语义：空行分页，页内首行为标题、其余为要点
  List<List<String>> _slides(List<String> lines) {
    final slides = <List<String>>[];
    var current = <String>[];
    for (final line in lines) {
      if (line.trim().isEmpty) {
        if (current.isNotEmpty) slides.add(current);
        current = <String>[];
      } else {
        current.add(line.trim());
      }
    }
    if (current.isNotEmpty) slides.add(current);
    return slides;
  }
}
