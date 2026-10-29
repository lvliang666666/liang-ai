import 'dart:convert';

import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// 新批次内置工具（date_calc / unit_convert / base_convert / math_function /
/// random_number / random_pick / dice_flip / text_stats / uuid_generate /
/// base64_codec / hash_text）的行为测试。
///
/// 统一经 ToolRegistry.execute 走真实链路（参数 JSON 解析 + 异常转 isError）。
void main() {
  final registry = ToolRegistry()..registerAll(builtinTools);

  Future<ToolCallResult> call(String name, Map<String, dynamic> args) =>
      registry.execute(ToolCall(
        id: 'c',
        name: name,
        argumentsJson: args.isEmpty ? '{}' : jsonEncode(args),
      ));

  group('工具目录', () {
    test('注册表含全部 30 个内置工具', () {
      expect(registry.length, 30);
      expect(
        registry.names,
        containsAll([
          'get_current_time',
          'get_device_info',
          'date_calc',
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
        ]),
      );
    });
  });

  group('date_calc 日期计算', () {
    test('diff：两日期相差天数', () async {
      final r = await call('date_calc',
          {'op': 'diff', 'date': '2026-01-01', 'date2': '2026-01-31'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('30 天'));
    });

    test('diff：跨月跨年', () async {
      final r = await call('date_calc',
          {'op': 'diff', 'date': '2025-12-31', 'date2': '2026-01-01'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('1 天'));
    });

    test('diff：倒序为负数', () async {
      final r = await call('date_calc',
          {'op': 'diff', 'date': '2026-01-31', 'date2': '2026-01-01'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('-30 天'));
    });

    test('add：加天数带星期', () async {
      final r = await call('date_calc',
          {'op': 'add', 'date': '2026-10-20', 'offset': 10});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('2026-10-30'));
      expect(r.content, contains('星期'));
    });

    test('add：负数偏移', () async {
      final r = await call('date_calc',
          {'op': 'add', 'date': '2026-10-20', 'offset': -20});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('2026-09-30'));
    });

    test('weekday：星期几', () async {
      final r =
          await call('date_calc', {'op': 'weekday', 'date': '2026-10-20'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('星期二')); // 2026-10-20 是周二
    });

    test('错误：非法日期格式 / 不存在的日期 / 缺参数', () async {
      expect((await call('date_calc', {'op': 'weekday', 'date': '2026/10/20'}))
          .isError, isTrue);
      expect((await call('date_calc', {'op': 'weekday', 'date': '2026-02-30'}))
          .isError, isTrue);
      expect((await call('date_calc', {'op': 'diff', 'date': '2026-01-01'}))
          .isError, isTrue);
      expect((await call('date_calc', {'op': 'nope'})).isError, isTrue);
    });
  });

  group('unit_convert 单位换算', () {
    test('长度：km → mile', () async {
      final r = await call('unit_convert',
          {'category': 'length', 'value': 10, 'from': 'km', 'to': 'mile'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('6.213712'));
    });

    test('重量：kg → pound（别名 lb）', () async {
      final r1 = await call('unit_convert',
          {'category': 'weight', 'value': 1, 'from': 'kg', 'to': 'pound'});
      final r2 = await call('unit_convert',
          {'category': 'weight', 'value': 1, 'from': 'kg', 'to': 'lb'});
      expect(r1.isError, isFalse, reason: r1.content);
      expect(r2.isError, isFalse, reason: r2.content);
      expect(r1.content, r2.content);
      expect(r1.content, contains('2.204623'));
    });

    test('温度：C → F（含别名小写）', () async {
      final r = await call('unit_convert',
          {'category': 'temperature', 'value': 100, 'from': 'c', 'to': 'f'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('212'));
    });

    test('温度：K → C', () async {
      final r = await call('unit_convert',
          {'category': 'temperature', 'value': 273.15, 'from': 'K', 'to': 'C'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('0'));
    });

    test('数据大小：GB → MB', () async {
      final r = await call('unit_convert',
          {'category': 'data', 'value': 2, 'from': 'GB', 'to': 'MB'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('2048'));
    });

    test('速度：kmh → mps', () async {
      final r = await call('unit_convert',
          {'category': 'speed', 'value': 36, 'from': 'kmh', 'to': 'mps'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('10'));
    });

    test('市斤换算：kg → jin', () async {
      final r = await call('unit_convert',
          {'category': 'weight', 'value': 2, 'from': 'kg', 'to': 'jin'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('4'));
    });

    test('错误：未知类别 / 未知单位', () async {
      expect(
          (await call('unit_convert', {
            'category': 'volume',
            'value': 1,
            'from': 'l',
            'to': 'ml'
          }))
              .isError,
          isTrue);
      expect(
          (await call('unit_convert', {
            'category': 'length',
            'value': 1,
            'from': 'lightyear',
            'to': 'm'
          }))
              .isError,
          isTrue);
    });
  });

  group('base_convert 进制转换', () {
    test('二进制 → 十进制', () async {
      final r = await call('base_convert',
          {'value': '1010', 'from': 2, 'to': 10});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('= 10（10进制）'));
    });

    test('十六进制 → 十进制（大小写不敏感）', () async {
      final r1 = await call('base_convert', {'value': 'FF', 'from': 16, 'to': 10});
      final r2 = await call('base_convert', {'value': 'ff', 'from': 16, 'to': 10});
      expect(r1.isError, isFalse, reason: r1.content);
      expect(r1.content, contains('= 255（10进制）'));
      // 数值相同（回显用户原始输入，大小写保留）
      expect(r2.content, contains('= 255（10进制）'));
    });

    test('十进制 → 二进制', () async {
      final r = await call('base_convert', {'value': '255', 'from': 10, 'to': 2});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('= 11111111（2进制）'));
    });

    test('负数', () async {
      final r = await call('base_convert', {'value': '-1010', 'from': 2, 'to': 10});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('= -10（10进制）'));
    });

    test('大数不溢出（BigInt）', () async {
      final r = await call('base_convert',
          {'value': 'FFFFFFFFFFFFFFFFFFFF', 'from': 16, 'to': 10});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('1208925819614629174706175'));
    });

    test('零', () async {
      final r = await call('base_convert', {'value': '0', 'from': 10, 'to': 2});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('= 0（2进制）'));
    });

    test('错误：非法字符 / 进制越界', () async {
      expect(
          (await call('base_convert', {'value': '12', 'from': 2, 'to': 10}))
              .isError,
          isTrue); // '2' 不是二进制数字
      expect(
          (await call('base_convert', {'value': '10', 'from': 1, 'to': 10}))
              .isError,
          isTrue);
      expect(
          (await call('base_convert', {'value': '10', 'from': 10, 'to': 37}))
              .isError,
          isTrue);
    });
  });

  group('math_function 数学函数', () {
    test('sqrt / pow', () async {
      final r1 = await call('math_function', {'fn': 'sqrt', 'x': 144});
      expect(r1.isError, isFalse, reason: r1.content);
      expect(r1.content, contains('= 12'));

      final r2 = await call('math_function', {'fn': 'pow', 'x': 2, 'y': 10});
      expect(r2.isError, isFalse, reason: r2.content);
      expect(r2.content, contains('= 1024'));
    });

    test('三角函数（弧度）', () async {
      final r = await call('math_function', {'fn': 'sin', 'x': 0});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('= 0'));
    });

    test('round / floor / ceil / abs', () async {
      expect((await call('math_function', {'fn': 'round', 'x': 3.5})).content,
          contains('= 4'));
      expect((await call('math_function', {'fn': 'floor', 'x': 3.9})).content,
          contains('= 3'));
      expect((await call('math_function', {'fn': 'ceil', 'x': 3.1})).content,
          contains('= 4'));
      expect((await call('math_function', {'fn': 'abs', 'x': -5})).content,
          contains('= 5'));
    });

    test('错误：负数开方 / 域外 asin / 未知函数', () async {
      expect((await call('math_function', {'fn': 'sqrt', 'x': -1})).isError,
          isTrue);
      expect((await call('math_function', {'fn': 'asin', 'x': 2})).isError,
          isTrue);
      expect((await call('math_function', {'fn': 'foo', 'x': 1})).isError,
          isTrue);
    });
  });

  group('random_number 随机数', () {
    test('默认范围 1-100 单个', () async {
      final r = await call('random_number', {});
      expect(r.isError, isFalse, reason: r.content);
      final m = RegExp(r'(\d+)').firstMatch(r.content.split('：').last);
      expect(m, isNotNull);
      final v = int.parse(m!.group(1)!);
      expect(v, inInclusiveRange(1, 100));
    });

    test('指定范围与个数', () async {
      final r = await call('random_number', {'min': 1, 'max': 6, 'count': 5});
      expect(r.isError, isFalse, reason: r.content);
      final nums = r.content.split('：').last.split(', ').map(int.parse).toList();
      expect(nums.length, 5);
      for (final v in nums) {
        expect(v, inInclusiveRange(1, 6));
      }
    });

    test('unique 不重复', () async {
      final r = await call('random_number',
          {'min': 1, 'max': 10, 'count': 10, 'unique': true});
      expect(r.isError, isFalse, reason: r.content);
      final nums = r.content.split('：').last.split(', ').map(int.parse).toList();
      expect(nums.toSet().length, 10);
    });

    test('错误：min > max / unique 超范围', () async {
      expect((await call('random_number', {'min': 10, 'max': 1})).isError,
          isTrue);
      expect(
          (await call('random_number',
              {'min': 1, 'max': 5, 'count': 10, 'unique': true}))
              .isError,
          isTrue);
    });
  });

  group('random_pick 随机抽取', () {
    test('抽一个', () async {
      final r = await call('random_pick', {'items': 'A, B, C'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, startsWith('随机选中：'));
      expect('ABC'.split('').any(r.content.contains), isTrue);
    });

    test('抽多个', () async {
      final r = await call('random_pick',
          {'items': 'A,B,C,D,E', 'count': 3});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('随机选中 3 项'));
    });

    test('shuffle 打乱全部', () async {
      final r = await call('random_pick',
          {'items': '1,2,3,4,5', 'shuffle': true});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('随机排序'));
      // 打乱后仍含全部元素
      for (final c in ['1', '2', '3', '4', '5']) {
        expect(r.content.contains(c), isTrue);
      }
    });

    test('错误：空列表', () async {
      expect((await call('random_pick', {'items': ' , '})).isError, isTrue);
    });
  });

  group('dice_flip 骰子硬币', () {
    test('默认六面骰', () async {
      final r = await call('dice_flip', {'mode': 'dice'});
      expect(r.isError, isFalse, reason: r.content);
      final v = int.parse(r.content.split('：').last);
      expect(v, inInclusiveRange(1, 6));
    });

    test('多骰子带总和', () async {
      final r = await call('dice_flip', {'mode': 'dice', 'count': 3});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('总和'));
    });

    test('20 面骰范围', () async {
      final r = await call('dice_flip', {'mode': 'dice', 'sides': 20});
      expect(r.isError, isFalse, reason: r.content);
      final v = int.parse(r.content.split('：').last);
      expect(v, inInclusiveRange(1, 20));
    });

    test('抛硬币', () async {
      final r = await call('dice_flip', {'mode': 'coin'});
      expect(r.isError, isFalse, reason: r.content);
      final isHeads = r.content.contains('正面');
      final isTails = r.content.contains('反面');
      expect(isHeads || isTails, isTrue, reason: r.content);
    });

    test('多次抛硬币统计', () async {
      final r = await call('dice_flip', {'mode': 'coin', 'count': 10});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('正面'));
      expect(r.content, contains('反面'));
    });
  });

  group('text_stats 文本统计', () {
    test('中英混合统计', () async {
      final r = await call('text_stats', {'text': '你好世界 hello world 123'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('总字符数：20'));
      expect(r.content, contains('中文字符：4'));
      expect(r.content, contains('英文单词：3')); // hello / world / 123
      expect(r.content, contains('数字字符：3'));
      expect(r.content, contains('行数：1'));
    });

    test('多行文本行数', () async {
      final r = await call('text_stats', {'text': 'a\nb\nc'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('行数：3'));
    });

    test('UTF-8 字节数（中文 3 字节）', () async {
      final r = await call('text_stats', {'text': '中文'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('UTF-8 字节：6'));
    });

    test('错误：空文本', () async {
      expect((await call('text_stats', {'text': ''})).isError, isTrue);
    });
  });

  group('uuid_generate', () {
    test('默认生成 1 个，v4 格式', () async {
      final r = await call('uuid_generate', {});
      expect(r.isError, isFalse, reason: r.content);
      expect(
        r.content,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('多个生成', () async {
      final r = await call('uuid_generate', {'count': 3});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content.split('\n'), hasLength(3));
      // 互不相同
      final lines = r.content.split('\n').toSet();
      expect(lines, hasLength(3));
    });

    test('大写', () async {
      final r = await call('uuid_generate', {'uppercase': true});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, matches(RegExp(r'^[0-9A-F]{8}-')));
    });
  });

  group('base64_codec', () {
    test('编码', () async {
      final r = await call('base64_codec', {'mode': 'encode', 'text': 'hello'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('aGVsbG8='));
    });

    test('编码中文', () async {
      final r = await call('base64_codec', {'mode': 'encode', 'text': '中'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('5Lit'));
    });

    test('解码', () async {
      final r =
          await call('base64_codec', {'mode': 'decode', 'text': 'aGVsbG8='});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('hello'));
    });

    test('解码非法 Base64 报错', () async {
      expect(
          (await call('base64_codec', {'mode': 'decode', 'text': '!!!'}))
              .isError,
          isTrue);
    });

    test('默认模式为编码', () async {
      final r = await call('base64_codec', {'text': 'abc'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('YWJj'));
    });
  });

  group('hash_text', () {
    test('MD5 已知值', () async {
      final r = await call('hash_text', {'text': 'abc'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('900150983cd24fb0d6963f7d28e17f72'));
    });

    test('SHA-256 已知值', () async {
      final r = await call('hash_text',
          {'text': 'abc', 'algorithm': 'sha256'});
      expect(r.isError, isFalse, reason: r.content);
      expect(
        r.content,
        contains(
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'),
      );
    });

    test('多算法一次输出', () async {
      final r = await call('hash_text',
          {'text': 'abc', 'algorithm': 'md5, sha1, sha256'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content.split('\n'), hasLength(3));
      expect(r.content, contains('MD5:'));
      expect(r.content, contains('SHA-1:'));
      expect(r.content, contains('SHA-256:'));
    });

    test('错误：未知算法', () async {
      expect(
          (await call('hash_text', {'text': 'x', 'algorithm': 'crc32'}))
              .isError,
          isTrue);
    });
  });
}
