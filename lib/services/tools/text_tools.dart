import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../tool_registry.dart';

/// 文本统计工具：字符/中文字/英文词/行数/字节
class TextStatsTool extends ToolHandler {
  const TextStatsTool();

  @override
  String get name => 'text_stats';

  @override
  String get description =>
      '统计文本：总字符数、中文字符数、英文单词数、数字个数、行数、UTF-8 字节数。当用户询问字数、统计文本长度时使用。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要统计的文本'},
        },
        'required': ['text'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final text = arguments['text'] as String? ?? '';
    if (text.isEmpty) throw ArgumentError('text 为空');

    var cjk = 0;
    var digits = 0;
    for (final rune in text.runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF || // CJK 基本区
          rune >= 0x3400 && rune <= 0x4DBF || // 扩展 A
          rune >= 0xF900 && rune <= 0xFAFF) {
        // 兼容表意区
        cjk++;
      } else if (rune >= 0x30 && rune <= 0x39) {
        digits++;
      }
    }
    final lines = text.split('\n').length;
    final bytes = utf8.encode(text).length;
    // 英文单词：连续字母/数字/撇号段
    final words = RegExp(r"[A-Za-z0-9']+").allMatches(text).length;

    return [
      '总字符数：${text.length}',
      '中文字符：$cjk',
      '英文单词：$words',
      '数字字符：$digits',
      '行数：$lines',
      'UTF-8 字节：$bytes',
    ].join('\n');
  }
}

/// UUID 生成工具：v4 随机 UUID
class UuidGenerateTool extends ToolHandler {
  const UuidGenerateTool();

  @override
  String get name => 'uuid_generate';

  @override
  String get description => '生成随机 UUID v4。count 为个数（默认 1，最多 50），uppercase=true 时大写。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'count': {'type': 'number', 'description': '生成个数，默认 1，最多 50'},
          'uppercase': {'type': 'boolean', 'description': '是否大写，默认 false'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final count = ((arguments['count'] as num?)?.toInt() ?? 1).clamp(1, 50);
    final uppercase = arguments['uppercase'] == true;
    final uuids = [for (var i = 0; i < count; i++) _v4()];
    final list = uppercase ? uuids.map((u) => u.toUpperCase()).toList() : uuids;
    return list.join('\n');
  }

  /// RFC 4122 v4：随机 128 位，版本位 4、变体位 10xx
  static String _v4() {
    final rng = Random();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40; // version 4
    b[8] = (b[8] & 0x3F) | 0x80; // variant 10xx
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// Base64 编解码工具
class Base64CodecTool extends ToolHandler {
  const Base64CodecTool();

  @override
  String get name => 'base64_codec';

  @override
  String get description =>
      'Base64 编码或解码。mode="encode"（默认）把文本编码为 Base64；mode="decode" 把 Base64 解码为文本（输入须为合法 Base64）。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'mode': {
            'type': 'string',
            'enum': ['encode', 'decode'],
            'description': 'encode=编码（默认），decode=解码',
          },
          'text': {'type': 'string', 'description': '输入文本（编码时为原文，解码时为 Base64）'},
        },
        'required': ['text'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final text = arguments['text'] as String? ?? '';
    if (text.isEmpty) throw ArgumentError('text 为空');
    final mode = (arguments['mode'] as String? ?? 'encode').trim().toLowerCase();

    switch (mode) {
      case 'encode':
        return 'Base64 编码结果：\n${base64.encode(utf8.encode(text))}';
      case 'decode':
        try {
          final decoded = utf8.decode(base64.decode(text.trim()));
          return 'Base64 解码结果：\n$decoded';
        } on FormatException {
          throw ArgumentError('不是合法的 Base64 字符串');
        }
      default:
        throw ArgumentError('未知模式 "$mode"，支持 encode / decode');
    }
  }
}

/// 哈希工具：MD5 / SHA-1 / SHA-256
class HashTextTool extends ToolHandler {
  const HashTextTool();

  @override
  String get name => 'hash_text';

  @override
  String get description =>
      '计算文本哈希值。algorithm 可选 md5（默认）/ sha1 / sha256，可传多个（逗号分隔）一次算全。注意：哈希不可逆，仅用于校验/指纹。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要哈希的文本'},
          'algorithm': {
            'type': 'string',
            'description': '算法，逗号分隔：md5 / sha1 / sha256，默认 md5',
          },
        },
        'required': ['text'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final text = arguments['text'] as String? ?? '';
    if (text.isEmpty) throw ArgumentError('text 为空');
    final algos = (arguments['algorithm'] as String? ?? 'md5')
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();

    final bytes = utf8.encode(text);
    final lines = <String>[];
    for (final algo in algos) {
      switch (algo) {
        case 'md5':
          lines.add('MD5: ${_hex(md5.convert(bytes).bytes)}');
        case 'sha1':
          lines.add('SHA-1: ${_hex(sha1.convert(bytes).bytes)}');
        case 'sha256':
          lines.add('SHA-256: ${_hex(sha256.convert(bytes).bytes)}');
        default:
          throw ArgumentError('不支持的算法 "$algo"，可用 md5 / sha1 / sha256');
      }
    }
    return lines.join('\n');
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
