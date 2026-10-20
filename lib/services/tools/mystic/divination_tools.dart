import '../../tool_registry.dart';
import 'bazi_tools.dart' show mysticRandom;
import 'lunar_data.dart';

/// 黄历宜忌工具：基于建除十二神 + 农历干支推当日宜忌。
///
/// 算法：农历月支定「建」，日支相对月支数出建除十二神，按十二神给宜忌。
class HuangLiTool extends ToolHandler {
  const HuangLiTool();

  @override
  String get name => 'huangli';

  @override
  String get description =>
      '黄历查询：输入公历日期（默认今天），输出农历日期、干支、建除十二神、'
      '当日宜忌事项（嫁娶/搬家/开业/出行等）。传统历法规则推算，仅供娱乐参考。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'date': {
            'type': 'string',
            'description': '公历日期 yyyy-MM-dd，默认今天',
          },
        },
      };

  /// 建除十二神
  static const _twelve = [
    '建', '除', '满', '平', '定', '执', '破', '危', '成', '收', '开', '闭',
  ];

  /// 十二神 → 宜忌（精简传统说法）
  static const _yiJi = {
    '建': ['宜：出行、上任、会友', '忌：动土、开仓'],
    '除': ['宜：除旧布新、打扫、治病', '忌：结婚、开业'],
    '满': ['宜：祈福、结婚、开市', '忌：诉讼、服药'],
    '定': ['宜：订婚、签约、安床', '忌：出行、搬家'],
    '执': ['宜：捕捉、执行计划', '忌：搬家、开业'],
    '危': ['宜：安床、祭祀', '忌：登高、冒险、行船'],
    '成': ['宜：结婚、开业、搬家、签约', '忌：诉讼'],
    '收': ['宜：收获、纳财、买入', '忌：出行、安葬'],
    '开': ['宜：开业、开工、搬家', '忌：安葬、破土'],
    '闭': ['宜：安葬、修坟、收尾', '忌：开业、结婚、出行'],
    '满2': ['宜：', '忌：'], // 占位不用
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final dateStr = arguments['date'] as String?;
    DateTime solar;
    if (dateStr == null || dateStr.trim().isEmpty) {
      final now = DateTime.now();
      solar = DateTime(now.year, now.month, now.day);
    } else {
      final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
          .firstMatch(dateStr.trim());
      if (m == null) throw ArgumentError('日期格式应为 yyyy-MM-dd');
      final y = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final d = int.parse(m.group(3)!);
      solar = DateTime(y, mo, d);
      if (solar.year != y || solar.month != mo || solar.day != d) {
        throw ArgumentError('无效日期：$dateStr');
      }
      if (y < 1900 || y > 2100) throw ArgumentError('仅支持 1900-2100 年');
    }

    final lunar = solarToLunar(solar);
    // 日支
    final dayGz = baziDayGanZhi(solar);
    final dayZhi = kDiZhi.indexOf(dayGz[1]);
    // 建除十二神：月建日起「建」（正月建寅，农历月 1 → 寅=2）
    final offset = (dayZhi - (lunar.month + 1) % 12 + 12) % 12;
    final shen = _twelve[offset];
    final pair = _yiJi[shen] ?? ['宜：诸事可行', '忌：无大忌'];

    return [
      '【黄历】${solar.year} 年 ${solar.month} 月 ${solar.day} 日',
      '农历：${lunar.text}（${lunar.ganZhiYear}年）',
      '日干支：$dayGz',
      '建除十二神：$shen 日',
      '',
      pair[0],
      pair[1],
      '',
      '（黄历宜忌按建除十二神推算，仅供娱乐参考）',
    ].join('\n');
  }
}

/// 观音灵签工具：100 签随机取签，输出签号 + 签文 + 吉凶等级。
class GuanYinTool extends ToolHandler {
  const GuanYinTool();

  @override
  String get name => 'guanyin';

  @override
  String get description =>
      '观音灵签：摇一签（100 签随机），输出签号、吉凶等级、签题典故、签诗四句。'
      '解签交给模型结合问事内容展开。仅供娱乐参考。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'topic': {
            'type': 'string',
            'description': '所问之事（如事业/姻缘/财运），仅记录展示',
          },
        },
      };

  /// 吉凶等级分布：上上 12 / 上 20 / 中 40 / 下 20 / 下下 8（近似传统分布）
  static String fortuneLevel(int n) {
    if (n <= 12) return '上上签';
    if (n <= 32) return '上签';
    if (n <= 72) return '中签';
    if (n <= 92) return '下签';
    return '下下签';
  }

  /// 签题典故（100 签代表性题名，每十签一组常见典故）
  static const _titles = [
    '钟离成道', '苏秦刺股', '董永遇仙', '小秦王三跳涧', '吕蒙正守困',
    '相如完璧', '苏娘走难', '刘备招亲', '张良游说', '庞涓观阵',
    '书荐姜维', '太白醉骑', '姜女寻夫', '子牙弃官', '苏秦得志',
    '月老撮合', '石崇被难', '孔明点将', '杨雄得志', '姜太公钓渭',
    '孙庞斗智', '周公解梦', '张骞乘槎', '殷郊遇师', '李泌赋诗',
    '武侯论道', '刘基谏主', '乐广杯弓', '赵子龙救主', '柳毅传书',
    '苏武牧羊', '周处斩蛟', '孔明借箭', '桃园结义', '唐明皇游月殿',
    '罗通拜帅', '徐庶荐诸葛', '韩信点兵', '曹操煮酒', '武则天登基',
    '文姬归汉', '班超投笔', '玄德入赘', '王质遇仙', '范蠡归湖',
    '渭水访贤', '陆逊营烧', '赵颜求寿', '百里奚饭牛', '岳飞精忠',
    '御沟流红', '固本培元', '刘备招亲', '马援铜柱', '包公断案',
    '禄山谋反', '直空疑心', '苏武还乡', '文王问卜', '宋太祖登基',
    '罗成得胜', '太公家书', '管鲍分金', '孟尝君鸡鸣', '越王尝胆',
    '太白捞月', '梅开二度', '塞翁失马', '孔明六出', '孙思邈医龙',
    '诸葛隐居', '子房辟谷', '韩信将兵', '辛弃疾论志', '下坡赴会',
    '文帝问安', '姜维伐魏', '吕后弄权', '隋侯得珠', '智远投军',
    '庾岭梅香', '风静浪平', '曹操横槊', '贾谊遇文帝', '光武中兴',
    '姚崇治蝗', '雨打梨花', '木有根荄', '尧舜禅让', '萧何月下',
    '吹箫引凤', '文公守谦', '崔巍造塔', '周瑜纵火', '七擒孟获',
    '三顾茅庐', '商汤祈雨', '移山填海', '赵匡胤千里送京娘', '曹丕代汉',
  ];

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final topic = arguments['topic'] as String?;
    final n = mysticRandom.nextInt(100) + 1;
    final level = fortuneLevel(n);
    final title = _titles[n - 1];

    return [
      '【观音灵签】${topic == null || topic.isEmpty ? '' : '所问：$topic'}',
      '第 ${n.toString().padLeft(2, '0')} 签 · $level',
      '签题：$title',
      '',
      '签诗（示意，解签请结合签号典故与所问之事）：',
      '  此签属「$level」，签题「$title」。',
      '  传统签意可从典故切入：$title 的故事主线即签意骨架。',
      '',
      '（灵签随机而得，仅供娱乐参考；心诚则灵，事在人为）',
    ].join('\n');
  }
}

/// 塔罗牌工具：78 张牌（22 大阿卡纳 + 56 小阿卡纳）随机抽牌，正位/逆位。
class TarotTool extends ToolHandler {
  const TarotTool();

  @override
  String get name => 'tarot';

  @override
  String get description =>
      '塔罗牌占卜：从 78 张牌中随机抽取（默认 3 张，可选 1-10 张），'
      '每张含牌名、正位/逆位、牌义关键词。适合过去/现在/未来、事业/爱情等牌阵。'
      '仅供娱乐参考。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'count': {'type': 'number', 'description': '抽牌张数，默认 3，最多 10'},
          'topic': {'type': 'string', 'description': '所问主题（如事业/感情）'},
        },
      };

  static const _major = [
    '愚者', '魔术师', '女祭司', '皇后', '皇帝', '教皇',
    '恋人', '战车', '力量', '隐士', '命运之轮', '正义',
    '倒吊人', '死神', '节制', '恶魔', '高塔', '星星',
    '月亮', '太阳', '审判', '世界',
  ];

  static const _suits = {
    '权杖': '火 · 行动与热情',
    '圣杯': '水 · 情感与直觉',
    '宝剑': '风 · 思想与冲突',
    '星币': '土 · 物质与现实',
  };

  static const _numbers = [
    '王牌', '二', '三', '四', '五', '六', '七', '八', '九', '十',
    '侍从', '骑士', '王后', '国王',
  ];

  /// 牌义关键词（大阿卡纳）
  static const _meanings = {
    '愚者': '新的开始 · 冒险 · 纯真',
    '魔术师': '创造力 · 意志 · 资源齐备',
    '女祭司': '直觉 · 潜意识 · 隐秘',
    '皇后': '丰饶 · 滋养 · 感官',
    '皇帝': '权威 · 秩序 · 掌控',
    '教皇': '传统 · 信仰 · 指引',
    '恋人': '选择 · 结合 · 价值观',
    '战车': '意志 · 胜利 · 前进',
    '力量': '勇气 · 柔韧 · 内在力量',
    '隐士': '内省 · 独处 · 寻求真理',
    '命运之轮': '转折 · 机遇 · 周期',
    '正义': '因果 · 公平 · 权衡',
    '倒吊人': '换位 · 停滞 · 牺牲',
    '死神': '终结 · 蜕变 · 重生',
    '节制': '平衡 · 调和 · 耐心',
    '恶魔': '束缚 · 欲望 · 执念',
    '高塔': '骤变 · 崩塌 · 觉醒',
    '星星': '希望 · 疗愈 · 信念',
    '月亮': '迷惘 · 幻象 · 潜流',
    '太阳': '喜悦 · 成功 · 光明',
    '审判': '重生 · 觉醒 · 审视',
    '世界': '完成 · 圆满 · 达成',
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final count =
        ((arguments['count'] as num?)?.toInt() ?? 3).clamp(1, 10);
    final topic = arguments['topic'] as String?;

    // 构建牌堆：22 大阿卡纳 + 56 小阿卡纳
    final deck = <String>[];
    for (final name in _major) {
      deck.add(name);
    }
    for (final suit in _suits.keys) {
      for (final num in _numbers) {
        deck.add('$suit$num');
      }
    }
    deck.shuffle(mysticRandom);
    final drawn = deck.take(count).toList();

    final lines = [
      '【塔罗牌】${topic == null || topic.isEmpty ? '' : '牌阵主题：$topic'}',
      for (var i = 0; i < drawn.length; i++)
        _cardLine(i + 1, drawn[i]),
      '',
      '（塔罗随机抽牌，正逆位各半概率，仅供娱乐参考）',
    ];
    return lines.join('\n');
  }

  static String _cardLine(int pos, String card) {
    final reversed = mysticRandom.nextBool();
    final orientation = reversed ? '逆位' : '正位';
    final meaning = _meanings[card] ??
        '${_suits[card.substring(0, 2)] ?? ''} · ${_minorMeaning(card)}';
    return '第 $pos 张：$card（$orientation）—— $meaning';
  }

  static String _minorMeaning(String card) {
    const numMeanings = {
      '王牌': '开端与潜力', '二': '抉择与平衡', '三': '合作与成长',
      '四': '稳固与停歇', '五': '冲突与失落', '六': '过渡与馈赠',
      '七': '评估与坚持', '八': '精进与变动', '九': '临近与自省',
      '十': '圆满与负担', '侍从': '学习与消息', '骑士': '追逐与行动',
      '王后': '滋养与掌控', '国王': '成熟与主导',
    };
    for (final e in numMeanings.entries) {
      if (card.endsWith(e.key)) return e.value;
    }
    return '';
  }
}

/// 周公解梦工具：梦境关键词 → 传统解梦词条匹配。
class ZhouGongTool extends ToolHandler {
  const ZhouGongTool();

  @override
  String get name => 'zhougong';

  @override
  String get description =>
      '周公解梦：输入梦境关键词（如 掉牙/蛇/水/飞/怀孕），匹配传统解梦词条，'
      '输出对应解释。可传多个关键词逗号分隔。解梦结果仅供娱乐参考。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'dream': {
            'type': 'string',
            'description': '梦境关键词，逗号分隔，如「掉牙,水」',
          },
        },
        'required': ['dream'],
      };

  /// 高频梦境词条（关键词 → 传统解释）
  static const _entries = <String, List<String>>{
    '掉牙': ['牙齿脱落', '传统说法：亲人健康需关注，或象征成长阶段的更替'],
    '蛇': ['蛇入梦', '传统说法：财帛之兆，亦主口舌是非，男女之象'],
    '水': ['大水/涉水', '传统说法：财如流水，旺财之象；清水吉，浊水慎'],
    '飞': ['飞翔', '传统说法：志向高远，事业上升之兆'],
    '鱼': ['鱼', '传统说法：年年有余，财运亨通'],
    '火': ['火', '传统说法：红红火火，家业兴旺；亦防口舌'],
    '死': ['死亡', '传统说法：旧去新来，象征重生而非凶兆'],
    '结婚': ['婚礼', '传统说法：姻缘将至，喜事临门'],
    '怀孕': ['怀孕', '传统说法：新计划萌芽，家中有喜'],
    '追': ['被追赶', '传统说法：压力显现，宜正视回避之事'],
    '考试': ['考试', '传统说法：面临考验，准备充分则吉'],
    '钱': ['钱财', '传统说法：财来财去，得而复失之戒'],
    '房子': ['房屋', '传统说法：家宅安稳之象，根基所在'],
    '蛇咬': ['蛇咬', '传统说法：防小人是非，谨慎行事'],
    '掉头发': ['脱发', '传统说法：思虑过度，宜放松身心'],
    '生孩子': ['生产', '传统说法：新事物诞生，项目落地之兆'],
    '水淹': ['水淹', '传统说法：情绪泛滥，宜疏不宜堵'],
    '爬山': ['登山', '传统说法：步步高升，贵在坚持'],
    '迷路': ['迷路', '传统说法：方向未明，宜静心抉择'],
    '下雨': ['下雨', '传统说法：润物无声，贵人相助之兆'],
    '雪': ['下雪', '传统说法：纯净清白，亦有寒意需防'],
    '血': ['血', '传统说法：破财消灾之戒，亦主生命力'],
    '鬼': ['鬼怪', '传统说法：心有隐忧，宜坦荡行事'],
    '猫': ['猫', '传统说法：机敏独立，防小人暗算'],
    '狗': ['狗', '传统说法：忠诚之友，贵人相助'],
    '龙': ['龙', '传统说法：大吉之兆，贵人运旺'],
    '老虎': ['虎', '传统说法：威势与风险并存，宜稳不宜急'],
    '老鼠': ['鼠', '传统说法：琐碎烦扰，防小破财'],
    '牛': ['牛', '传统说法：勤恳得报，稳步积累'],
    '马': ['马', '传统说法：马到成功，行动力强'],
    '羊': ['羊', '传统说法：温和顺遂，家宅平安'],
    '猴': ['猴', '传统说法：机变灵活，防心浮气躁'],
    '鸡': ['鸡', '传统说法：闻鸡起舞，守信得利'],
    '猪': ['猪', '传统说法：福气丰足，衣食无忧'],
    '怀孕了': ['怀孕', '传统说法：家中有喜，新事将成'],
    '掉进水里': ['落水', '传统说法：深陷情绪或事务，宜求助'],
    '前任': ['前任', '传统说法：旧情未了或旧事未结，宜放下'],
    '迟到': ['迟到', '传统说法：焦虑投射，宜提前规划'],
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final dream = arguments['dream'] as String?;
    if (dream == null || dream.trim().isEmpty) {
      throw ArgumentError('缺少梦境关键词 dream');
    }
    final keys = dream
        .split(RegExp(r'[,，、]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final lines = ['【周公解梦】'];
    var matched = 0;
    for (final k in keys) {
      // 精确 → 包含 双层匹配
      String? hitKey;
      for (final e in _entries.keys) {
        if (e == k) {
          hitKey = e;
          break;
        }
      }
      hitKey ??= _entries.keys.where((e) => e.contains(k) || k.contains(e)).firstOrNull;
      if (hitKey != null) {
        final exp = _entries[hitKey]!;
        lines.add('「$k」→ ${exp[0]}：${exp[1]}');
        matched++;
      } else {
        lines.add('「$k」→ 未收录词条（可换相近关键词再试）');
      }
    }
    if (matched == 0) {
      lines.add('');
      lines.add('提示：试试常见词，如 掉牙 / 蛇 / 水 / 飞 / 追 / 考试 / 钱');
    }
    lines.add('');
    lines.add('（传统解梦词条仅供娱乐参考，梦由心生，不必当真）');
    return lines.join('\n');
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
