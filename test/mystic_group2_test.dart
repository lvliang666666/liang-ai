import 'dart:convert';

import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/mystic/divination_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// 玄学工具组 2：huangli / guanyin / tarot / zhougong
void main() {
  final registry = ToolRegistry()
    ..register(const HuangLiTool())
    ..register(const GuanYinTool())
    ..register(const TarotTool())
    ..register(const ZhouGongTool());

  Future<ToolCallResult> call(String name, Map<String, dynamic> args) =>
      registry.execute(ToolCall(
        id: 'c',
        name: name,
        argumentsJson: args.isEmpty ? '{}' : jsonEncode(args),
      ));

  group('huangli 黄历', () {
    test('指定日期输出农历与宜忌', () async {
      final r = (await call('huangli', {'date': '2026-02-17'})).content;
      expect(r, contains('2026 年 2 月 17 日'));
      expect(r, contains('农历'));
      expect(r, contains('建除十二神'));
      expect(r, contains('宜'));
      expect(r, contains('忌'));
    });

    test('不传日期默认今天不报错', () async {
      final r = await call('huangli', {});
      expect(r.isError, isFalse);
      expect(r.content, contains('黄历'));
    });

    test('坏日期报错', () async {
      final r = await call('huangli', {'date': '2026-13-40'});
      expect(r.isError, isTrue);
    });
  });

  group('guanyin 观音灵签', () {
    test('签号在 1-100，含吉凶等级', () async {
      final r = (await call('guanyin', {'topic': '事业'})).content;
      expect(r, contains('所问：事业'));
      final m = RegExp(r'第 (\d{2}) 签').firstMatch(r);
      expect(m, isNotNull);
      final n = int.parse(m!.group(1)!);
      expect(n, inInclusiveRange(1, 100));
      final hasLevel = ['上上签', '上签', '中签', '下签', '下下签']
          .any(r.contains);
      expect(hasLevel, isTrue);
      expect(r, contains('签题'));
    });

    test('吉凶等级分布边界', () {
      expect(GuanYinTool.fortuneLevel(1), '上上签');
      expect(GuanYinTool.fortuneLevel(12), '上上签');
      expect(GuanYinTool.fortuneLevel(13), '上签');
      expect(GuanYinTool.fortuneLevel(72), '中签');
      expect(GuanYinTool.fortuneLevel(73), '下签');
      expect(GuanYinTool.fortuneLevel(93), '下下签');
      expect(GuanYinTool.fortuneLevel(100), '下下签');
    });

    test('多次摇签结果有随机性', () async {
      final results = <String>{};
      for (var i = 0; i < 10; i++) {
        final r = await call('guanyin', {});
        results.add(r.content);
      }
      // 100 种签号，10 次全同概率极低
      expect(results.length, greaterThan(1));
    });
  });

  group('tarot 塔罗牌', () {
    test('默认抽 3 张，含正逆位', () async {
      final r = (await call('tarot', {'topic': '事业'})).content;
      expect(r, contains('牌阵主题：事业'));
      expect(r, contains('第 1 张'));
      expect(r, contains('第 3 张'));
      expect(r, isNot(contains('第 4 张')));
      expect(r.contains('正位') || r.contains('逆位'), isTrue);
    });

    test('count 参数控制张数', () async {
      final r = (await call('tarot', {'count': 1})).content;
      expect(r, contains('第 1 张'));
      expect(r, isNot(contains('第 2 张')));
    });

    test('大阿卡纳牌义在表中', () async {
      final r = (await call('tarot', {'count': 10})).content;
      // 10 张里大概率含大阿卡纳，验证格式
      expect(RegExp(r'第 \d+ 张：.+(正位|逆位)').allMatches(r).length, 10);
    });
  });

  group('zhougong 周公解梦', () {
    test('精确词条：掉牙', () async {
      final r = (await call('zhougong', {'dream': '掉牙'})).content;
      expect(r, contains('牙齿脱落'));
    });

    test('多关键词逗号分隔', () async {
      final r = (await call('zhougong', {'dream': '蛇,水'})).content;
      expect(r, contains('蛇'));
      expect(r, contains('水'));
    });

    test('未收录词条给提示', () async {
      final r = (await call('zhougong', {'dream': 'xyz不存在的梦'})).content;
      expect(r, contains('未收录'));
      expect(r, contains('试试常见词'));
    });

    test('缺参数报错', () async {
      final r = await call('zhougong', {});
      expect(r.isError, isTrue);
    });
  });
}
