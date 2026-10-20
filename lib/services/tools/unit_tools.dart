import 'dart:math';

import '../tool_registry.dart';

/// 单位换算工具：长度 / 重量 / 温度 / 数据大小 / 速度
class UnitConvertTool extends ToolHandler {
  const UnitConvertTool();

  @override
  String get name => 'unit_convert';

  @override
  String get description =>
      '单位换算。类别 category：length（长度 m/km/cm/mm/mile/foot/inch）、weight（重量 kg/g/ton/pound/ounce）、temperature（温度 C/F/K）、data（数据大小 B/KB/MB/GB/TB）、speed（速度 mps/kmh/knot/mph）。value + from + to。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'category': {
            'type': 'string',
            'enum': ['length', 'weight', 'temperature', 'data', 'speed'],
            'description': '换算类别',
          },
          'value': {'type': 'number', 'description': '数值'},
          'from': {'type': 'string', 'description': '源单位'},
          'to': {'type': 'string', 'description': '目标单位'},
        },
        'required': ['category', 'value', 'from', 'to'],
      };

  /// 长度：基准米
  static const _length = {
    'm': 1.0,
    'km': 1000.0,
    'dm': 0.1,
    'cm': 0.01,
    'mm': 0.001,
    'mile': 1609.344,
    'yard': 0.9144,
    'foot': 0.3048,
    'inch': 0.0254,
    'nautical_mile': 1852.0,
  };

  /// 重量：基准千克
  static const _weight = {
    'kg': 1.0,
    'g': 0.001,
    'mg': 1e-6,
    'ton': 1000.0,
    'pound': 0.45359237,
    'ounce': 0.028349523125,
    'jin': 0.5, // 市斤
    'liang': 0.05, // 市两
  };

  /// 数据大小：基准字节（1024 进制）
  static const _data = {
    'B': 1.0,
    'KB': 1024.0,
    'MB': 1024.0 * 1024,
    'GB': 1024.0 * 1024 * 1024,
    'TB': 1024.0 * 1024 * 1024 * 1024,
    'PB': 1024.0 * 1024 * 1024 * 1024 * 1024,
  };

  /// 速度：基准 米/秒
  static const _speed = {
    'mps': 1.0, // 米/秒
    'kmh': 1 / 3.6, // 千米/小时
    'mph': 0.44704, // 英里/小时
    'knot': 1852.0 / 3600, // 节
    'fts': 0.3048, // 英尺/秒
  };

  /// 单位别名归一（大小写不敏感）
  static String _norm(String unit) => switch (unit.trim().toLowerCase()) {
        'c' || 'celsius' || '°c' || '摄氏度' => 'C',
        'f' || 'fahrenheit' || '°f' || '华氏度' => 'F',
        'k' || 'kelvin' || '开尔文' => 'K',
        'meter' || 'meters' => 'm',
        'kilometer' || 'kilometers' => 'km',
        'centimeter' || 'centimeters' => 'cm',
        'millimeter' || 'millimeters' => 'mm',
        'mile(s)' => 'mile',
        'foot' || 'feet' || 'ft' => 'foot',
        'inch' || 'inches' => 'inch',
        'kilogram' || 'kilograms' => 'kg',
        'gram' || 'grams' => 'g',
        'pound' || 'pounds' || 'lb' || 'lbs' => 'pound',
        'ounce' || 'ounces' || 'oz' => 'ounce',
        'byte' || 'bytes' => 'B',
        'kilobyte' => 'KB',
        'megabyte' => 'MB',
        'gigabyte' => 'GB',
        'terabyte' => 'TB',
        _ => unit.trim(),
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final category = (arguments['category'] as String? ?? '').trim().toLowerCase();
    final value = arguments['value'] as num?;
    final from = arguments['from'] as String? ?? '';
    final to = arguments['to'] as String? ?? '';
    if (value == null) throw ArgumentError('缺少 value 参数');

    switch (category) {
      case 'temperature':
        return _temperature(value.toDouble(), _norm(from), _norm(to));
      case 'length':
        return _linear(value.toDouble(), _norm(from), _norm(to), _length, '长度');
      case 'weight':
        return _linear(value.toDouble(), _norm(from), _norm(to), _weight, '重量');
      case 'data':
        return _linear(value.toDouble(), _norm(from), _norm(to), _data, '数据大小');
      case 'speed':
        return _linear(value.toDouble(), _norm(from), _norm(to), _speed, '速度');
      default:
        throw ArgumentError('未知类别 "$category"，支持 length/weight/temperature/data/speed');
    }
  }

  /// 线性换算（同基准系数表）
  static String _linear(double value, String from, String to,
      Map<String, double> table, String label) {
    final f = table[from];
    final t = table[to];
    if (f == null) throw ArgumentError('$label不支持单位 "$from"，可用：${table.keys.join(" / ")}');
    if (t == null) throw ArgumentError('$label不支持单位 "$to"，可用：${table.keys.join(" / ")}');
    final result = value * f / t;
    return '${_num(value)} $from = ${_num(result)} $to';
  }

  /// 温度换算（经摄氏度中转）
  static String _temperature(double value, String from, String to) {
    const units = ['C', 'F', 'K'];
    if (!units.contains(from)) {
      throw ArgumentError('温度不支持单位 "$from"，可用：C / F / K');
    }
    if (!units.contains(to)) {
      throw ArgumentError('温度不支持单位 "$to"，可用：C / F / K');
    }
    // 先转摄氏
    final celsius = switch (from) {
      'C' => value,
      'F' => (value - 32) * 5 / 9,
      'K' => value - 273.15,
      _ => throw StateError('unreachable'),
    };
    final result = switch (to) {
      'C' => celsius,
      'F' => celsius * 9 / 5 + 32,
      'K' => celsius + 273.15,
      _ => throw StateError('unreachable'),
    };
    return '${_num(value)}°${from == 'C' ? 'C' : from} = ${_num(result)}°$to';
  }

  /// 数值格式化：整数不带小数点，小数保留最多 6 位有效
  static String _num(double v) {
    if (v.isNaN || v.isInfinite) return v.toString();
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
    // 保留 6 位小数并去掉尾随 0
    var text = v.toStringAsFixed(6);
    text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return text;
  }
}

/// 进制转换工具：2-36 进制互转
class BaseConvertTool extends ToolHandler {
  const BaseConvertTool();

  @override
  String get name => 'base_convert';

  @override
  String get description =>
      '进制转换。把整数在 2-36 进制之间互转：value 为源进制的数字字符串（支持负数），from/to 为进制（2-36，10 以上用字母 A-Z 表示）。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'value': {'type': 'string', 'description': '源进制的数字字符串，如 "FF" 或 "-1010"'},
          'from': {'type': 'number', 'description': '源进制（2-36）'},
          'to': {'type': 'number', 'description': '目标进制（2-36）'},
        },
        'required': ['value', 'from', 'to'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final value = (arguments['value'] as String? ?? '').trim();
    final from = (arguments['from'] as num?)?.toInt();
    final to = (arguments['to'] as num?)?.toInt();
    if (from == null || to == null) throw ArgumentError('缺少 from/to 参数');
    if (from < 2 || from > 36) throw ArgumentError('from 进制须在 2-36 之间，收到 $from');
    if (to < 2 || to > 36) throw ArgumentError('to 进制须在 2-36 之间，收到 $to');
    if (value.isEmpty) throw ArgumentError('缺少 value 参数');

    var negative = false;
    var digits = value;
    if (digits.startsWith('-')) {
      negative = true;
      digits = digits.substring(1);
    } else if (digits.startsWith('+')) {
      digits = digits.substring(1);
    }
    if (digits.isEmpty) throw ArgumentError('value 缺少数字部分');

    // 按源进制解析（BigInt 防溢出）
    var acc = BigInt.zero;
    final base = BigInt.from(from);
    for (var i = 0; i < digits.length; i++) {
      final d = _digitValue(digits[i]);
      if (d == null || d >= from) {
        throw ArgumentError('字符 "${digits[i]}" 不是 ${from} 进制数字');
      }
      acc = acc * base + BigInt.from(d);
    }

    // 转目标进制
    if (acc == BigInt.zero) {
      return '$value（${from}进制）= 0（${to}进制）';
    }
    final targetBase = BigInt.from(to);
    const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    var out = '';
    var rest = acc;
    while (rest > BigInt.zero) {
      final idx = (rest % targetBase).toInt();
      out = chars[idx] + out;
      rest = rest ~/ targetBase;
    }
    final sign = negative ? '-' : '';
    return '$value（${from}进制）= $sign$out（${to}进制）';
  }

  /// 单字符数值：0-9 / A-Z / a-z
  static int? _digitValue(String ch) {
    final code = ch.codeUnitAt(0);
    if (code >= 0x30 && code <= 0x39) return code - 0x30; // 0-9
    if (code >= 0x41 && code <= 0x5A) return code - 0x41 + 10; // A-Z
    if (code >= 0x61 && code <= 0x7A) return code - 0x61 + 10; // a-z
    return null;
  }
}

/// 数学函数工具：sqrt/pow/log/sin/cos/tan 等
class MathFunctionTool extends ToolHandler {
  const MathFunctionTool();

  @override
  String get name => 'math_function';

  @override
  String get description =>
      '高级数学函数计算。fn 可选：sqrt（平方根）、pow（x 的 y 次方）、log（自然对数）、log10、exp、sin/cos/tan（弧度）、asin/acos/atan、abs、round、floor、ceil。单参数函数只需 x；pow 需要 x 和 y。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'fn': {
            'type': 'string',
            'enum': [
              'sqrt', 'pow', 'log', 'log10', 'exp',
              'sin', 'cos', 'tan', 'asin', 'acos', 'atan',
              'abs', 'round', 'floor', 'ceil',
            ],
            'description': '函数名',
          },
          'x': {'type': 'number', 'description': '输入值'},
          'y': {'type': 'number', 'description': '第二个输入值（仅 pow 需要）'},
        },
        'required': ['fn', 'x'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final fn = (arguments['fn'] as String? ?? '').trim().toLowerCase();
    final x = arguments['x'] as num?;
    if (x == null) throw ArgumentError('缺少 x 参数');
    final xd = x.toDouble();

    double result;
    var expr = '';
    switch (fn) {
      case 'sqrt':
        if (xd < 0) throw ArgumentError('sqrt 不支持负数');
        result = sqrt(xd);
        expr = '√$xd';
      case 'pow':
        final y = arguments['y'] as num?;
        if (y == null) throw ArgumentError('pow 需要 y 参数');
        result = pow(xd, y.toDouble()).toDouble();
        expr = '$xd^$y';
      case 'log':
        if (xd <= 0) throw ArgumentError('log 要求 x > 0');
        result = log(xd);
        expr = 'ln($xd)';
      case 'log10':
        if (xd <= 0) throw ArgumentError('log10 要求 x > 0');
        result = log(xd) / ln10;
        expr = 'log10($xd)';
      case 'exp':
        result = exp(xd);
        expr = 'e^$xd';
      case 'sin':
        result = sin(xd);
        expr = 'sin($xd)';
      case 'cos':
        result = cos(xd);
        expr = 'cos($xd)';
      case 'tan':
        result = tan(xd);
        expr = 'tan($xd)';
      case 'asin':
        if (xd < -1 || xd > 1) throw ArgumentError('asin 要求 x 在 [-1, 1]');
        result = asin(xd);
        expr = 'asin($xd)';
      case 'acos':
        if (xd < -1 || xd > 1) throw ArgumentError('acos 要求 x 在 [-1, 1]');
        result = acos(xd);
        expr = 'acos($xd)';
      case 'atan':
        result = atan(xd);
        expr = 'atan($xd)';
      case 'abs':
        result = xd.abs();
        expr = '|$xd|';
      case 'round':
        result = xd.roundToDouble();
        expr = 'round($xd)';
      case 'floor':
        result = xd.floorToDouble();
        expr = 'floor($xd)';
      case 'ceil':
        result = xd.ceilToDouble();
        expr = 'ceil($xd)';
      default:
        throw ArgumentError('未知函数 "$fn"');
    }
    return '$expr = ${_fmt(result)}';
  }

  static String _fmt(double v) {
    if (v.isNaN) return 'NaN（结果不是实数）';
    if (v.isInfinite) return v > 0 ? '∞' : '-∞';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
    var text = v.toStringAsFixed(10);
    text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return text;
  }
}
