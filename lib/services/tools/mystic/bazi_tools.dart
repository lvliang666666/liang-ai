import 'dart:math';

import '../../tool_registry.dart';
import 'lunar_data.dart';

/// 八字排盘工具：公历生日 → 四柱干支 + 五行统计 + 纳音 + 生肖。
///
/// 只输出排盘事实数据，命理解读交给模型。
class BaziTool extends ToolHandler {
  const BaziTool();

  @override
  String get name => 'bazi';

  @override
  String get description =>
      '八字排盘：输入公历出生日期时间（可选性别），输出四柱干支（年柱/月柱/日柱/时柱）、'
      '五行分布统计、日主与纳音。年柱以立春为界，月柱按节气，时柱按 2 小时一辰。'
      '排盘结果仅供娱乐参考。不传时间默认中午 12 点。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'date': {
            'type': 'string',
            'description': '公历出生日期，格式 yyyy-MM-dd，如 1995-06-15',
          },
          'time': {
            'type': 'string',
            'description': '出生时间 HH:mm（24 小时制），可选，默认 12:00',
          },
          'gender': {
            'type': 'string',
            'enum': ['male', 'female'],
            'description': '性别（影响大运顺逆，当前版本仅记录）',
          },
        },
        'required': ['date'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final dateStr = arguments['date'] as String?;
    if (dateStr == null || dateStr.trim().isEmpty) {
      throw ArgumentError('缺少出生日期 date（yyyy-MM-dd）');
    }
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
        .firstMatch(dateStr.trim());
    if (m == null) throw ArgumentError('日期格式应为 yyyy-MM-dd');

    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final solar = DateTime(year, month, day);
    // DateTime 构造进位检测（如 2 月 30 日）
    if (solar.year != year || solar.month != month || solar.day != day) {
      throw ArgumentError('无效日期：$dateStr');
    }
    if (year < 1901 || year > 2099) {
      throw ArgumentError('仅支持 1901-2099 年出生');
    }

    final timeStr = arguments['time'] as String?;
    var hour = 12;
    var minute = 0;
    if (timeStr != null && timeStr.trim().isNotEmpty) {
      final tm = RegExp(r'^(\d{1,2}):(\d{1,2})$').firstMatch(timeStr.trim());
      if (tm == null) throw ArgumentError('时间格式应为 HH:mm');
      hour = int.parse(tm.group(1)!);
      minute = int.parse(tm.group(2)!);
      if (hour > 23 || minute > 59) throw ArgumentError('时间超出范围');
    }
    final solarFull = DateTime(year, month, day, hour, minute);

    final gender = arguments['gender'] as String?;
    final genderText = gender == 'female'
        ? '坤造（女）'
        : gender == 'male'
            ? '乾造（男）'
            : '未提供';

    final lunar = solarToLunar(solar);
    final yearGz = baziYearGanZhi(solarFull);
    final monthGz = baziMonthGanZhi(solarFull);
    final dayGz = baziDayGanZhi(solarFull);
    final hourGz = baziHourGanZhi(solarFull);

    // 五行统计（四柱八字 8 字）
    final pillars = [yearGz, monthGz, dayGz, hourGz];
    final counts = <String, int>{'木': 0, '火': 0, '土': 0, '金': 0, '水': 0};
    for (final p in pillars) {
      counts[wuXingOfGan(p[0])] = (counts[wuXingOfGan(p[0])] ?? 0) + 1;
      counts[wuXingOfZhi(p[1])] = (counts[wuXingOfZhi(p[1])] ?? 0) + 1;
    }
    final missing =
        counts.entries.where((e) => e.value == 0).map((e) => e.key).toList();

    final naYin = naYinOfIndex(ganZhiIndex(yearGz));

    final lines = [
      '【八字排盘】$genderText',
      '公历：${_fmtDate(solarFull)}',
      '农历：${lunar.text}',
      '',
      '四柱：',
      '  年柱：$yearGz（${wuXingOfGan(yearGz[0])}${wuXingOfZhi(yearGz[1])}）纳音：$naYin',
      '  月柱：$monthGz（${wuXingOfGan(monthGz[0])}${wuXingOfZhi(monthGz[1])}）',
      '  日柱：$dayGz（${wuXingOfGan(dayGz[0])}${wuXingOfZhi(dayGz[1])}）—— 日主',
      '  时柱：$hourGz（${wuXingOfGan(hourGz[0])}${wuXingOfZhi(hourGz[1])}）',
      '',
      '五行统计：' +
          counts.entries.map((e) => '${e.key}${e.value}').join(' '),
      if (missing.isNotEmpty) '五行所缺：${missing.join('、')}',
      if (missing.isEmpty) '五行俱全',
      '生肖：${lunar.shengXiao}',
      '',
      '（排盘仅供娱乐参考，解读请结合传统命理知识展开）',
    ];
    return lines.join('\n');
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// 五行分析工具：八字五行计数 + 日主强弱提示 + 缺项补救方向。
class WuXingTool extends ToolHandler {
  const WuXingTool();

  @override
  String get name => 'wuxing';

  @override
  String get description =>
      '五行分析：输入公历出生日期时间，输出八字五行计数、日主五行、五行所缺、'
      '各五行对应方位/颜色/季节对照表。比 bazi 更聚焦五行维度。仅供娱乐参考。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'date': {
            'type': 'string',
            'description': '公历出生日期 yyyy-MM-dd',
          },
          'time': {
            'type': 'string',
            'description': '出生时间 HH:mm，可选，默认 12:00',
          },
        },
        'required': ['date'],
      };

  static const _wxInfo = {
    '木': '东方 · 绿色 · 春天 · 仁',
    '火': '南方 · 红色 · 夏天 · 礼',
    '土': '中央 · 黄色 · 长夏 · 信',
    '金': '西方 · 白色 · 秋天 · 义',
    '水': '北方 · 黑色 · 冬天 · 智',
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final dateStr = arguments['date'] as String?;
    if (dateStr == null || dateStr.trim().isEmpty) {
      throw ArgumentError('缺少出生日期 date（yyyy-MM-dd）');
    }
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
        .firstMatch(dateStr.trim());
    if (m == null) throw ArgumentError('日期格式应为 yyyy-MM-dd');
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    if (year < 1901 || year > 2099) {
      throw ArgumentError('仅支持 1901-2099 年');
    }

    var hour = 12;
    final timeStr = arguments['time'] as String?;
    if (timeStr != null && timeStr.trim().isNotEmpty) {
      final tm = RegExp(r'^(\d{1,2}):(\d{1,2})$').firstMatch(timeStr.trim());
      if (tm == null) throw ArgumentError('时间格式应为 HH:mm');
      hour = int.parse(tm.group(1)!);
      if (hour > 23) throw ArgumentError('时间超出范围');
    }
    final solar = DateTime(year, month, day, hour);

    final pillars = [
      baziYearGanZhi(solar),
      baziMonthGanZhi(solar),
      baziDayGanZhi(solar),
      baziHourGanZhi(solar),
    ];
    final counts = <String, int>{'木': 0, '火': 0, '土': 0, '金': 0, '水': 0};
    for (final p in pillars) {
      counts[wuXingOfGan(p[0])] = (counts[wuXingOfGan(p[0])] ?? 0) + 1;
      counts[wuXingOfZhi(p[1])] = (counts[wuXingOfZhi(p[1])] ?? 0) + 1;
    }
    final dayGz = pillars[2];
    final dayMaster = wuXingOfGan(dayGz[0]);
    final missing =
        counts.entries.where((e) => e.value == 0).map((e) => e.key).toList();
    final strongest = counts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;

    final lines = [
      '【五行分析】',
      '四柱：${pillars.join(' ')}',
      '五行：' + counts.entries.map((e) => '${e.key}${e.value}').join(' '),
      '',
      '日主：$dayGz → ${dayGz[0]}（$dayMaster）',
      '最旺：$strongest（${counts[strongest]} 个）',
      missing.isEmpty
          ? '五行俱全，气场均衡'
          : '所缺：${missing.join('、')}（传统说法：可从方位/颜色/习性上补）',
      '',
      '五行对照：',
      for (final e in _wxInfo.entries) '  ${e.key}：${e.value}',
      '',
      '（五行分析仅供娱乐参考）',
    ];
    return lines.join('\n');
  }
}

/// 生肖星座工具：公历日期 → 生肖（按农历年）+ 星座（按太阳黄经近似分界）。
class ZodiacTool extends ToolHandler {
  const ZodiacTool();

  @override
  String get name => 'zodiac';

  @override
  String get description =>
      '查询生肖与星座：输入公历出生日期，输出农历生肖（按农历年）与西方星座'
      '（按太阳黄经近似分界）。可选传农历查询模式。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'date': {
            'type': 'string',
            'description': '公历出生日期 yyyy-MM-dd',
          },
        },
        'required': ['date'],
      };

  /// 星座分界（每月的界日，界日当天起算后一星座）
  static const _cusp = [20, 19, 21, 20, 21, 22, 23, 23, 23, 24, 23, 22];
  static const _constellations = [
    '摩羯座', '水瓶座', '双鱼座', '白羊座', '金牛座', '双子座',
    '巨蟹座', '狮子座', '处女座', '天秤座', '天蝎座', '射手座',
  ];

  static String constellationOf(int month, int day) {
    // 界日表：1 月 20 日前摩羯，之后水瓶……
    final idx = day < _cusp[month - 1] ? month - 1 : month % 12;
    return _constellations[idx];
  }

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final dateStr = arguments['date'] as String?;
    if (dateStr == null || dateStr.trim().isEmpty) {
      throw ArgumentError('缺少出生日期 date（yyyy-MM-dd）');
    }
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
        .firstMatch(dateStr.trim());
    if (m == null) throw ArgumentError('日期格式应为 yyyy-MM-dd');
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final solar = DateTime(year, month, day);
    if (solar.year != year || solar.month != month || solar.day != day) {
      throw ArgumentError('无效日期：$dateStr');
    }
    if (year < 1900 || year > 2100) {
      throw ArgumentError('仅支持 1900-2100 年');
    }

    final lunar = solarToLunar(solar);
    final sx = lunar.shengXiao;
    final gz = lunar.ganZhiYear;
    final constellation = constellationOf(month, day);

    return [
      '【生肖星座】',
      '公历：$year 年 $month 月 $day 日',
      '农历：${lunar.text}',
      '生肖：$sx（$gz 年）',
      '星座：$constellation',
      '',
      '（生肖按农历年划分，星座按太阳黄经近似分界，仅供娱乐）',
    ].join('\n');
  }
}

/// 农历转换工具：公历 ↔ 农历互转 + 干支年 + 生肖。
class LunarCalendarTool extends ToolHandler {
  const LunarCalendarTool();

  @override
  String get name => 'lunar_calendar';

  @override
  String get description =>
      '农历转换：公历日期转农历（含闰月、干支年、生肖），或农历日期反查公历。'
      '支持 1900-2100 年。「2026 年春节是哪天」「我生日农历是几月初几」这类问题用它。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'mode': {
            'type': 'string',
            'enum': ['solar_to_lunar', 'lunar_to_solar'],
            'description': 'solar_to_lunar=公历转农历（默认），lunar_to_solar=农历转公历',
          },
          'date': {
            'type': 'string',
            'description': '公历日期 yyyy-MM-dd（solar_to_lunar 模式）',
          },
          'year': {'type': 'number', 'description': '农历年（lunar_to_solar 模式）'},
          'month': {'type': 'number', 'description': '农历月 1-12（lunar_to_solar 模式）'},
          'day': {'type': 'number', 'description': '农历日 1-30（lunar_to_solar 模式）'},
          'is_leap': {'type': 'boolean', 'description': '是否闰月（lunar_to_solar 模式，默认 false）'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final mode = (arguments['mode'] as String? ?? 'solar_to_lunar').trim();

    if (mode == 'solar_to_lunar') {
      final dateStr = arguments['date'] as String?;
      if (dateStr == null || dateStr.trim().isEmpty) {
        throw ArgumentError('缺少日期 date（yyyy-MM-dd）');
      }
      final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
          .firstMatch(dateStr.trim());
      if (m == null) throw ArgumentError('日期格式应为 yyyy-MM-dd');
      final y = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final d = int.parse(m.group(3)!);
      final solar = DateTime(y, mo, d);
      if (solar.year != y || solar.month != mo || solar.day != d) {
        throw ArgumentError('无效日期：$dateStr');
      }
      final lunar = solarToLunar(solar);
      return [
        '【农历转换】',
        '公历：$y 年 $mo 月 $d 日',
        '农历：${lunar.text}',
        '干支年：${lunar.ganZhiYear}年（${lunar.shengXiao}）',
        if (lunar.isLeapMonth) '（闰月）',
      ].join('\n');
    }

    if (mode == 'lunar_to_solar') {
      final year = (arguments['year'] as num?)?.toInt();
      final month = (arguments['month'] as num?)?.toInt();
      final day = (arguments['day'] as num?)?.toInt();
      if (year == null || month == null || day == null) {
        throw ArgumentError('农历转公历需要 year / month / day 三个参数');
      }
      final isLeap = arguments['is_leap'] == true;
      final solar = lunarToSolar(year, month, day, isLeap: isLeap);
      final lunar = LunarDate(
          year: year, month: month, day: day, isLeapMonth: isLeap);
      return [
        '【农历转换】',
        '农历：${lunar.text}',
        '公历：${solar.year} 年 ${solar.month} 月 ${solar.day} 日',
        '干支年：${lunar.ganZhiYear}年（${lunar.shengXiao}）',
      ].join('\n');
    }

    throw ArgumentError('未知模式 "$mode"，支持 solar_to_lunar / lunar_to_solar');
  }
}

/// 供测试使用的随机源注入点（默认系统随机）
Random mysticRandom = Random();
