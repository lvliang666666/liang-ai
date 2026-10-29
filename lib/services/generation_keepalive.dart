import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// I13 后台生成保活：流式生成期间维持前台服务 + WakeLock
///
/// **问题**：Android 对后台 App 有进程冻结（Cached Apps Freezer）+
/// 网络挂起两层限制，SSE 长连接切后台几秒内被掐断——回来只剩半截
/// 内容 + 续传胶囊（I10 兜底生效但体验是「重跑」）。
///
/// **方案**：生成开始 → 启动 dataSync 前台服务（进程不被冻结、网络
/// 不断，插件自持 PARTIAL_WAKE_LOCK 保 CPU）+ WakeLock（用户停留
/// App 内观看时屏幕不熄灭）；生成结束/出错/手动停止 → 全部释放。
/// 长时后台（用户主动离开）由系统 6h dataSync 上限自然兜底，超时后
/// 降级为 I10 断流续传。
///
/// **克制呈现**：通知栏常驻提示是前台服务的系统代价，提供设置开关
/// （默认开）；关闭开关 = 不启动前台服务（纯靠系统宽限，短时切后台
/// 可能仍断流，但无通知打扰）。
///
/// 所有方法静默容错：插件异常（模拟器/桌面/权限拒绝）只 debugPrint，
/// 绝不影响生成主流程。
class GenerationKeepalive {
  GenerationKeepalive._();

  static bool _active = false;
  static bool _serviceInited = false;

  /// 当前是否处于保活态（测试/调试用）
  static bool get active => _active;

  /// 最近一次 start 收到的通知开关（测试断言用）
  static bool? lastNotificationEnabled;

  /// 重置内部状态（仅测试用：隔离用例间状态）
  @visibleForTesting
  static void resetForTest() {
    _active = false;
    _serviceInited = false;
    lastNotificationEnabled = null;
  }

  /// 生成开始：启动前台服务 + WakeLock
  ///
  /// [notificationEnabled] 通知开关（宿主从 SettingsService 读）；
  /// [title] 通知标题（会话名）；[content] 通知正文（「正在生成回答…」）。
  static Future<void> start({
    required bool notificationEnabled,
    String title = 'Liang AI',
    String content = '正在生成回答…',
  }) async {
    if (_active) return;
    _active = true;
    lastNotificationEnabled = notificationEnabled;
    try {
      if (notificationEnabled) {
        // flutter_foreground_task 11.x：startService 前必须 init 一次
        // （通知渠道 + 任务选项）；幂等，只在首个生成轮配置
        if (!_serviceInited) {
          FlutterForegroundTask.init(
            androidNotificationOptions: AndroidNotificationOptions(
              channelId: 'generation_keepalive',
              channelName: '后台生成',
              channelDescription: '生成回答期间保持运行，切后台不断流',
              channelImportance: NotificationChannelImportance.LOW,
              priority: NotificationPriority.LOW,
              onlyAlertOnce: true,
            ),
            iosNotificationOptions: const IOSNotificationOptions(
              showNotification: false,
              playSound: false,
            ),
            foregroundTaskOptions: ForegroundTaskOptions(
              eventAction: ForegroundTaskEventAction.nothing(),
              allowWakeLock: true,
            ),
          );
          _serviceInited = true;
        }
        await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.dataSync],
          notificationTitle: title,
          notificationText: content,
        );
      }
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('GenerationKeepalive.start 失败（不影响生成）：$e');
    }
  }

  /// 生成结束（完成/出错/手动停止）：释放前台服务 + WakeLock
  static Future<void> stop() async {
    if (!_active) return;
    _active = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('GenerationKeepalive.stopService 失败：$e');
    }
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('GenerationKeepalive.wakelock 失败：$e');
    }
  }
}
