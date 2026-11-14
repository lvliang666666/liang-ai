import 'dart:typed_data';

import 'package:archive/archive.dart';

/// OOXML（docx/xlsx/pptx）zip 骨架写入器
///
/// 三方包全冲突（docx_dart/excel 要 xml <7，dart_pptx 要 archive ^3，
/// 均与 syncfusion 35.x 的 xml ≥7.0.1 / archive 4.5.2 互斥），文档生成
/// 必须自建 OOXML。本文件只做两件事：
/// - 把「路径 → 文本内容」的文件清单打成标准 zip 字节（OOXML 本质
///   就是 zip + 约定目录结构）
/// - XML 文本转义（OOXML 里中文/引号/尖括号必须转义，否则包损坏）
///
/// 零新依赖：archive 4.5.2 已在 pubspec.lock（transitive）。
class OoxmlWriter {
  final Map<String, String> _files = {};

  /// 添加一个包内文件（路径用正斜杠，如 `word/document.xml`）
  void add(String path, String xmlContent) {
    _files[path] = xmlContent;
  }

  /// 打成 zip 字节（OOXML 规范：[Content_Types].xml 必须在包内，
  /// zip 条目顺序无强制要求，Office 按 OPC 规范读取）
  Uint8List build() {
    final archive = Archive();
    // 排序保证字节级确定性（同输入同输出，测试快照稳定）
    final paths = _files.keys.toList()..sort();
    for (final path in paths) {
      archive.addFile(ArchiveFile.string(path, _files[path]!));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  /// XML 文本转义：& < > " ' 五件套（中文原样保留，UTF-8 声明在文件头）
  static String esc(Object? value) {
    final s = value?.toString() ?? '';
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
