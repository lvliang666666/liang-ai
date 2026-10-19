import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 导出格式
enum ExportFormat { markdown, html, plainText }

/// 文件导出服务：把 Markdown 文本落成真实文件（下载目录）
class FileExportService {
  /// 导出内容为文件，返回保存路径
  ///
  /// [fileNameBase] 不带扩展名（如 "会话标题_20261017"）。
  static Future<String> export({
    required String content,
    required String fileNameBase,
    required ExportFormat format,
  }) async {
    final safeName = _sanitize(fileNameBase);
    final (ext, bytes) = switch (format) {
      ExportFormat.markdown => ('md', _utf8(content)),
      ExportFormat.html => ('html', _utf8(_wrapHtml(content))),
      ExportFormat.plainText => ('txt', _utf8(_stripMarkdown(content))),
    };

    final dir = await _exportDirectory();
    // 同名冲突：追加序号
    var path = '${dir.path}/$safeName.$ext';
    var i = 1;
    while (File(path).existsSync()) {
      path = '${dir.path}/$safeName($i).$ext';
      i++;
    }
    await File(path).writeAsBytes(bytes);
    return path;
  }

  /// 导出内容并调起系统分享面板（QQ/微信/邮件等已装应用自动出现）
  ///
  /// 文件写入临时目录（分享后由系统/用户处理，不占用用户可见空间）。
  /// 返回分享结果状态；用户取消分享返回 null。
  static Future<ShareResult?> share({
    required String content,
    required String fileNameBase,
    required ExportFormat format,
  }) async {
    final safeName = _sanitize(fileNameBase);
    final (ext, bytes) = switch (format) {
      ExportFormat.markdown => ('md', _utf8(content)),
      ExportFormat.html => ('html', _utf8(_wrapHtml(content))),
      ExportFormat.plainText => ('txt', _utf8(_stripMarkdown(content))),
    };

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$safeName.$ext';
    await File(path).writeAsBytes(bytes);

    return SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: _mimeType(format))],
      fileNameOverrides: ['$safeName.$ext'],
    ));
  }

  /// 分享用的 MIME 类型（微信/QQ 据此决定以文件还是文本形式接收）
  static String _mimeType(ExportFormat format) => switch (format) {
        ExportFormat.markdown => 'text/markdown',
        ExportFormat.html => 'text/html',
        ExportFormat.plainText => 'text/plain',
      };

  /// Markdown → 独立 HTML 文件（带基础样式，手机浏览器/WPS 可直接打开）
  static String _wrapHtml(String markdownText) {
    final body = md.markdownToHtml(
      markdownText,
      extensionSet: md.ExtensionSet.gitHubWeb,
    );
    return '''<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>导出文档</title>
<style>
  body { font-family: -apple-system, "Segoe UI", Roboto, "PingFang SC",
         "Microsoft YaHei", sans-serif; max-width: 760px; margin: 0 auto;
         padding: 24px 16px; line-height: 1.7; color: #1f1f1f; }
  pre { background: #f5f5f5; padding: 12px; border-radius: 8px;
        overflow-x: auto; font-size: 13px; }
  code { background: #f5f5f5; padding: 2px 5px; border-radius: 4px;
         font-size: 0.9em; }
  pre code { background: none; padding: 0; }
  table { border-collapse: collapse; width: 100%; margin: 12px 0; }
  th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; }
  th { background: #fafafa; }
  blockquote { border-left: 4px solid #ddd; margin: 12px 0;
               padding: 4px 16px; color: #555; }
  h1, h2, h3 { border-bottom: 1px solid #eee; padding-bottom: 6px; }
</style>
</head>
<body>
$body
</body>
</html>''';
  }

  /// Markdown → 纯文本（去掉常见标记，保留结构换行）
  static String _stripMarkdown(String text) {
    var t = text;
    // 代码块围栏
    t = t.replaceAll(RegExp(r'```+\w*\n?'), '');
    // 行内代码
    t = t.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!);
    // 图片 ![alt](url) → alt
    t = t.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!);
    // 链接 [text](url) → text (url)
    t = t.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\(([^)]*)\)'), (m) => '${m.group(1)} (${m.group(2)})');
    // 标题 #
    t = t.replaceAllMapped(RegExp(r'^#{1,6}\s+', multiLine: true), (m) => '');
    // 加粗/斜体
    t = t.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1)!);
    t = t.replaceAllMapped(RegExp(r'\*([^*]+)\*'), (m) => m.group(1)!);
    // 引用
    t = t.replaceAllMapped(RegExp(r'^>\s?', multiLine: true), (m) => '');
    // 分隔线
    t = t.replaceAll(RegExp(r'^(-{3,}|\*{3,})\s*$', multiLine: true), '');
    // 列表标记保留为 •
    t = t.replaceAllMapped(RegExp(r'^(\s*)[-*+]\s+', multiLine: true),
        (m) => '${m.group(1)}• ');
    return t.trim();
  }

  /// 导出目录：Android 下载目录（公开可见），失败回退应用文档目录
  static Future<Directory> _exportDirectory() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {}
    return getApplicationDocumentsDirectory();
  }

  /// 文件名安全化：去掉路径分隔符与非法字符
  static String _sanitize(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (n.isEmpty) n = 'export';
    if (n.length > 60) n = n.substring(0, 60);
    return n;
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));
}
