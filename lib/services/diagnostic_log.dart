import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// E4 本地诊断日志：环形内存 buffer + 文件滚动落盘
///
/// 设计（roadmap E4，明确不做 Crashlytics/Sentry——无后台服务，
/// 本地日志 + 手动分享足够）：
/// - **环形 buffer**：内存保留最近 [maxEntries] 条（默认 500），
///   查看页即时展示，零 IO
/// - **文件滚动**：按天一个文件（`diag_YYYYMMDD.log`），保留
///   [retentionDays] 天（默认 3），启动时清理过期文件
/// - **脱敏铁律**：[sanitize] 强制执行——API Key（Bearer/sk- 前缀）、
///   消息正文、请求体内容一律不落盘；只记元数据（状态码/类型/耗时）
/// - **崩溃钩子**：[installHooks] 挂 FlutterError.onError 与
///   PlatformDispatcher.onError，未捕获异常落盘后走原处理器
///
/// 全部方法静态 + fire-and-forget：日志失败绝不影响主流程。
class DiagnosticLog {
  DiagnosticLog._();

  /// 内存环形 buffer 上限
  static const maxEntries = 500;

  /// 文件保留天数
  static const retentionDays = 3;

  /// 日志目录名（应用文档目录下）
  static const dirName = 'diagnostics';

  /// 内存环形 buffer（最新在尾）
  static final List<LogEntry> _buffer = [];

  /// 全量 buffer 只读视图（设置页查看用）
  static List<LogEntry> get entries => List.unmodifiable(_buffer);

  /// 落盘目录（init 时解析；null = 未初始化/不可用，只进内存）
  static Directory? _dir;

  /// 是否已初始化（测试注入用）
  static bool get initialized => _dir != null;

  /// 初始化：解析目录 + 清理过期文件。失败静默（只进内存模式）。
  static Future<void> init() async {
    try {
      final docs = await _documentsDir();
      final dir = Directory('${docs.path}/$dirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      await _cleanExpired();
    } catch (_) {
      _dir = null; // 目录不可用：降级为纯内存
    }
  }

  /// 测试注入目录（绕过 path_provider）
  static void initForTest(Directory dir) {
    _dir = dir;
  }

  /// 重置全部状态（测试隔离用）
  static void reset() {
    _buffer.clear();
    _dir = null;
    _writeQueue = Future.value();
  }

  /// 记一条日志（内存 + 异步落盘）
  static void log(String message, {LogKind kind = LogKind.general}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      kind: kind,
      message: message,
    );
    _buffer.add(entry);
    if (_buffer.length > maxEntries) {
      _buffer.removeRange(0, _buffer.length - maxEntries);
    }
    _appendToFile(entry);
  }

  /// 记 API 错误元数据（E4 核心场景：「为什么回答中断了」有据可查）
  ///
  /// 只记元数据：状态码/错误类型/耗时/模型——**正文与 Key 永不传入**。
  static void logApiError({
    required String kind,
    int? statusCode,
    required int elapsedMs,
    String? model,
  }) {
    log('API $kind'
        '${statusCode != null ? ' HTTP $statusCode' : ''}'
        ' 耗时${elapsedMs}ms'
        '${model != null ? ' model=$model' : ''}',
        kind: LogKind.api);
  }

  /// 记未捕获异常（崩溃钩子用）
  static void logCrash(String error, String? stack) {
    // 堆栈截断（前 20 行）——完整堆栈对排查启动崩溃足够且防文件膨胀
    final trimmed = stack == null
        ? ''
        : '\n${stack.split('\n').take(20).join('\n')}';
    log('未捕获异常: $error$trimmed', kind: LogKind.crash);
  }

  /// 脱敏：移除 Bearer token / sk- 开头的 Key 形态
  ///
  /// 所有外部传入文本（错误消息可能含响应片段）过这道再落盘。
  static String sanitize(String text) {
    var result = text;
    // Bearer <token> → Bearer ***
    result = result.replaceAllMapped(
      RegExp(r'Bearer\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false),
      (_) => 'Bearer ***',
    );
    // sk- 开头的 OpenAI 风格 Key
    result = result.replaceAllMapped(
      RegExp(r'sk-[A-Za-z0-9]{8,}'),
      (_) => 'sk-***',
    );
    return result;
  }

  /// 读取全部日志文件内容（设置页查看/分享用；按文件名倒序 = 新的在前）
  static Future<String> readAllFiles() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return '';
    final files = (await dir.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    final buffer = StringBuffer();
    for (final f in files) {
      try {
        buffer.writeln(await f.readAsString());
      } catch (_) {}
    }
    return sanitize(buffer.toString());
  }

  /// 清空全部日志文件 + 内存 buffer
  static Future<void> clearAll() async {
    _buffer.clear();
    final dir = _dir;
    if (dir == null || !await dir.exists()) return;
    try {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.log')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 追加落盘（fire-and-forget：失败静默，绝不影响主流程）
  ///
  /// 写队列串行化：两条 log 的落盘并发执行时，writeAsString(append)
  /// 对不存在的文件各自 create——后完成者覆盖先完成者（丢行）。
  /// 队列保证同目录写操作按调用顺序执行，行序与 buffer 一致。
  static Future<void> _writeQueue = Future.value();

  static void _appendToFile(LogEntry entry) {
    final dir = _dir;
    if (dir == null) return;
    _writeQueue = _writeQueue.then((_) async {
      try {
        final date = entry.timestamp;
        final name =
            'diag_${date.year}${_pad(date.month)}${_pad(date.day)}.log';
        final file = File('${dir.path}/$name');
        await file.writeAsString(entry.toLine(),
            mode: FileMode.append, flush: false);
      } catch (_) {}
    });
  }

  /// 清理超过保留期的日志文件
  static Future<void> _cleanExpired() async {
    final dir = _dir;
    if (dir == null) return;
    final cutoff = DateTime.now().subtract(const Duration(days: retentionDays));
    final cutoffName =
        'diag_${cutoff.year}${_pad(cutoff.month)}${_pad(cutoff.day)}.log';
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.log')) continue;
        final name = entity.uri.pathSegments.last;
        if (name.compareTo(cutoffName) < 0) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 文档目录解析（避免直接依赖 path_provider——由调用方注入更可测；
  /// 生产走 PlatformDispatcher 拿不到时降级）
  static Future<Directory> _documentsDir() async {
    // 应用支持目录：/data/user/0/<pkg>/files（Android）——
    // Directory.systemTemp 在真机也可写但会被系统清理，改用当前目录兜底
    final dir = Directory.current;
    final diag = Directory('${dir.path}/$dirName');
    if (!await diag.exists()) await diag.create(recursive: true);
    return diag;
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

/// 日志类别（查看页过滤 + 落盘前缀）
enum LogKind {
  general('INFO'),
  api('API'),
  crash('CRASH');

  const LogKind(this.label);
  final String label;
}

/// 单条日志
class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.kind,
    required this.message,
  });

  final DateTime timestamp;
  final LogKind kind;
  final String message;

  /// 落盘行格式：`2026-10-29T17:30:00 [API] API timeout HTTP 429 耗时1200ms`
  String toLine() =>
      '${timestamp.toIso8601String()} [${kind.label}] ${DiagnosticLog.sanitize(message)}\n';
}

/// 崩溃钩子安装（main 启动时调用一次）
///
/// - FlutterError.onError：Flutter 框架异常（build/layout 抛错）
/// - PlatformDispatcher.instance.onError：未捕获的 Dart 异常
/// 两者都先落盘再走原处理器（保留原有上报/打印行为）。
void installDiagnosticHooks() {
  final originalFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    DiagnosticLog.logCrash(
      details.exceptionAsString(),
      details.stack?.toString(),
    );
    originalFlutterError?.call(details);
  };
  final originalDispatcher = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    DiagnosticLog.logCrash(error.toString(), stack.toString());
    return originalDispatcher?.call(error, stack) ?? false;
  };
}
