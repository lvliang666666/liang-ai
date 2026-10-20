import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/mystic/bazi_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// 玄学工具组 1：lunar_calendar / bazi / wuxing / zodiac
void main() {
  final registry = ToolRegistry()
    ..register(const LunarCalendarTool())
    ..register(const BaziTool())
    ..register(const WuXingTool())
    ..register(const ZodiacTool());

  // 便捷调用（正确 JSON）
  Future<String> call(String name, Map<String, dynamic> args) async {
    final json = args.isEmpty
        ? '{}'
        : '{' +
            args.entries
                .map((e) =>
                    '"${e.key}":"${e.value.toString().replaceAll('"', '')}"')
                .join(',') +
            '}';
    final r = await registry.execute(
        ToolCall(id: 'c', name: name, argumentsJson: json));
    return r.content;
  }

  group('lunar_calendar 农历转换', () {
    test('公历转农历：2026-02-17 春节', () async {
      final r = await registry.execute(const ToolCall(
          id: 'c',
          name: 'lunar_calendar',
          argumentsJson: '{"date":"2026-02-17"}'));
      expect(r.isError, isFalse);
      expect(r.content, contains('正月初一'));
      expect(r.content, contains('丙午'));
      expect(r.content, contains('马'));
    });

    test('农历转公历：2026 年正月初一', () async {
      final r = await registry.execute(const ToolCall(
          id: 'c',
          name: 'lunar_calendar',
          argumentsJson:
              '{"mode":"lunar_to_solar","year":2026,"month":1,"day":1}'));
      expect(r.isError, isFalse);
      expect(r.content, contains('2026 年 2 月 17 日'));
    });

    test('错误路径：缺参数/坏格式', () async {
      final r1 = await registry.execute(const ToolCall(
          id: 'c', name: 'lunar_calendar', argumentsJson: '{}'));
      expect(r1.isError, isTrue);
      final r2 = await registry.execute(const ToolCall(
          id: 'c',
          name: 'lunar_calendar',
          argumentsJson: '{"mode":"lunar_to_solar","year":2026}'));
      expect(r2.isError, isTrue);
      final r3 = await registry.execute(const ToolCall(
          id: 'c',
          name: 'lunar_calendar',
          argumentsJson: '{"mode":"bad","date":"2026-01-01"}'));
      expect(r3.isError, isTrue);
    });
  });

  group('bazi 八字排盘', () {
    test('1995-06-15 排盘结构完整', () async {
      final r = await call('bazi', {'date': '1995-06-15', 'time': '10:30'});
      expect(r.contains('乾造'), isFalse); // 未传性别
      expect(r, contains('四柱'));
      expect(r, contains('年柱'));
      expect(r, contains('日主'));
      expect(r, contains('五行统计'));
      expect(r, contains('生肖：猪')); // 1995 乙亥猪年
      expect(r, contains('农历'));
    });

    test('立春分界：2026-02-03 仍属乙巳年', () async {
      final r = await call('bazi', {'date': '2026-02-03'});
      expect(r, contains('年柱：乙巳'));
    });

    test('立春分界：2026-02-05 属丙午年', () async {
      final r = await call('bazi', {'date': '2026-02-05'});
      expect(r, contains('年柱：丙午'));
    });

    test('五行统计数字总和为 8', () async {
      final r = await call('bazi', {'date': '2000-01-01', 'time': '23:30'});
      final wxLine = r.split('\n').firstWhere((l) => l.contains('五行统计'));
      final nums = RegExp(r'[木火土金水](\d)')
          .allMatches(wxLine)
          .fold(0, (s, m) => s + int.parse(m.group(1)!));
      expect(nums, 8);
    });

    test('缺时间默认 12 点不报错', () async {
      final r = await call('bazi', {'date': '1990-01-01'});
      expect(r, contains('12:00'));
    });

    test('错误路径：缺参数/坏格式/无效日期', () async {
      Future<String> err(Map<String, dynamic> args) async {
        final r = await registry.execute(ToolCall(
            id: 'c',
            name: 'bazi',
            argumentsJson:
                '{' +
                args.entries
                    .map((e) =>
                        '"${e.key}":"${e.value.toString().replaceAll('"', '')}"')
                .join(',') +
                '}'));
        return r.content;
      }

      expect((await err({})), contains('缺少'));
      expect((await err({'date': '1995/06/15'})), contains('格式'));
      expect((await err({'date': '1995-02-30'})), contains('无效日期'));
      expect((await err({'date': '1899-01-01'})), contains('1901'));
      expect((await err({'date': '1995-06-15', 'time': '25:00'})),
          contains('超出范围'));
    });
  });

  group('wuxing 五行分析', () {
    test('输出日主与五行计数', () async {
      final r = await call('wuxing', {'date': '1995-06-15'});
      expect(r, contains('日主'));
      expect(r, contains('五行：'));
      expect(r, contains('五行对照'));
    });

    test('缺参数报错', () async {
      final r = await registry.execute(
          const ToolCall(id: 'c', name: 'wuxing', argumentsJson: '{}'));
      expect(r.isError, isTrue);
    });
  });

  group('zodiac 生肖星座', () {
    test('1995-06-15 = 猪 + 双子座', () async {
      final r = await call('zodiac', {'date': '1995-06-15'});
      expect(r, contains('猪'));
      expect(r, contains('双子座'));
    });

    test('星座边界：1 月 19 水瓶 / 1 月 20 水瓶 / 12 月 22 摩羯', () async {
      // 1/19 前（含）摩羯，1/20 起水瓶
      expect(ZodiacTool.constellationOf(1, 19), '摩羯座');
      expect(ZodiacTool.constellationOf(1, 20), '水瓶座');
      expect(ZodiacTool.constellationOf(12, 22), '摩羯座');
      expect(ZodiacTool.constellationOf(12, 21), '射手座');
    });

    test('2026-02-17 春节出生 = 马年', () async {
      final r = await call('zodiac', {'date': '2026-02-17'});
      expect(r, contains('马'));
      expect(r, contains('水瓶座')); // 2 月 17 日
    });

    test('错误路径', () async {
      final r1 = await registry.execute(const ToolCall(
          id: 'c', name: 'zodiac', argumentsJson: '{"date":"1995-13-01"}'));
      expect(r1.isError, isTrue);
      final r2 = await registry.execute(const ToolCall(
          id: 'c', name: 'zodiac', argumentsJson: '{"date":"bad"}'));
      expect(r2.isError, isTrue);
    });
  });
}
