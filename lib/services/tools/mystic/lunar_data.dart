/// 农历核心数据（1900-2100）与公农历互转、干支纪年算法。
///
/// 数据表格式：每年一个 int，压缩以下信息（经典 lunarInfo 编码）：
/// - bit 0-3 : 闰月月份（0 = 无闰月，1-12 = 闰几月）
/// - bit 4-15: 12/13 个月的大小月位（1 = 30 天，0 = 29 天）
///   从 bit4 开始是正月，依次到冬月；若有闰月，闰月位在 bit16。
/// - bit 16  : 闰月大小（1 = 30 天，0 = 29 天）
///
/// 数据来源：通用 lunarInfo 表（依据紫金山天文台历数据整理，社区广泛验证）。
library;

/// 1900-2100 每年农历信息压缩位
const List<int> kLunarInfo = [
  0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0,
  0x09ad0, 0x055d2, 0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540,
  0x0d6a0, 0x0ada2, 0x095b0, 0x14977, 0x04970, 0x0a4b0, 0x0b4b5, 0x06a50,
  0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970, 0x06566, 0x0d4a0,
  0x0ea50, 0x06e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,
  0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2,
  0x0a950, 0x0b557, 0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573,
  0x052b0, 0x0a9a8, 0x0e950, 0x06aa0, 0x0aea6, 0x0ab50, 0x04b60, 0x0aae4,
  0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0, 0x096d0, 0x04dd5,
  0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6,
  0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46,
  0x0ab60, 0x09570, 0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58,
  0x05ac0, 0x0ab60, 0x096d5, 0x092e0, 0x0c960, 0x0d954, 0x0d4a0, 0x0da50,
  0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5, 0x0a950, 0x0b4a0,
  0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,
  0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260,
  0x0ea65, 0x0d530, 0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0,
  0x1d0b6, 0x0d250, 0x0d520, 0x0dd45, 0x0b5a0, 0x056d0, 0x055b2, 0x049b0,
  0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0, 0x14b63, 0x09370,
  0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06b20, 0x1a6c4, 0x0aae0,
  0x0a2e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0,
  0x0a6d0, 0x055d4, 0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50,
  0x055a0, 0x0aba4, 0x0a5b0, 0x052b0, 0x0b273, 0x06930, 0x07337, 0x06aa0,
  0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160, 0x0e968, 0x0d520,
  0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252,
  0x0d520, // 2099
];

/// 天干
const List<String> kTianGan = [
  '甲', '乙', '丙', '丁', '戊', '己', '庚', '辛', '壬', '癸',
];

/// 地支
const List<String> kDiZhi = [
  '子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥',
];

/// 生肖（按地支顺序）
const List<String> kShengXiao = [
  '鼠', '牛', '虎', '兔', '龙', '蛇', '马', '羊', '猴', '鸡', '狗', '猪',
];

/// 农历月份名
const List<String> kLunarMonths = [
  '正', '二', '三', '四', '五', '六', '七', '八', '九', '十', '冬', '腊',
];

/// 农历日名（初一到三十）
const List<String> kLunarDays = [
  '初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
  '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
  '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十',
];

/// 农历基准日：1900-01-31 = 农历 1900 年正月初一
final DateTime kLunarEpoch = DateTime(1900, 1, 31);

/// 农历日期
class LunarDate {
  const LunarDate({
    required this.year,
    required this.month,
    required this.day,
    required this.isLeapMonth,
  });

  /// 农历年（如 2026）
  final int year;

  /// 农历月（1-12，闰月时 [isLeapMonth] 为 true）
  final int month;

  /// 农历日（1-30）
  final int day;

  /// 是否闰月
  final bool isLeapMonth;

  /// 干支年（如「丙午」）
  String get ganZhiYear => ganZhiOfYear(year);

  /// 生肖
  String get shengXiao => shengXiaoOfYear(year);

  /// 中文描述（如「二〇二六年二月初二」）
  String get text {
    final y = '$year年';
    final m = isLeapMonth ? '闰${kLunarMonths[month - 1]}月' : '${kLunarMonths[month - 1]}月';
    return '$y$m${kLunarDays[day - 1]}';
  }

  Map<String, dynamic> toJson() => {
        'year': year,
        'month': month,
        'day': day,
        'isLeapMonth': isLeapMonth,
      };
}

/// 农历某年总天数（含闰月）
int lunarYearDays(int year) {
  var sum = 348; // 12 个 29 天
  var info = kLunarInfo[year - 1900];
  for (var i = 0x8000; i > 0x8; i >>= 1) {
    sum += (info & i) == 0 ? 0 : 1;
  }
  return sum + leapMonthDays(year);
}

/// 农历某年闰几月（0 = 无闰月）
int leapMonth(int year) => kLunarInfo[year - 1900] & 0xf;

/// 农历某年闰月天数（无闰月返回 0）
int leapMonthDays(int year) {
  if (leapMonth(year) == 0) return 0;
  return (kLunarInfo[year - 1900] & 0x10000) == 0 ? 29 : 30;
}

/// 农历某年某月天数（month 传闰月月份时返回闰月天数）
int lunarMonthDays(int year, int month, {bool isLeap = false}) {
  if (isLeap) return leapMonthDays(year);
  return (kLunarInfo[year - 1900] & (0x10000 >> month)) == 0 ? 29 : 30;
}

/// 公历 → 农历。超出 1900-2100 支持范围抛 ArgumentError。
LunarDate solarToLunar(DateTime solar) {
  final date = DateTime(solar.year, solar.month, solar.day);
  if (date.isBefore(kLunarEpoch) ||
      date.isAfter(DateTime(2100, 12, 31))) {
    throw ArgumentError('仅支持 1900-01-31 至 2100-12-31 的日期');
  }

  // 距基准日天数
  var offset = date.difference(kLunarEpoch).inDays;

  // 逐年扣减找农历年
  var year = 1900;
  while (year <= 2100 && offset > 0) {
    final days = lunarYearDays(year);
    if (offset < days) break;
    offset -= days;
    year++;
  }

  // 找月：月序为 1..leap(平), leap(闰), leap+1..12
  final leap = leapMonth(year);
  var isLeapMonth = false;
  var month = 1;
  while (month <= 12 && offset > 0) {
    final days =
        isLeapMonth ? leapMonthDays(year) : lunarMonthDays(year, month);
    if (offset < days) break;
    offset -= days;
    if (isLeapMonth) {
      isLeapMonth = false;
      month++;
    } else if (leap > 0 && month == leap) {
      isLeapMonth = true; // 下轮处理闰月（月号不变）
    } else {
      month++;
    }
  }

  return LunarDate(
    year: year,
    month: month,
    day: offset + 1,
    isLeapMonth: isLeapMonth,
  );
}

/// 农历 → 公历。参数非法抛 ArgumentError。
DateTime lunarToSolar(int year, int month, int day, {bool isLeap = false}) {
  if (year < 1900 || year > 2100) {
    throw ArgumentError('仅支持 1900-2100 年');
  }
  if (month < 1 || month > 12) throw ArgumentError('月份须在 1-12');
  if (isLeap && leapMonth(year) != month) {
    throw ArgumentError('$year 年没有闰$month 月');
  }
  final maxDay =
      isLeap ? leapMonthDays(year) : lunarMonthDays(year, month);
  if (day < 1 || day > maxDay) {
    throw ArgumentError('$year 年${isLeap ? '闰' : ''}$month 月只有 $maxDay 天');
  }

  var offset = 0;
  for (var y = 1900; y < year; y++) {
    offset += lunarYearDays(y);
  }
  final leap = leapMonth(year);
  // 累加目标月之前的所有月（月序 1..leap 平月, leap 闰月, leap+1..）
  var m = 1;
  while (m < month || (isLeap && m == month)) {
    offset += lunarMonthDays(year, m);
    if (leap > 0 && m == leap) {
      // 平 leap 月之后紧跟闰 leap 月
      if (isLeap && m == month) break; // 目标就是闰月，前面平月已加
      offset += leapMonthDays(year);
    }
    m++;
  }
  if (isLeap) {
    // 目标是闰月：上面循环在 m==month 时只加了平月，需补闰月位置判断——
    // 实际上循环条件 isLeap && m==month 时先加平月再 break，此处 offset
    // 已含平月，闰月日从平月月末起算，无需再加
  }
  return kLunarEpoch.add(Duration(days: offset + day - 1));
}

/// 干支纪年（立春分界的八字年柱请用 [baziYearGanZhi]）
String ganZhiOfYear(int year) {
  final gan = kTianGan[(year - 4) % 10];
  final zhi = kDiZhi[(year - 4) % 12];
  return '$gan$zhi';
}

/// 生肖（按农历年）
String shengXiaoOfYear(int year) => kShengXiao[(year - 4) % 12];

/// 八字年柱：以立春为界（约每年 2 月 4 日）。
/// 精确到日的近似：立春日在 2 月 3-5 日之间，此处按 2 月 4 日处理。
/// （玄学娱乐场景可接受；如需精确到分钟需引入节气表。）
String baziYearGanZhi(DateTime solar) {
  final gzYear = solar.month > 2 || (solar.month == 2 && solar.day >= 4)
      ? solar.year
      : solar.year - 1;
  return ganZhiOfYear(gzYear);
}

/// 八字月柱：按节气月（寅月起正月），以「节」为界。
/// 近似节日（每月 4-8 日间，按多年平均取整日）：
/// 立春 2/4 惊蛰 3/6 清明 4/5 立夏 5/6 芒种 6/6 小暑 7/7 立秋 8/8
/// 白露 9/8 寒露 10/8 立冬 11/7 大雪 12/7 小寒 1/6
String baziMonthGanZhi(DateTime solar) {
  // 节气分界日（月, 日）
  const jie = [
    [1, 6], [2, 4], [3, 6], [4, 5], [5, 6], [6, 6],
    [7, 7], [8, 8], [9, 8], [10, 8], [11, 7], [12, 7],
  ];
  // 确定节气月序（0 = 小寒月/丑月 … 11 = 冬月后/子月）
  var idx = 11; // 默认大雪后
  for (var i = 0; i < 12; i++) {
    final jm = jie[i][0];
    final jd = jie[i][1];
    if (solar.month > jm || (solar.month == jm && solar.day >= jd)) {
      idx = i;
    }
  }
  // idx: 0=丑月(小寒后) 1=寅月(立春后) … 11=子月(大雪后)
  final monthZhiIndex = idx == 0 ? 1 : (idx + 1) % 12; // 寅=2 起
  // 月干：五虎遁——年干定寅月干
  // 年干甲己→丙寅起，乙庚→戊寅，丙辛→庚寅，丁壬→壬寅，戊癸→甲寅
  final gzYear = solar.month > 2 || (solar.month == 2 && solar.day >= 4)
      ? solar.year
      : solar.year - 1;
  final yearGan = (gzYear - 4) % 10;
  const firstGanOfYin = [2, 4, 6, 8, 0]; // 甲己丙 乙庚戊 丙辛庚 丁壬壬 戊癸甲
  final yinGan = firstGanOfYin[yearGan % 5];
  final monthOffset = (monthZhiIndex - 2 + 12) % 12; // 距寅月数
  final monthGan = (yinGan + monthOffset) % 10;
  return '${kTianGan[monthGan]}${kDiZhi[monthZhiIndex]}';
}

/// 八字日柱：基准 1900-01-01 = 甲戌日（甲=0）。
/// 经典算法：以 1900-01-31（甲辰日）等锚点推算，此处用 1900-01-01 甲戌。
String baziDayGanZhi(DateTime solar) {
  final date = DateTime(solar.year, solar.month, solar.day);
  final anchor = DateTime(1900, 1, 1);
  final days = date.difference(anchor).inDays;
  // 1900-01-01 是甲戌日：甲=0，戌=10 → 干支序 10（甲戌在六十甲子中序 11，索引 10）
  final index = (days + 10) % 60;
  return '${kTianGan[index % 10]}${kDiZhi[index % 12]}';
}

/// 八字时柱：五鼠遁——日干定时干。时支按 2 小时一辰，23:00 起子时。
/// [hour] 24 小时制。
String baziHourGanZhi(DateTime solar) {
  final hour = solar.hour;
  // 时支：23-0 子，1-2 丑 … 21-22 亥
  final zhiIndex = ((hour + 1) ~/ 2) % 12;
  final dayGan = _dayGanIndex(solar);
  // 五鼠遁：甲己→甲子起，乙庚→丙子，丙辛→戊子，丁壬→庚子，戊癸→壬子
  const firstGanOfZi = [0, 2, 4, 6, 8];
  final ziGan = firstGanOfZi[dayGan % 5];
  final hourGan = (ziGan + zhiIndex) % 10;
  return '${kTianGan[hourGan]}${kDiZhi[zhiIndex]}';
}

int _dayGanIndex(DateTime solar) {
  final date = DateTime(solar.year, solar.month, solar.day);
  final days = date.difference(DateTime(1900, 1, 1)).inDays;
  return (days + 10) % 60 % 10;
}

/// 五行归属
String wuXingOfGan(String gan) {
  const map = {
    '甲': '木', '乙': '木', '丙': '火', '丁': '火',
    '戊': '土', '己': '土', '庚': '金', '辛': '金',
    '壬': '水', '癸': '水',
  };
  return map[gan] ?? '';
}

String wuXingOfZhi(String zhi) {
  const map = {
    '子': '水', '丑': '土', '寅': '木', '卯': '木',
    '辰': '土', '巳': '火', '午': '火', '未': '土',
    '申': '金', '酉': '金', '戌': '土', '亥': '水',
  };
  return map[zhi] ?? '';
}

/// 纳音五行（六十甲子，每两组一纳音）
const List<String> kNaYin = [
  '海中金', '炉中火', '大林木', '路旁土', '剑锋金',
  '山头火', '涧下水', '城头土', '白蜡金', '杨柳木',
  '泉中水', '屋上土', '霹雳火', '松柏木', '长流水',
  '砂石金', '山下火', '平地木', '壁上土', '金箔金',
  '覆灯火', '天河水', '大驿土', '钗钏金', '桑柘木',
  '大溪水', '沙中土', '天上火', '石榴木', '大海水',
];

/// 干支序（0-59）的纳音
String naYinOfIndex(int index) => kNaYin[index ~/ 2];

/// 干支字符串（如「甲子」）转六十甲子序号，非法返回 -1
int ganZhiIndex(String gz) {
  if (gz.length != 2) return -1;
  final g = kTianGan.indexOf(gz[0]);
  final z = kDiZhi.indexOf(gz[1]);
  if (g < 0 || z < 0) return -1;
  // 干支同奇偶才存在于六十甲子
  if (g % 2 != z % 2) return -1;
  for (var i = 0; i < 60; i++) {
    if (i % 10 == g && i % 12 == z) return i;
  }
  return -1;
}
