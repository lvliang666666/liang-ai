import 'dart:convert';

import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试用工具
class EchoTool extends ToolHandler {
  const EchoTool();
  @override
  String get name => 'echo';
  @override
  String get description => '原样返回输入';
  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {'text': {'type': 'string'}},
      };
  @override
  Future<String> execute(Map<String, dynamic> arguments) async =>
      arguments['text'] as String? ?? '';
}

class FailTool extends ToolHandler {
  const FailTool();
  @override
  String get name => 'fail';
  @override
  String get description => '总是失败';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object'};
  @override
  Future<String> execute(Map<String, dynamic> arguments) async =>
      throw StateError('故意失败');
}

void main() {
  group('ToolCall 模型', () {
    test('toJson/fromJson 往返', () {
      const call = ToolCall(
          id: 'call_1', name: 'get_current_time', argumentsJson: '{"tz":"Asia/Shanghai"}');
      final restored = ToolCall.fromJson(call.toJson());
      expect(restored.id, 'call_1');
      expect(restored.name, 'get_current_time');
      expect(restored.argumentsJson, '{"tz":"Asia/Shanghai"}');
    });

    test('arguments 坏 JSON 容错返回空 Map', () {
      const call = ToolCall(id: 'c', name: 'n', argumentsJson: '{broken');
      expect(call.arguments, isEmpty);
      expect(const ToolCall(id: 'c', name: 'n').arguments, isEmpty);
    });

    test('argumentsPreview 截断 40 字符', () {
      final long = jsonEncode({'text': 'x' * 100});
      final call = ToolCall(id: 'c', name: 'n', argumentsJson: long);
      expect(call.argumentsPreview.length, 41); // 40 + 省略号
      expect(call.argumentsPreview.endsWith('…'), isTrue);
    });

    test('encodeList/decodeList 往返 + 脏数据容错', () {
      const calls = [
        ToolCall(id: 'a', name: 'f1', argumentsJson: '{"x":1}'),
        ToolCall(id: 'b', name: 'f2'),
      ];
      final encoded = ToolCall.encodeList(calls);
      final decoded = ToolCall.decodeList(encoded);
      expect(decoded.length, 2);
      expect(decoded[0].name, 'f1');
      expect(decoded[1].argumentsJson, isEmpty);
      // 脏数据
      expect(ToolCall.decodeList('not-json'), isEmpty);
      expect(ToolCall.decodeList(null), isEmpty);
      expect(ToolCall.decodeList(''), isEmpty);
    });
  });

  group('ToolRegistry', () {
    test('toOpenAiTools 生成 OpenAI 格式', () {
      final registry = ToolRegistry()..register(const EchoTool());
      final tools = registry.toOpenAiTools();
      expect(tools.length, 1);
      expect(tools[0]['type'], 'function');
      final fn = tools[0]['function'] as Map<String, dynamic>;
      expect(fn['name'], 'echo');
      expect(fn['description'], '原样返回输入');
      expect((fn['parameters'] as Map)['type'], 'object');
    });

    test('execute 正常路径', () async {
      final registry = ToolRegistry()..register(const EchoTool());
      final result = await registry.execute(
          const ToolCall(id: 'c1', name: 'echo', argumentsJson: '{"text":"你好"}'));
      expect(result.isError, isFalse);
      expect(result.content, '你好');
      expect(result.callId, 'c1');
    });

    test('execute 未知工具返回 isError 结果（不抛异常）', () async {
      final registry = ToolRegistry();
      final result = await registry
          .execute(const ToolCall(id: 'c1', name: 'nope', argumentsJson: '{}'));
      expect(result.isError, isTrue);
      expect(result.content, contains('未知工具'));
    });

    test('execute 工具抛异常转为 isError 结果', () async {
      final registry = ToolRegistry()..register(const FailTool());
      final result = await registry
          .execute(const ToolCall(id: 'c1', name: 'fail', argumentsJson: '{}'));
      expect(result.isError, isTrue);
      expect(result.content, contains('故意失败'));
    });

    test('executeAll 批量执行 + 结果截断', () async {
      final registry = ToolRegistry()
        ..register(const EchoTool())
        ..register(const FailTool());
      final results = await registry.executeAll([
        const ToolCall(id: 'a', name: 'echo', argumentsJson: '{"text":"hi"}'),
        const ToolCall(id: 'b', name: 'fail', argumentsJson: '{}'),
        ToolCall(id: 'c', name: 'echo', argumentsJson: '{"text":"${'y' * 5000}"}'),
      ], maxChars: 100);
      expect(results.length, 3);
      expect(results[0].isError, isFalse);
      expect(results[1].isError, isTrue);
      expect(results[2].content.length, lessThan(120));
      expect(results[2].content, contains('已截断'));
    });

    test('toolResultToApiMessage 生成 role=tool 格式', () {
      final msg = toolResultToApiMessage(
          const ToolCallResult(callId: 'c1', content: '结果文本'));
      expect(msg['role'], 'tool');
      expect(msg['tool_call_id'], 'c1');
      expect(msg['content'], '结果文本');
    });
  });

  group('内置工具', () {
    test('注册表含全部内置工具', () {
      final registry = ToolRegistry()..registerAll(builtinTools);
      expect(registry.length, 29);
      expect(
          registry.names,
          containsAll([
            'get_current_time',
            'get_device_info',
            'calculate',
            'bazi',
            'wuxing',
            'zodiac',
            'huangli',
            'guanyin',
            'tarot',
            'zhougong',
            'shuzi',
            'xingming',
            'dice_iching',
            'peach_blossom',
            'date_calc',
            'unit_convert',
            'base_convert',
            'math_function',
            'random_number',
            'random_pick',
            'dice_flip',
            'text_stats',
            'uuid_generate',
            'base64_codec',
            'hash_text',
            'memory_save',
            'memory_search',
            'memory_forget',
          ]));
    });

    test('get_current_time 返回日期时间格式', () async {
      final registry = ToolRegistry()..register(const GetCurrentTimeTool());
      final result = await registry
          .execute(const ToolCall(id: 'c', name: 'get_current_time', argumentsJson: '{}'));
      expect(result.isError, isFalse);
      expect(result.content, contains('当前时间'));
      expect(result.content, contains('星期'));
      expect(result.content, matches(RegExp(r'\d{4}年\d{1,2}月\d{1,2}日')));
    });

    test('calculate 四则运算 + 括号 + 优先级', () async {
      final registry = ToolRegistry()..register(const CalculateTool());
      Future<String> calc(String expr) async {
        final r = await registry.execute(ToolCall(
            id: 'c',
            name: 'calculate',
            argumentsJson: jsonEncode({'expression': expr})));
        expect(r.isError, isFalse, reason: r.content);
        return r.content;
      }

      expect(await calc('1 + 2 * 3'), contains('= 7'));
      expect(await calc('(4 + 5) / 3'), contains('= 3'));
      expect(await calc('10 % 3'), contains('= 1'));
      expect(await calc('-5 + 10'), contains('= 5'));
      expect(await calc('2 * (3 + 4) - 1'), contains('= 13'));
      expect(await calc('1 / 3'), contains('= 0.3333'));
    });

    test('calculate 错误处理：除零/坏表达式/缺参数', () async {
      final registry = ToolRegistry()..register(const CalculateTool());
      Future<ToolCallResult> calc(String? expr) async {
        return registry.execute(ToolCall(
            id: 'c',
            name: 'calculate',
            argumentsJson: expr == null
                ? '{}'
                : jsonEncode({'expression': expr})));
      }

      expect((await calc('1 / 0')).isError, isTrue);
      expect((await calc('1 +')).isError, isTrue);
      expect((await calc('abc')).isError, isTrue);
      expect((await calc(null)).isError, isTrue);
    });

    test('get_device_info 在测试环境不崩溃', () async {
      final registry = ToolRegistry()..register(const GetDeviceInfoTool());
      final result = await registry
          .execute(const ToolCall(id: 'c', name: 'get_device_info', argumentsJson: '{}'));
      // 测试环境（非 Android）应返回平台提示而非崩溃
      expect(result.isError, isFalse);
      expect(result.content, isNotEmpty);
    });
  });
}
