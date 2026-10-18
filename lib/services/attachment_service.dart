import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/message_attachment.dart';

/// 附件处理服务：纯逻辑（给定文件名 + 字节 → MessageAttachment）
///
/// 插件调用（image_picker / file_picker）在 UI 层薄胶水中完成，
/// 本服务只做「字节 → 附件」的转换，保证测试环境可跑。
class AttachmentService {
  const AttachmentService({this.storageDir});

  /// 文件附件原文件的保存目录（应用沙箱）；null = 不保存原文件
  final Directory? storageDir;

  /// 图片字节 → 图片附件（JPEG base64，压缩由 image_picker 原生完成）
  MessageAttachment imageAttachment(String name, Uint8List bytes) {
    return MessageAttachment(
      type: AttachmentType.image,
      name: name.isEmpty ? 'photo.jpg' : name,
      base64Data: base64Encode(bytes),
    );
  }

  /// 文件字节 → 文件附件（提取纯文本 + 保存原文件供点开）
  ///
  /// 支持 txt / md（UTF-8 直读）与 pdf（文本层提取）。
  /// 扫描版 PDF 无文本层时抛 [AttachmentException]。
  /// [storageDir] 非空时把原文件复制进沙箱并记录路径。
  Future<MessageAttachment> fileAttachment(String name, Uint8List bytes) async {
    final text = await extractText(name, bytes);
    String? savedPath;
    if (storageDir != null) {
      savedPath = await saveOriginal(name, bytes);
    }
    return MessageAttachment(
      type: AttachmentType.file,
      name: name,
      extractedText: text,
      filePath: savedPath,
    );
  }

  /// 原文件保存到沙箱（重名加时间戳后缀），返回保存路径
  Future<String> saveOriginal(String name, Uint8List bytes) async {
    final dir = storageDir!;
    if (!await dir.exists()) await dir.create(recursive: true);
    var fileName = p.basename(name.isEmpty ? 'file' : name);
    var target = p.join(dir.path, fileName);
    if (await File(target).exists()) {
      final ext = p.extension(fileName);
      final base = p.basenameWithoutExtension(fileName);
      fileName =
          '$base${DateTime.now().millisecondsSinceEpoch}$ext';
      target = p.join(dir.path, fileName);
    }
    await File(target).writeAsBytes(bytes, flush: true);
    return target;
  }

  /// 按扩展名提取文件纯文本
  Future<String> extractText(String name, Uint8List bytes) async {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return _extractPdfText(bytes);
    }
    // txt / md：UTF-8 直读（容错非法字节）
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// PDF 文本层提取（syncfusion 纯 Dart 实现，测试环境可用）
  String _extractPdfText(Uint8List bytes) {
    try {
      final doc = PdfDocument(inputBytes: bytes);
      final text = PdfTextExtractor(doc).extractText();
      doc.dispose();
      final trimmed = text.trim();
      if (trimmed.isEmpty) {
        throw const AttachmentException(
            '该 PDF 没有文本层（可能是扫描件），无法提取内容');
      }
      return trimmed;
    } on AttachmentException {
      rethrow;
    } catch (_) {
      throw const AttachmentException('PDF 解析失败，请确认文件未损坏');
    }
  }
}

/// 附件处理异常（用户可读信息）
class AttachmentException implements Exception {
  const AttachmentException(this.message);
  final String message;

  @override
  String toString() => message;
}
