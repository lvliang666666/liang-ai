import '../../tool_registry.dart';
import 'bazi_tools.dart' show mysticRandom;
import 'lunar_data.dart';

/// 数字能量学工具：手机号/生日等数字串的 81 数理吉凶分析。
class ShuZiTool extends ToolHandler {
  const ShuZiTool();

  @override
  String get name => 'shuzi';

  @override
  String get description =>
      '数字能量学：分析手机号、QQ 号、生日等数字串的数理吉凶（81 数理表）。'
      '输出总格数理、吉凶等级、逐位拆解。数字长度不限。仅供娱乐参考。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'number': {
            'type': 'string',
            'description': '要分析的数字串，如手机号 13812345678',
          },
        },
        'required': ['number'],
      };

  /// 81 数理吉凶（1-81 循环，索引 0 对应数理 1）
  /// 吉 = true，凶 = false（半吉半凶按吉处理并标注）
  static const _jiXiong = [
    true, false, true, false, false, // 1-5
    true, true, false, true, true, // 6-10
    false, false, true, false, true, // 11-15
    true, false, true, false, false, // 16-20
    true, true, true, false, true, // 21-25
    false, false, true, false, true, // 26-30
    true, false, true, true, false, // 31-35
    false, false, true, false, false, // 36-40
    true, false, true, true, false, // 41-45
    true, false, false, true, false, // 46-50
    true, false, true, true, false, // 51-55
    false, false, true, false, false, // 56-60
    true, false, true, true, false, // 61-65
    true, false, true, true, true, // 66-70
    false, false, true, false, true, // 71-75
    true, false, false, true, false, // 76-80
    true, // 81
  ];

  static String levelOf(int n) {
    final idx = (n - 1) % 81;
    return _jiXiong[idx] ? '吉' : '凶';
  }

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final number = arguments['number'] as String?;
    if (number == null) throw ArgumentError('缺少数字串 number');
    final digits = number.replaceAll(RegExp(r'[\s-]'), '');
    if (digits.isEmpty || digits.contains(RegExp(r'[^\d]'))) {
      throw ArgumentError('number 应为纯数字串');
    }

    // 总格：各位数字求和，循环归约到 1-81
    var sum = 0;
    for (final ch in digits.split('')) {
      sum += int.parse(ch);
    }
    var total = sum;
    while (total > 81) {
      total = total.toString().split('').fold(0, (s, c) => s + int.parse(c));
    }

    // 逐位拆解（取后 4 位做尾数分析，数字能量学惯例）
    final tail = digits.length >= 4
        ? digits.substring(digits.length - 4)
        : digits;
    final tailLines = <String>[];
    for (var i = 0; i < tail.length; i++) {
      final d = int.parse(tail[i]);
      tailLines.add('  第 ${i + 1} 位（${d}）：数理 ${d == 0 ? 81 : d} · ${levelOf(d == 0 ? 81 : d)}');
    }

    return [
      '【数字能量分析】',
      '数字：$digits（${digits.length} 位）',
      '',
      '各位求和：$sum → 归约总格：$total（${levelOf(total)}）',
      '',
      '尾数拆解（后 ${tail.length} 位）：',
      ...tailLines,
      '',
      '（数字能量学 81 数理仅供娱乐参考，号码吉凶不在数字在人心）',
    ].join('\n');
  }
}

/// 姓名五格工具：姓名笔画（康熙字典笔画近似）→ 天/人/地/外/总五格。
class XingMingTool extends ToolHandler {
  const XingMingTool();

  @override
  String get name => 'xingming';

  @override
  String get description =>
      '姓名五格测算：输入中文姓名（2-4 字），按康熙字典笔画计算天格/人格/地格/'
      '外格/总格，输出各格数理与吉凶。复姓请连写。仅供娱乐参考。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': '中文姓名，2-4 字，如「李明」或「欧阳修」',
          },
        },
        'required': ['name'],
      };

  /// 常用姓与字的康熙笔画表（覆盖高频字，未收录按 1 画/简体笔画近似）
  static const _strokes = {
    // 常见姓
    '李': 7, '王': 4, '张': 11, '刘': 15, '陈': 16, '杨': 13, '赵': 14,
    '黄': 12, '周': 8, '吴': 7, '徐': 10, '孙': 10, '胡': 9, '朱': 6,
    '高': 10, '林': 8, '何': 7, '郭': 15, '马': 10, '罗': 20, '梁': 11,
    '宋': 7, '郑': 19, '谢': 17, '韩': 17, '唐': 10, '冯': 12, '于': 3,
    '董': 15, '萧': 18, '程': 12, '曹': 11, '袁': 10, '邓': 19, '许': 11,
    '傅': 12, '沈': 8, '曾': 12, '彭': 12, '吕': 7, '苏': 22, '卢': 16,
    '蒋': 17, '蔡': 17, '贾': 13, '丁': 2, '魏': 18, '薛': 19, '叶': 15,
    '阎': 16, '余': 7, '潘': 16, '杜': 7, '戴': 18, '夏': 10, '钟': 17,
    '汪': 8, '田': 5, '任': 6, '姜': 9, '范': 11, '方': 4, '石': 5,
    '姚': 9, '谭': 19, '廖': 14, '邹': 12, '熊': 14, '金': 8, '陆': 11,
    '郝': 14, '孔': 4, '白': 5, '崔': 11, '康': 11, '毛': 4, '邱': 5,
    '秦': 10, '江': 7, '史': 5, '顾': 21, '侯': 9, '邵': 12, '孟': 8,
    '龙': 16, '万': 15, '段': 9, '雷': 13, '钱': 16, '汤': 13, '尹': 4,
    '易': 8, '常': 11, '武': 8, '乔': 12, '贺': 12, '赖': 16, '龚': 22,
    // 复姓
    '欧阳': 0, // 占位（复姓按两字分别取）
    '诸葛': 0, '司马': 0, '上官': 0,
    // 高频名字用字
    '明': 8, '华': 14, '军': 9, '伟': 11, '强': 12, '平': 5, '辉': 15,
    '鹏': 19, '飞': 9, '鑫': 24, '磊': 15, '浩': 11, '宇': 6, '轩': 10,
    '然': 12, '婷': 12, '雪': 11, '梅': 11, '兰': 21, '竹': 6, '菊': 14,
    '春': 9, '花': 8, '红': 9, '丽': 19, '娟': 10, '敏': 11, '静': 16,
    '娜': 10, '琳': 13, '晶': 12, '云': 12, '峰': 10, '涛': 18,
    '超': 12, '勇': 9, '杰': 12, '斌': 12, '波': 9,
    '刚': 10, '健': 11, '俊': 9, '帆': 6, '宁': 14, '欣': 8, '怡': 9,
    '佳': 8, '嘉': 14, '子': 3, '梓': 11, '涵': 12, '萱': 15, '琪': 13,
    '瑶': 15, '璇': 16, '瑞': 14, '睿': 14, '哲': 10, '思': 9, '远': 17,
    '志': 7, '国': 11, '文': 4, '天': 4, '凤': 14,
    '德': 15, '福': 14, '禄': 13, '寿': 14, '喜': 12, '财': 10, '贵': 12,
    '富': 12, '安': 6, '乐': 15, '和': 8, '顺': 12,
    '一': 1, '二': 2, '三': 3, '四': 5, '五': 4, '六': 4, '七': 2,
    '八': 2, '九': 2, '十': 2, '百': 6, '千': 3, '亿': 15,
  };

  /// 取康熙笔画（未收录字按简体笔画近似：这里统一按 10 画兜底并标注）
  static int strokesOf(String ch) => _strokes[ch] ?? 10;

  static String levelOf(int n) {
    if (n <= 0) return '—';
    final idx = (n - 1) % 81;
    const ji = [
      true, false, true, false, false, true, true, false, true, true,
      false, false, true, false, true, true, false, true, false, false,
      true, true, true, false, true, false, false, true, false, true,
      true, false, true, true, false, false, false, true, false, false,
      true, false, true, true, false, true, false, false, true, false,
      true, false, true, true, false, false, false, true, false, false,
      true, false, true, true, false, true, false, true, true, true,
      false, false, true, false, true, true, false, false, true, false,
      true,
    ];
    return ji[idx] ? '吉' : '凶';
  }

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final name = arguments['name'] as String?;
    if (name == null || name.trim().isEmpty) {
      throw ArgumentError('缺少姓名 name');
    }
    final chars = name.trim().split('');
    if (chars.length < 2 || chars.length > 4) {
      throw ArgumentError('姓名须为 2-4 个字');
    }
    if (chars.any((c) => RegExp(r'[a-zA-Z0-9]').hasMatch(c))) {
      throw ArgumentError('请输入中文姓名');
    }

    final strokes = chars.map(strokesOf).toList();
    final unknown = <String>[
      for (var i = 0; i < chars.length; i++)
        if (!_strokes.containsKey(chars[i])) chars[i],
    ];

    // 五格计算（单姓/复姓简化：按字数分）
    final isCompound = chars.length >= 3 && _strokes.containsKey(chars[0] + chars[1]) == false &&
        (chars[0] + chars[1] == '欧阳' ||
            chars[0] + chars[1] == '诸葛' ||
            chars[0] + chars[1] == '司马' ||
            chars[0] + chars[1] == '上官');
    int tianGe, renGe, diGe, waiGe, zongGe;
    if (isCompound) {
      // 复姓：姓两字 + 名（1-2 字）
      final surname = strokes[0] + strokes[1];
      tianGe = surname;
      renGe = strokes.length == 3
          ? strokes[2] + 1
          : strokes[2] + strokes[3];
      diGe = strokes.length == 3 ? 2 : strokes[2] + strokes[3];
      waiGe = strokes.length == 3 ? 2 : 2;
      zongGe = surname + (strokes.length == 3 ? strokes[2] : strokes[2] + strokes[3]);
    } else {
      final surname = strokes[0];
      tianGe = surname + 1;
      renGe = strokes.length == 2
          ? surname + strokes[1]
          : surname + strokes[1];
      diGe = strokes.length == 2
          ? strokes[1] + 1
          : strokes[1] + strokes[2];
      waiGe = strokes.length == 2
          ? 2
          : (strokes.length == 3 ? strokes[2] + 1 : strokes[2] + strokes[3]);
      zongGe = strokes.fold(0, (a, b) => a + b);
    }

    String fmt(String label, int n) =>
        '$label：$n（${levelOf(n)}）';

    return [
      '【姓名五格】${chars.join('')}',
      '康熙笔画：${chars.map((c) => '$c=${strokesOf(c)}').join(' ')}',
      if (unknown.isNotEmpty)
        '（未收录生僻字按 10 画近似：${unknown.join('、')}）',
      '',
      fmt('天格', tianGe),
      fmt('人格', renGe),
      fmt('地格', diGe),
      fmt('外格', waiGe),
      fmt('总格', zongGe),
      '',
      '（五格剖象法仅供娱乐参考，名字好坏不在笔画在寓意）',
    ].join('\n');
  }
}

/// 六爻起卦工具：三枚铜钱摇六次 → 本卦 + 变卦（纳甲简化版，出卦象与卦名）。
class DiceIchingTool extends ToolHandler {
  const DiceIchingTool();

  @override
  String get name => 'dice_iching';

  @override
  String get description =>
      '六爻起卦：模拟三枚铜钱摇六次（从下往上），得出本卦与变卦，'
      '输出卦名、卦象（六爻阴阳）、动爻。适合问事业/感情/决策等。仅供娱乐参考。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'topic': {
            'type': 'string',
            'description': '所问之事（如跳槽/姻缘），仅记录展示',
          },
        },
      };

  /// 八经卦（三爻，自下而上 1=阳 0=阴）
  static const _trigrams = {
    '111': '乾', '000': '坤', '100': '震', '010': '坎',
    '001': '艮', '011': '巽', '101': '离', '110': '兑',
  };

  /// 六十四卦名（上卦+下卦 → 卦名）
  static const _hexagramNames = {
    '乾乾': '乾为天', '坤坤': '坤为地', '震坎': '水雷屯', '坎艮': '山水蒙',
    '坎乾': '水天需', '乾坎': '天水讼', '坤坎': '地水师', '坎坤': '水地比',
    '巽乾': '风天小畜', '乾兑': '天泽履', '坤兑': '地天泰', '兑坤': '泽地否',
    '乾离': '天火同人', '离乾': '火天大有', '艮坤': '地山谦', '震坤': '雷地豫',
    '兑震': '泽雷随', '艮震': '山雷颐', '巽兑': '泽风大过', '坎坎': '坎为水',
    '离离': '离为火', '艮兑': '泽山咸', '震巽': '雷风恒', '艮乾': '天山遁',
    '乾艮': '雷天大壮', '坤离': '火地晋', '离坤': '火地晋', '兑离': '泽火革',
    '离兑': '火泽睽', '震离': '雷火丰', '离艮': '火山旅', '巽巽': '巽为风',
    '巽坎': '水风井', '坎兑': '泽水困', '兑坎': '泽水革',
    '震艮': '雷山小过', '艮巽': '风山渐',
    '巽艮': '风泽中孚', '艮艮': '艮为山', '巽震': '风雷益', '兑兑': '兑为泽',
    '兑巽': '泽风大过', '艮离': '火山旅',
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final topic = arguments['topic'] as String?;

    // 摇六次，自下而上。每爻：三枚铜钱（背=3，字=2），和为 6-9
    // 6=老阴(动) 7=少阳 8=少阴 9=老阳(动)
    final lines = <int>[];
    final moving = <int>[];
    for (var i = 0; i < 6; i++) {
      final coins = [
        mysticRandom.nextBool() ? 3 : 2,
        mysticRandom.nextBool() ? 3 : 2,
        mysticRandom.nextBool() ? 3 : 2,
      ];
      final sum = coins.fold(0, (a, b) => a + b);
      lines.add(sum);
      if (sum == 6 || sum == 9) moving.add(i + 1);
    }

    // 本卦：老阳记阳，老阴记阴；变卦：动爻取反
    final ben = lines.map((l) => (l == 7 || l == 9) ? 1 : 0).join();
    final bian = lines
        .map((l) =>
            (l == 7 || l == 9) ? '0' : (l == 6 ? '1' : '0'))
        .join();

    String hexName(String code) {
      final lower = _trigrams[code.substring(0, 3)]!;
      final upper = _trigrams[code.substring(3)]!;
      return _hexagramNames['$upper$lower'] ?? '$upper下$lower上（未收录卦名）';
    }

    final benName = hexName(ben);
    final bianName = moving.isEmpty ? '（无动爻，不变）' : hexName(bian);

    final yaoStr = (String code) => code
        .split('')
        .reversed
        .map((b) => b == '1' ? '━━━' : '━ ━')
        .join('\n      ');

    return [
      '【六爻起卦】${topic == null || topic.isEmpty ? '' : '所问：$topic'}',
      '',
      '摇卦记录（自下而上）：',
      for (var i = 0; i < 6; i++)
        '  第${i + 1}爻：${_coinText(lines[i])}${(lines[i] == 6 || lines[i] == 9) ? ' ← 动爻' : ''}',
      '',
      '本卦：$benName',
      '      ${yaoStr(ben)}',
      if (moving.isNotEmpty) ...[
        '动爻：第 ${moving.join('、')} 爻',
        '变卦：$bianName',
        '      ${yaoStr(bian)}',
      ],
      if (moving.isEmpty) '无动爻：静卦，以本卦卦辞断之',
      '',
      '（六爻模拟铜钱摇卦，仅供娱乐参考；卦象解读请结合所问之事）',
    ].join('\n');
  }

  static String _coinText(int sum) {
    switch (sum) {
      case 6:
        return '三字（老阴 ⚋ 动）';
      case 7:
        return '一背二字（少阳 ⚊）';
      case 8:
        return '两背一字（少阴 ⚋）';
      case 9:
        return '三背（老阳 ⚊ 动）';
    }
    return '';
  }
}

/// 桃花测算工具：出生年支/日支推桃花位（咸池）。
class PeachBlossomTool extends ToolHandler {
  const PeachBlossomTool();

  @override
  String get name => 'peach_blossom';

  @override
  String get description =>
      '桃花测算：输入公历出生日期，按传统「申子辰见酉」等咸池规则推算桃花位与'
      '桃花年提示。输出桃花方位、旺年。仅供娱乐参考。';

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

  /// 咸池（桃花）：三合局见对应支
  /// 申子辰见酉 / 寅午戌见卯 / 巳酉丑见午 / 亥卯未见子
  static const _taoHua = {
    '申': '酉', '子': '酉', '辰': '酉',
    '寅': '卯', '午': '卯', '戌': '卯',
    '巳': '午', '酉': '午', '丑': '午',
    '亥': '子', '卯': '子', '未': '子',
  };

  /// 地支 → 方位
  static const _directions = {
    '子': '正北', '卯': '正东', '午': '正南', '酉': '正西',
    '寅': '东北偏东', '辰': '东南偏东', '巳': '东南偏南', '未': '西南偏南',
    '申': '西南偏西', '戌': '西北偏西', '亥': '西北偏北', '丑': '东北偏北',
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
    if (solar.year != year || solar.month != month || solar.day != day) {
      throw ArgumentError('无效日期：$dateStr');
    }
    if (year < 1901 || year > 2099) {
      throw ArgumentError('仅支持 1901-2099 年');
    }

    final lunar = solarToLunar(solar);
    // 年支
    final yearZhi = kDiZhi[(lunar.year - 4) % 12];
    // 日支
    final dayGz = baziDayGanZhi(solar);
    final dayZhi = dayGz[1];

    final taoHuaYear = _taoHua[yearZhi]!;
    final taoHuaDay = _taoHua[dayZhi]!;
    final direction = _directions[taoHuaYear]!;

    // 桃花旺年：流年地支为桃花支的年份
    final wangYears = <int>[];
    for (var y = DateTime.now().year; y < DateTime.now().year + 12; y++) {
      if (kDiZhi[(y - 4) % 12] == taoHuaYear) wangYears.add(y);
    }

    return [
      '【桃花测算】',
      '出生：$year 年 $month 月 $day 日（${lunar.ganZhiYear}年 ${lunar.shengXiao}）',
      '年支：$yearZhi → 桃花星：$taoHuaYear',
      '日支：$dayZhi → 日桃花：$taoHuaDay',
      '',
      '桃花方位：$direction',
      '桃花旺年：${wangYears.take(3).join('、')} 年（流年地支逢 $taoHuaYear）',
      '',
      '（咸池桃花按三合局推算，仅供娱乐参考；缘分天定，事在人为）',
    ].join('\n');
  }
}
