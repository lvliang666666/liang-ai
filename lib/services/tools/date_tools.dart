import '../tool_registry.dart';

/// 日期计算工具：日期差 / 加减天数 / 星期几
class DateCalcTool extends ToolHandler {
  const DateCalcTool();

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  String get name => 'date_calc';

  @override
  String get description =>
      '日期计算。支持三种操作：op="diff" 计算两个日期相差天数；op="add" 日期加减 N 天（offset 可为负）；op="weekday" 查询日期是星期几。日期格式 yyyy-MM-dd。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'op': {
            'type': 'string',
            'enum': ['diff', 'add', 'weekday'],
            'description': '操作类型：diff=日期差，add=加减天数，weekday=星期几',
          },
          'date': {
            'type': 'string',
            'description': '日期，格式 yyyy-MM-dd（add/weekday 必填；diff 时为起始日期）',
          },
          'date2': {
            'type': 'string',
            'description': '第二个日期，格式 yyyy-MM-dd（仅 diff 需要）',
          },
          'offset': {
            'type': 'number',
            'description': '加减的天数，可为负（仅 add 需要）',
          },
        },
        'required': ['op'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final op = arguments['op'] as String? ?? '';
    switch (op) {
      case 'diff':
        final d1 = _parseDate(arguments['date'], 'date');
        final d2 = _parseDate(arguments['date2'], 'date2');
        final days = d2.difference(d1).inDays;
        return '${_fmt(d1)} 与 ${_fmt(d2)} 相差 $days 天'
            '（${days.abs() == days && days >= 0 ? '' : ''}$days）';
      case 'add':
        final d = _parseDate(arguments['date'], 'date');
        final offset = (arguments['offset'] as num?)?.toInt();
        if (offset == null) throw ArgumentError('add 操作缺少 offset 参数');
        final result = d.add(Duration(days: offset));
        final sign = offset >= 0 ? '+' : '';
        return '${_fmt(d)} $sign$offset 天 = ${_fmt(result)}（星期${_weekdays[result.weekday - 1]}）';
      case 'weekday':
        final d = _parseDate(arguments['date'], 'date');
        return '${_fmt(d)} 是星期${_weekdays[d.weekday - 1]}';
      default:
        throw ArgumentError('未知操作 "$op"，支持 diff / add / weekday');
    }
  }

  static DateTime _parseDate(Object? raw, String argName) {
    final text = raw?.toString().trim() ?? '';
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(text);
    if (m == null) {
      throw ArgumentError('参数 $argName 格式错误："${text.isEmpty ? '(空)' : text}"，应为 yyyy-MM-dd');
    }
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final date = DateTime(year, month, day);
    // DateTime 会静默进位（如 2026-02-31 → 3 月 3 日），这里校验回原值
    if (date.year != year || date.month != month || date.day != day) {
      throw ArgumentError('日期不存在：$text');
    }
    return date;
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
