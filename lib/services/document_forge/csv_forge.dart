import 'dart:io';

/// CSV 生成器
///
/// ⚠️ UTF-8 BOM 必须带：无 BOM 时 Excel 按系统 ANSI 解码，中文全乱码。
/// 带上 EF BB BF 三字节，Excel/WPS/Numbers 均正确识别 UTF-8。
class CsvForge {
  /// 生成 CSV 到 [path]；[rows] 为二维表
  Future<File> write({
    required String path,
    required List<List<String>> rows,
  }) async {
    final buf = StringBuffer('﻿'); // UTF-8 BOM
    for (final row in rows) {
      buf.writeln(row.map(_field).join(','));
    }
    final file = File(path);
    // writeAsString 以 UTF-8 编码，BOM 字符 U+FEFF 落盘即 EF BB BF
    await file.writeAsString(buf.toString(), flush: true);
    return file;
  }

  /// RFC 4180 字段转义：含逗号/引号/换行时整体加引号，内部引号翻倍
  String _field(String value) {
    final needsQuote =
        value.contains(',') || value.contains('"') || value.contains('\n');
    if (!needsQuote) return value;
    return '"${value.replaceAll('"', '""')}"';
  }
}
