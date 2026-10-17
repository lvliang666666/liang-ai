import 'dart:convert';

import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
