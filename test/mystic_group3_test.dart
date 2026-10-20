import 'dart:convert';

import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/mystic/numerology_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// 玄学工具组 3：shuzi / xingming / dice_iching / peach_blossom
void main() {
  final registry = ToolRegistry()
    ..register(const ShuZiTool())
    ..register(const XingMingTool())
    ..register(const DiceIchingTool())
    ..register(const PeachBlossomTool());

  Future<String> call(String name, Map<String, dynamic> args) async {
    final r = await registry.execute(ToolCall(
      id: 'c',
      name: name,
      argumentsJson: args.isEmpty ? '{}' : jsonEncode(args),
    ));
    return r.content;
  }

  group('shuzi 数字能量', () {
    test('手机号分析结构完整', () async {
      final r = await call('shuzi', {'number': '13812345678'});
      expect(r, contains('13812345678'));
      expect(r, contains('总格'));
      expect(r.contains('吉') || r.contains('凶'), isTrue);
      expect(r, contains('尾数拆解'));
    });

    test('总格归约：全 9 串', () async {
      // 9+9+9=27 → 27 在 1-81 内直接用
      final r = await call('shuzi', {'number': '999'});
      expect(r, contains('27'));
    });

    test('错误路径：空串/非数字', () async {
      final r1 = await registry.execute(const ToolCall(
          id: 'c', name: 'shuzi', argumentsJson: '{"number":""}'));
      expect(r1.isError, isTrue);
      final r2 = await registry.execute(const ToolCall(
          id: 'c', name: 'shuzi', argumentsJson: '{"number":"12ab"}'));
      expect(r2.isError, isTrue);
      final r3 = await registry.execute(
          const ToolCall(id: 'c', name: 'shuzi', argumentsJson: '{}'));
      expect(r3.isError, isTrue);
    });
  });

  group('xingming 姓名五格', () {
    test('李明：天格 8 人格 15', () async {
      final r = await call('xingming', {'name': '李明'});
      expect(r, contains('李=7'));
      expect(r, contains('明=8'));
      expect(r, contains('天格：8'));
      expect(r, contains('人格：15'));
      expect(r, contains('总格：15'));
    });

    test('三字名：张伟强', () async {
      final r = await call('xingming', {'name': '张伟强'});
      expect(r, contains('张=11'));
      expect(r, contains('伟=11'));
      expect(r, contains('强=12'));
      expect(r, contains('总格：34'));
    });

    test('错误路径：单字/英文/缺参', () async {
      final r1 = await registry.execute(const ToolCall(
          id: 'c', name: 'xingming', argumentsJson: '{"name":"李"}'));
      expect(r1.isError, isTrue);
      final r2 = await registry.execute(const ToolCall(
          id: 'c', name: 'xingming', argumentsJson: '{"name":"Tom"}'));
      expect(r2.isError, isTrue);
      final r3 = await registry.execute(
          const ToolCall(id: 'c', name: 'xingming', argumentsJson: '{}'));
      expect(r3.isError, isTrue);
    });
  });

  group('dice_iching 六爻起卦', () {
    test('卦象结构完整：六爻记录 + 本卦', () async {
      final r = await call('dice_iching', {'topic': '跳槽'});
      expect(r, contains('所问：跳槽'));
      expect(r, contains('第1爻'));
      expect(r, contains('第6爻'));
      expect(r, contains('本卦'));
      // 卦象符号
      expect(r.contains('━━━') || r.contains('━ ━'), isTrue);
    });

    test('多次起卦有随机性', () async {
      final results = <String>{};
      for (var i = 0; i < 8; i++) {
        results.add(await call('dice_iching', {}));
      }
      expect(results.length, greaterThan(1));
    });
  });

  group('peach_blossom 桃花测算', () {
    test('1995-06-15：亥年 → 桃花子', () async {
      final r = await call('peach_blossom', {'date': '1995-06-15'});
      expect(r, contains('年支：亥'));
      expect(r, contains('桃花星：子'));
      expect(r, contains('桃花方位'));
      expect(r, contains('桃花旺年'));
    });

    test('2026-02-17 马年 → 桃花卯', () async {
      final r = await call('peach_blossom', {'date': '2026-02-17'});
      expect(r, contains('年支：午'));
      expect(r, contains('桃花星：卯'));
    });

    test('错误路径：坏格式/缺参', () async {
      final r1 = await registry.execute(const ToolCall(
          id: 'c',
          name: 'peach_blossom',
          argumentsJson: '{"date":"1995/6/15"}'));
      expect(r1.isError, isTrue);
      final r2 = await registry.execute(
          const ToolCall(id: 'c', name: 'peach_blossom', argumentsJson: '{}'));
      expect(r2.isError, isTrue);
    });
  });
}
