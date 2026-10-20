import 'dart:math';

import '../tool_registry.dart';

/// 随机数工具：范围内随机整数（可多个、可去重）
class RandomNumberTool extends ToolHandler {
  const RandomNumberTool();

  @override
  String get name => 'random_number';

  @override
  String get description =>
      '生成随机整数。min/max 为范围（含两端，默认 1-100），count 为个数（默认 1，最多 100），unique=true 时结果不重复（要求范围足够大）。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'min': {'type': 'number', 'description': '最小值（含），默认 1'},
          'max': {'type': 'number', 'description': '最大值（含），默认 100'},
          'count': {'type': 'number', 'description': '生成个数，默认 1，最多 100'},
          'unique': {'type': 'boolean', 'description': '是否不重复，默认 false'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final min = (arguments['min'] as num?)?.toInt() ?? 1;
    final max = (arguments['max'] as num?)?.toInt() ?? 100;
    final count = ((arguments['count'] as num?)?.toInt() ?? 1).clamp(1, 100);
    final unique = arguments['unique'] == true;

    if (min > max) throw ArgumentError('min（$min）不能大于 max（$max）');
    final range = max - min + 1;
    if (unique && count > range) {
      throw ArgumentError('不重复要求 count（$count）≤ 范围大小（$range）');
    }

    final rng = Random();
    final results = <int>[];
    if (unique) {
      // 范围不大时全量洗牌取前 count；范围大时用 Set 去重
      if (range <= count * 10) {
        final pool = [for (var i = min; i <= max; i++) i]..shuffle(rng);
        results.addAll(pool.take(count));
      } else {
        final seen = <int>{};
        while (results.length < count) {
          final v = min + rng.nextInt(range);
          if (seen.add(v)) results.add(v);
        }
      }
    } else {
      for (var i = 0; i < count; i++) {
        results.add(min + rng.nextInt(range));
      }
    }
    return '随机数（$min-$max${unique ? '，不重复' : ''}）：${results.join(', ')}';
  }
}

/// 随机抽取工具：从候选列表随机选一个或排序打乱
class RandomPickTool extends ToolHandler {
  const RandomPickTool();

  @override
  String get name => 'random_pick';

  @override
  String get description =>
      '从候选列表随机抽取。items 为候选列表（逗号分隔），count 为抽取个数（默认 1），shuffle=true 时返回全部打乱顺序（做决定/抽奖/随机排序）。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'items': {'type': 'string', 'description': '候选列表，逗号分隔，如 "红烧肉, 麻婆豆腐, 饺子"'},
          'count': {'type': 'number', 'description': '抽取个数，默认 1'},
          'shuffle': {'type': 'boolean', 'description': 'true 时打乱全部并返回（忽略 count）'},
        },
        'required': ['items'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final raw = arguments['items'] as String? ?? '';
    final items = raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (items.isEmpty) throw ArgumentError('items 为空，请提供逗号分隔的候选列表');
    if (items.length == 1) {
      return '只有一个候选：${items.first}';
    }

    final rng = Random();
    final shuffled = [...items]..shuffle(rng);

    if (arguments['shuffle'] == true) {
      return '随机排序：${shuffled.join(' → ')}';
    }
    final count = ((arguments['count'] as num?)?.toInt() ?? 1).clamp(1, items.length);
    final picked = shuffled.take(count).toList();
    return count == 1
        ? '随机选中：${picked.first}（共 ${items.length} 个候选）'
        : '随机选中 $count 项：${picked.join('、')}（共 ${items.length} 个候选）';
  }
}

/// 掷骰子/抛硬币工具
class DiceFlipTool extends ToolHandler {
  const DiceFlipTool();

  @override
  String get name => 'dice_flip';

  @override
  String get description =>
      '掷骰子或抛硬币。mode="dice" 掷骰子（sides 面数默认 6，count 个数默认 1）；mode="coin" 抛硬币（count 次数默认 1，最多 100）。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'mode': {
            'type': 'string',
            'enum': ['dice', 'coin'],
            'description': 'dice=掷骰子，coin=抛硬币',
          },
          'sides': {'type': 'number', 'description': '骰子面数，默认 6（仅 dice）'},
          'count': {'type': 'number', 'description': '次数，默认 1，最多 100'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final mode = (arguments['mode'] as String? ?? 'dice').trim().toLowerCase();
    final count = ((arguments['count'] as num?)?.toInt() ?? 1).clamp(1, 100);
    final rng = Random();

    switch (mode) {
      case 'dice':
        final sides = ((arguments['sides'] as num?)?.toInt() ?? 6).clamp(2, 1000);
        final rolls = [for (var i = 0; i < count; i++) rng.nextInt(sides) + 1];
        final sum = rolls.fold<int>(0, (a, b) => a + b);
        return count == 1
            ? '掷 ${sides} 面骰子：${rolls.first}'
            : '掷 ${sides} 面骰子 $count 次：${rolls.join(', ')}（总和 $sum）';
      case 'coin':
        final flips = [
          for (var i = 0; i < count; i++) rng.nextBool() ? '正面' : '反面'
        ];
        final heads = flips.where((f) => f == '正面').length;
        return count == 1
            ? '抛硬币：${flips.first}'
            : '抛硬币 $count 次：${flips.join('、')}（正面 $heads / 反面 ${count - heads}）';
      default:
        throw ArgumentError('未知模式 "$mode"，支持 dice / coin');
    }
  }
}
