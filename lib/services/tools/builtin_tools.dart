import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../tool_registry.dart';

/// 当前时间工具：返回设备本地日期时间/星期/时区
class GetCurrentTimeTool extends ToolHandler {
  const GetCurrentTimeTool();

  @override
  String get name => 'get_current_time';

  @override
  String get description => '获取设备当前的本地日期、时间、星期和时区。当用户询问现在几点、今天日期、星期几时使用。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final now = DateTime.now();
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final h = offset.inHours.abs().toString().padLeft(2, '0');
    final m = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '当前时间：${now.year}年${now.month}月${now.day}日 '
        '星期${weekdays[now.weekday - 1]} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} '
        '（UTC$sign$h:$m）';
  }
}

/// 设备信息工具：型号/系统版本/电池电量
class GetDeviceInfoTool extends ToolHandler {
  const GetDeviceInfoTool();

  static final Battery _battery = Battery();

  @override
  String get name => 'get_device_info';

  @override
  String get description => '获取设备信息：型号、Android 版本、电池电量与充电状态。当用户询问设备情况、电量时使用。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final info = <String>[];
    if (await _isAndroid()) {
      final android = await DeviceInfoPlugin().androidInfo;
      info.add('设备型号：${android.manufacturer} ${android.model}');
      info.add('系统版本：Android ${android.version.release}（API ${android.version.sdkInt}）');
    } else {
      info.add('设备：非 Android 平台（测试/桌面环境）');
    }
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final stateText = switch (state) {
        BatteryState.charging => '充电中',
        BatteryState.full => '已充满',
        BatteryState.discharging => '放电中',
        BatteryState.connectedNotCharging => '已连接未充电',
        _ => '未知',
      };
      info.add('电量：$level%（$stateText）');
    } catch (_) {
      info.add('电量：不可用');
    }
    return info.join('\n');
  }

  static Future<bool> _isAndroid() async {
    try {
      await DeviceInfoPlugin().androidInfo;
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 计算器工具：安全的四则运算表达式求值（不使用 eval，自写递归下降解析）
class CalculateTool extends ToolHandler {
  const CalculateTool();

  @override
  String get name => 'calculate';

  @override
  String get description => '计算数学表达式。支持 + - * / % 和括号。当需要精确计算时使用（不要心算）。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'expression': {
            'type': 'string',
            'description': '数学表达式，如 "1 + 2 * 3" 或 "(4 + 5) / 3"',
          },
        },
        'required': ['expression'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final expr = (arguments['expression'] as String? ?? '').trim();
    if (expr.isEmpty) {
      throw ArgumentError('缺少 expression 参数');
    }
    final value = _evaluate(expr);
    // 整数结果不带小数点
    final text = value == value.roundToDouble() && value.abs() < 1e15
        ? value.round().toString()
        : value.toString();
    return '$expr = $text';
  }

  /// 递归下降解析：expr = term (('+'|'-') term)*
  static double _evaluate(String expr) {
    final parser = _Parser(expr.replaceAll(' ', ''));
    final result = parser.parseExpression();
    parser.expectEnd();
    return result;
  }
}

class _Parser {
  _Parser(this._src);
  final String _src;
  int _pos = 0;

  double parseExpression() => _parseAdditive();

  void expectEnd() {
    if (_pos < _src.length) {
      throw FormatException('表达式在位置 $_pos 处有无法解析的字符 "${_src[_pos]}"');
    }
  }

  double _parseAdditive() {
    var value = _parseMultiplicative();
    while (_pos < _src.length) {
      final op = _src[_pos];
      if (op == '+') {
        _pos++;
        value += _parseMultiplicative();
      } else if (op == '-') {
        _pos++;
        value -= _parseMultiplicative();
      } else {
        break;
      }
    }
    return value;
  }

  double _parseMultiplicative() {
    var value = _parseUnary();
    while (_pos < _src.length) {
      final op = _src[_pos];
      if (op == '*') {
        _pos++;
        value *= _parseUnary();
      } else if (op == '/') {
        _pos++;
        final divisor = _parseUnary();
        if (divisor == 0) throw ArgumentError('除数不能为零');
        value /= divisor;
      } else if (op == '%') {
        _pos++;
        final divisor = _parseUnary();
        if (divisor == 0) throw ArgumentError('除数不能为零');
        value %= divisor;
      } else {
        break;
      }
    }
    return value;
  }

  double _parseUnary() {
    if (_pos < _src.length && _src[_pos] == '-') {
      _pos++;
      return -_parseUnary();
    }
    if (_pos < _src.length && _src[_pos] == '+') {
      _pos++;
      return _parseUnary();
    }
    return _parsePrimary();
  }

  double _parsePrimary() {
    if (_pos >= _src.length) {
      throw FormatException('表达式意外结束');
    }
    if (_src[_pos] == '(') {
      _pos++;
      final value = _parseAdditive();
      if (_pos >= _src.length || _src[_pos] != ')') {
        throw FormatException('括号不匹配');
      }
      _pos++;
      return value;
    }
    final start = _pos;
    while (_pos < _src.length &&
        (_src.codeUnitAt(_pos) >= 0x30 && _src.codeUnitAt(_pos) <= 0x39 ||
            _src[_pos] == '.')) {
      _pos++;
    }
    if (_pos == start) {
      throw FormatException('位置 $start 处的字符 "${_src[start]}" 无法解析');
    }
    final numText = _src.substring(start, _pos);
    final value = double.tryParse(numText);
    if (value == null) {
      throw FormatException('无法解析数字 "$numText"');
    }
    return value;
  }
}

/// 首批内置工具（零权限零凭据）
const builtinTools = <ToolHandler>[
  GetCurrentTimeTool(),
  GetDeviceInfoTool(),
  CalculateTool(),
];
