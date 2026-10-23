import 'dart:convert';

import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';


/// 构造单工具分片的 delta JSON（不含 data: 前缀与外层包裹）
String _tcJson(int index, String? id, String? name, String args) {
  final idPart = id == null ? '' : '"id":"$id",';
  final namePart = name == null ? '' : '"name":"$name",';
  final escaped = args.replaceAll('"', '\\"');
  return '{"choices":[{"delta":{"tool_calls":[{"index":$index,$idPart"type":"function","function":{$namePart"arguments":"$escaped"}}]}}]}';
}

/// 构造单个 tool_call 对象片段（不含 delta/choices 包裹）
String _tcFragment(int index, String? id, String? name, String args) {
  final idPart = id == null ? '' : '"id":"$id",';
  final namePart = name == null ? '' : '"name":"$name",';
  final escaped = args.replaceAll('"', '\\"');
  return '{"index":$index,$idPart"type":"function","function":{$namePart"arguments":"$escaped"}}';
}

/// 构造双工具并行分片 JSON
String _twoToolsJson() {
  return '{"choices":[{"delta":{"tool_calls":['
      '{"index":0,"id":"a","type":"function","function":{"name":"f1","arguments":""}},'
      '{"index":1,"id":"b","type":"function","function":{"name":"f2","arguments":""}}'
      ']}}]}';
}

void main() {
  group('SseParser', () {
    test('单 chunk 完整流：content 增量 + [DONE]', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"content":"你"}}]}\n'
        'data: {"choices":[{"delta":{"content":"好"}}]}\n'
        'data: [DONE]\n',
      );

      expect(events.length, 3);
      expect((events[0] as SseDeltaContent).text, '你');
      expect((events[1] as SseDeltaContent).text, '好');
      expect(events[2], isA<SseDone>());
      expect(parser.isDone, isTrue);
    });

    test('reasoning 与 content 分流', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"reasoning":"思考中"}}]}\n'
        'data: {"choices":[{"delta":{"content":"答案"}}]}\n',
      );

      expect(events.length, 2);
      expect((events[0] as SseDeltaReasoning).text, '思考中');
      expect((events[1] as SseDeltaContent).text, '答案');
    });

    test('跨 chunk 行边界缓冲（一行被切成两半）', () {
      final parser = SseParser();
      final line = 'data: {"choices":[{"delta":{"content":"完整"}}]}\n';

      final e1 = parser.addChunk(line.substring(0, 20));
      expect(e1, isEmpty); // 行未完成，无事件

      final e2 = parser.addChunk(line.substring(20));
      expect(e2.length, 1);
      expect((e2[0] as SseDeltaContent).text, '完整');
    });

    test('跨 chunk 的 UTF-8 多字节字符边界由上层解码器处理，这里验证拼接正确', () {
      final parser = SseParser();
      final line =
          'data: {"choices":[{"delta":{"content":"中文测试"}}]}\n';
      final bytes = utf8.encode(line);
      // 模拟 utf8.decoder 已正确拼接后按任意位置切分
      final s = utf8.decode(bytes);
      final e1 = parser.addChunk(s.substring(0, 10));
      final e2 = parser.addChunk(s.substring(10));
      final all = [...e1, ...e2];
      expect(all.length, 1);
      expect((all[0] as SseDeltaContent).text, '中文测试');
    });

    test('心跳注释行与空行被跳过', () {
      final parser = SseParser();
      final events = parser.addChunk(
        ': keep-alive\n'
        '\n'
        'data: {"choices":[{"delta":{"content":"hi"}}]}\n'
        '\n',
      );
      expect(events.length, 1);
      expect((events[0] as SseDeltaContent).text, 'hi');
    });

    test('坏 JSON 静默跳过，不影响后续行', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {broken json\n'
        'data: {"choices":[{"delta":{"content":"ok"}}]}\n',
      );
      expect(events.length, 1);
      expect((events[0] as SseDeltaContent).text, 'ok');
    });

    test('finish_reason 非空视为结束（即使无 [DONE]）', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}\n',
      );
      expect(events.length, 2);
      expect(events[0], isA<SseDeltaContent>());
      expect(events[1], isA<SseDone>());
    });

    test('服务端错误 JSON 输出 SseError', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"error":{"message":"消费者密钥不存在"}}\n',
      );
      expect(events.length, 1);
      final err = events[0] as SseError;
      expect(err.message, '消费者密钥不存在');
      expect(parser.isDone, isTrue);
    });

    test('done 后再喂 chunk 无事件', () {
      final parser = SseParser();
      parser.addChunk('data: [DONE]\n');
      expect(parser.addChunk('data: {"choices":[]}\n'), isEmpty);
    });

    test('flush 处理无换行结尾的残留行', () {
      final parser = SseParser();
      final e1 = parser.addChunk(
          'data: {"choices":[{"delta":{"content":"尾行"}}]}'); // 无 \n
      expect(e1, isEmpty);
      final e2 = parser.flush();
      expect(e2.length, 1);
      expect((e2[0] as SseDeltaContent).text, '尾行');
    });

    test('CRLF 行尾正确处理', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"content":"crlf"}}]}\r\n'
        'data: [DONE]\r\n',
      );
      expect(events.length, 2);
      expect((events[0] as SseDeltaContent).text, 'crlf');
      expect(events[1], isA<SseDone>());
    });

    test('reasoning_content 备用字段名也支持', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"reasoning_content":"思考"}}]}\n',
      );
      expect(events.length, 1);
      expect((events[0] as SseDeltaReasoning).text, '思考');
    });
  });
  group('SseParser tool_calls 解析', () {
    test('首片带 id/name，arguments 为空串', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_current_time","arguments":""}}]}}]}\n',
      );
      expect(events.length, 1);
      final tc = events[0] as SseToolCallDelta;
      expect(tc.index, 0);
      expect(tc.id, 'call_1');
      expect(tc.name, 'get_current_time');
      expect(tc.argumentsFragment, '');
    });
  });

  group('SseParser tool_calls 分片与结束', () {
    test('后续片只带 arguments 增量（无 id/name）', () {
      final parser = SseParser();
      final line1 = 'data: ${_tcJson(0, null, null, '{"city":"北')}\n';
      final line2 = 'data: ${_tcJson(0, null, null, '京')}\n';
      final events = [...parser.addChunk(line1), ...parser.addChunk(line2)];
      expect(events.length, 2);
      final t1 = events[0] as SseToolCallDelta;
      final t2 = events[1] as SseToolCallDelta;
      expect(t1.id, isNull);
      expect(t1.name, isNull);
      expect(t1.argumentsFragment, '{"city":"北');
      expect(t2.argumentsFragment, '京');
    });

    test('多工具并行调用 index 交错透传', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: ${_twoToolsJson()}\n',
      );
      expect(events.length, 2);
      expect((events[0] as SseToolCallDelta).index, 0);
      expect((events[1] as SseToolCallDelta).index, 1);
      expect((events[0] as SseToolCallDelta).name, 'f1');
      expect((events[1] as SseToolCallDelta).name, 'f2');
    });

    test('finish_reason=tool_calls 发出 SseToolCallsFinished 且不置 done', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n',
      );
      expect(events.length, 1);
      expect(events[0], isA<SseToolCallsFinished>());
      expect(parser.isDone, isFalse);
    });

    test('tool_calls 轮不再误发 SseDone', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"tool_calls":['
            '${_tcFragment(0, 'c1', 'f', '{}')}'
            ']},"finish_reason":"tool_calls"}]}\n',
      );
      expect(events.whereType<SseDone>(), isEmpty);
      expect(events.whereType<SseToolCallDelta>(), hasLength(1));
      expect(events.whereType<SseToolCallsFinished>(), hasLength(1));
    });

    test('tool_calls 与 content 同片共存（模型边说边调工具）', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"content":"让我查一下","tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"f","arguments":""}}]}}]}\n',
      );
      expect(events.length, 2);
      expect((events[0] as SseDeltaContent).text, '让我查一下');
      expect(events[1], isA<SseToolCallDelta>());
    });
  });

  group('SseParser usage 帧（F3 Token 水位）', () {
    test('usage-only 末帧（choices 空数组）发出 SseUsage', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":45}}\n',
      );
      expect(events.length, 1);
      final usage = events[0] as SseUsage;
      expect(usage.promptTokens, 120);
      expect(usage.completionTokens, 45);
      expect(parser.isDone, isFalse); // usage 帧本身不结束流，等 [DONE]
    });

    test('usage 帧后跟 [DONE]：两事件顺序输出', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}\n'
        'data: [DONE]\n',
      );
      expect(events.length, 2);
      expect(events[0], isA<SseUsage>());
      expect(events[1], isA<SseDone>());
      expect(parser.isDone, isTrue);
    });

    test('usage 与 choices 同帧共存：usage + delta 事件都发出', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}],'
        '"usage":{"prompt_tokens":7,"completion_tokens":3}}\n',
      );
      expect(events.whereType<SseUsage>(), hasLength(1));
      expect(events.whereType<SseDeltaContent>(), hasLength(1));
      expect(events.whereType<SseDone>(), hasLength(1));
    });

    test('无 usage 字段：行为与旧版一致（不产生 SseUsage）', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"content":"hi"}}]}\n',
      );
      expect(events.whereType<SseUsage>(), isEmpty);
      expect(events.whereType<SseDeltaContent>(), hasLength(1));
    });

    test('usage 字段类型异常（非 int）：静默跳过不崩溃', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[],"usage":{"prompt_tokens":"abc"}}\n',
      );
      expect(events, isEmpty);
    });

    test('完整流：content → usage → [DONE]（vLLM 真实时序）', () {
      final parser = SseParser();
      final events = parser.addChunk(
        'data: {"choices":[{"delta":{"content":"你"}}]}\n'
        'data: {"choices":[{"delta":{"content":"好"}}]}\n'
        'data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":2}}\n'
        'data: [DONE]\n',
      );
      expect(events.length, 4);
      expect((events[0] as SseDeltaContent).text, '你');
      expect((events[1] as SseDeltaContent).text, '好');
      final usage = events[2] as SseUsage;
      expect(usage.promptTokens, 12);
      expect(usage.completionTokens, 2);
      expect(events[3], isA<SseDone>());
    });
  });
}
