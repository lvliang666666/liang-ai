import 'dart:io';

import 'package:ai_chat_app/services/diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// E4 诊断日志单测：脱敏 / 元数据格式 / 环形 buffer / 文件滚动 / 清理
///
/// DiagnosticLog 全静态——每个用例 reset() 隔离；文件用例走
/// initForTest(临时目录)，不碰 path_provider。
void main() {
  late Directory tempDir;

  setUp(() async {
    DiagnosticLog.reset();
    tempDir = await Directory.systemTemp.createTemp('diag_test');
    DiagnosticLog.initForTest(tempDir);
  });

  tearDown(() async {
    DiagnosticLog.reset();
    // fire-and-forget 落盘可能仍在写：重试删除直到句柄释放
    for (var i = 0; i < 25; i++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  group('sanitize 脱敏', () {
    test('Bearer token 打码（大小写不敏感）', () {
      expect(
        DiagnosticLog.sanitize('Authorization: Bearer abc123XYZ._~+/=='),
        'Authorization: Bearer ***',
      );
      expect(
        DiagnosticLog.sanitize('authorization: bearer sk-lower-case-99'),
        'authorization: Bearer ***',
      );
    });

    test('sk- 开头 Key 打码', () {
      expect(
        DiagnosticLog.sanitize('key=sk-abcdefgh12345678'),
        'key=sk-***',
      );
      // 短于 8 位不算 Key 形态（避免误伤普通文本）
      expect(DiagnosticLog.sanitize('sk-123'), 'sk-123');
    });

    test('普通文本原样保留', () {
      const text = 'API timeout HTTP 429 耗时1200ms model=glm-4.7';
      expect(DiagnosticLog.sanitize(text), text);
    });
  });

  group('logApiError 元数据', () {
    test('完整元数据：kind + HTTP 码 + 耗时 + model', () {
      DiagnosticLog.logApiError(
          kind: 'connectionTimeout',
          statusCode: null,
          elapsedMs: 30000,
          model: 'glm-4.7');
      expect(DiagnosticLog.entries.length, 1);
      final e = DiagnosticLog.entries.single;
      expect(e.kind, LogKind.api);
      expect(e.message, contains('API connectionTimeout'));
      expect(e.message, contains('耗时30000ms'));
      expect(e.message, contains('model=glm-4.7'));
      // 无状态码时不出现 HTTP 字样
      expect(e.message, isNot(contains('HTTP')));
    });

    test('带状态码：HTTP 429 出现在消息里', () {
      DiagnosticLog.logApiError(
          kind: 'badResponse', statusCode: 429, elapsedMs: 120, model: 'm');
      expect(DiagnosticLog.entries.single.message, contains('HTTP 429'));
    });

    test('connected 成功事件也走同一格式', () {
      DiagnosticLog.logApiError(kind: 'connected', elapsedMs: 800);
      expect(DiagnosticLog.entries.single.message, contains('API connected'));
    });
  });

  group('环形 buffer', () {
    test('超过 maxEntries 丢弃最旧条目', () {
      for (var i = 0; i < DiagnosticLog.maxEntries + 50; i++) {
        DiagnosticLog.log('entry-$i');
      }
      expect(DiagnosticLog.entries.length, DiagnosticLog.maxEntries);
      // 最旧的 50 条被挤掉，最新一条在尾
      expect(DiagnosticLog.entries.first.message, 'entry-50');
      expect(DiagnosticLog.entries.last.message,
          'entry-${DiagnosticLog.maxEntries + 49}');
    });

    test('entries 是只读视图', () {
      expect(
        () => DiagnosticLog.entries.add(
            LogEntry(timestamp: DateTime.now(), kind: LogKind.general, message: 'x')),
        throwsUnsupportedError,
      );
    });
  });

  group('文件落盘', () {
    test('log 后文件存在且内容脱敏', () async {
      // Bearer 与 sk- 两种形态分别验证（Bearer 正则先命中会整体打码）
      DiagnosticLog.log('Bearer abcdefgh12345678 token');
      DiagnosticLog.log('独立 key=sk-abcdefghijklmnop 泄漏测试');
      // fire-and-forget：轮询等落盘完成
      final file = File(
          '${tempDir.path}/diag_${_stamp(DateTime.now())}.log');
      String content = '';
      for (var i = 0; i < 50; i++) {
        if (await file.exists()) {
          content = await file.readAsString();
          if (content.split('\n').where((l) => l.isNotEmpty).length >= 2) {
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(content, isNotEmpty);
      expect(content, contains('Bearer ***'));
      expect(content, contains('sk-***'));
      expect(content, isNot(contains('sk-abcdefghijklmnop')));
      // 行格式：ISO 时间戳 + [INFO] 前缀
      expect(content, contains('[INFO]'));
    });

    test('logApiError 落盘带 [API] 前缀', () async {
      DiagnosticLog.logApiError(kind: 'connected', elapsedMs: 100);
      final file = File(
          '${tempDir.path}/diag_${_stamp(DateTime.now())}.log');
      String content = '';
      for (var i = 0; i < 50; i++) {
        if (await file.exists()) {
          content = await file.readAsString();
          if (content.isNotEmpty) break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(content, contains('[API]'));
    });

    test('readAllFiles 汇总并脱敏', () async {
      DiagnosticLog.log('Bearer secret-token-xyz');
      for (var i = 0; i < 50; i++) {
        final text = await DiagnosticLog.readAllFiles();
        if (text.isNotEmpty) {
          expect(text, contains('Bearer ***'));
          expect(text, isNot(contains('secret-token-xyz')));
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('日志文件未落盘');
    });

    test('clearAll 删除文件 + 清空 buffer', () async {
      DiagnosticLog.log('to-be-cleared');
      final file = File(
          '${tempDir.path}/diag_${_stamp(DateTime.now())}.log');
      for (var i = 0; i < 50; i++) {
        if (await file.exists()) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await file.exists(), isTrue);

      await DiagnosticLog.clearAll();
      expect(DiagnosticLog.entries, isEmpty);
      expect(await file.exists(), isFalse);
    });

    test('未初始化时只进内存不落盘', () async {
      DiagnosticLog.reset(); // 清掉 initForTest 注入
      DiagnosticLog.log('memory-only');
      expect(DiagnosticLog.entries.length, 1);
      expect(await DiagnosticLog.readAllFiles(), '');
    });
  });

  group('logCrash 崩溃记录', () {
    test('堆栈截断到前 20 行', () {
      final stack = List.generate(40, (i) => 'frame-$i').join('\n');
      DiagnosticLog.logCrash('Boom: bad state', stack);
      final e = DiagnosticLog.entries.single;
      expect(e.kind, LogKind.crash);
      expect(e.message, contains('未捕获异常: Boom: bad state'));
      expect(e.message, contains('frame-19'));
      expect(e.message, isNot(contains('frame-20')));
    });

    test('无堆栈时只记错误消息', () {
      DiagnosticLog.logCrash('Boom', null);
      expect(DiagnosticLog.entries.single.message, '未捕获异常: Boom');
    });
  });
}

/// 当天日志文件名的时间戳段（与 DiagnosticLog 内部格式一致）
String _stamp(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
