import '../tool_registry.dart';

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
