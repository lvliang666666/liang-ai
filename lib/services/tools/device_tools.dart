import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../tool_registry.dart';

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
