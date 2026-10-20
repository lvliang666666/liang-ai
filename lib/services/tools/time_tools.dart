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
