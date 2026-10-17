import 'dart:convert';

/// SSE 流事件
sealed class SseEvent {
  const SseEvent();
}

/// 正文增量
class SseDeltaContent extends SseEvent {
  const SseDeltaContent(this.text);
  final String text;
}

/// 思考过程增量
class SseDeltaReasoning extends SseEvent {
  const SseDeltaReasoning(this.text);
  final String text;
}

/// 流正常结束（收到 [DONE]）
class SseDone extends SseEvent {
  const SseDone();
}

/// 流错误（服务端返回错误 JSON）
class SseError extends SseEvent {
  const SseError(this.message);
  final String message;
}

/// SSE 解析器（纯 Dart，可单测）
///
/// 处理跨 chunk 的行边界缓冲、`data: ` 前缀、`[DONE]` 终止标记、
/// 心跳注释行（`: keep-alive`）、坏 JSON 容错（静默跳过）。
class SseParser {
  final StringBuffer _buffer = StringBuffer();
  bool _done = false;

  bool get isDone => _done;

  /// 喂入一段文本（UTF-8 解码后的字符串），返回解析出的事件列表
  List<SseEvent> addChunk(String text) {
    if (_done || text.isEmpty) return const [];
    _buffer.write(text);
    return _drain();
  }

  /// 流结束时调用，处理缓冲区中残留的最后一行（无换行符结尾）
  List<SseEvent> flush() {
    if (_done || _buffer.isEmpty) return const [];
    final rest = _buffer.toString();
    _buffer.clear();
    return _parseLine(rest);
  }

  List<SseEvent> _drain() {
    final events = <SseEvent>[];
    final text = _buffer.toString();
    var start = 0;
    while (true) {
      final idx = text.indexOf('\n', start);
      if (idx < 0) break;
      final line =
          idx > start && text.codeUnitAt(idx - 1) == 13 // \r\n
              ? text.substring(start, idx - 1)
              : text.substring(start, idx);
      events.addAll(_parseLine(line));
      start = idx + 1;
    }
    // 保留未完成的部分
    if (start < text.length) {
      final rest = text.substring(start);
      _buffer
        ..clear()
        ..write(rest);
    } else {
      _buffer.clear();
    }
    return events;
  }

  List<SseEvent> _parseLine(String line) {
    if (_done) return const [];
    final trimmed = line.trim();

    // 空行 / 心跳注释行
    if (trimmed.isEmpty || trimmed.startsWith(':')) return const [];

    // data: 前缀
    if (!trimmed.startsWith('data:')) return const [];
    var payload = trimmed.substring(5);
    if (payload.startsWith(' ')) payload = payload.substring(1);

    // 终止标记
    if (payload == '[DONE]') {
      _done = true;
      return const [SseDone()];
    }

    // JSON 解析（坏数据静默跳过）
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return const [];
      json = decoded;
    } catch (_) {
      return const [];
    }

    // 服务端错误响应（非流式错误体）
    if (json['error'] != null) {
      final err = json['error'];
      final msg = err is Map<String, dynamic>
          ? (err['message'] as String? ?? err.toString())
          : err.toString();
      _done = true;
      return [SseError(msg)];
    }

    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return const [];
    final choice = choices[0];
    if (choice is! Map<String, dynamic>) return const [];

    // finish_reason 非空也视为结束（有些实现不发 [DONE]）
    final finish = choice['finish_reason'];

    final delta = choice['delta'];
    final events = <SseEvent>[];
    if (delta is Map<String, dynamic>) {
      final reasoning = delta['reasoning'] ?? delta['reasoning_content'];
      if (reasoning is String && reasoning.isNotEmpty) {
        events.add(SseDeltaReasoning(reasoning));
      }
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        events.add(SseDeltaContent(content));
      }
    }

    if (finish != null) {
      _done = true;
      events.add(const SseDone());
    }
    return events;
  }
}
