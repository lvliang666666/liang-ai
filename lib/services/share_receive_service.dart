import 'dart:async';

import 'package:flutter/services.dart';

/// F9 分享即问：接收系统分享文本的 Flutter 侧桥。
///
/// 与 MainActivity（MethodChannel `ai_chat_app/share`）配对：
/// - 冷启动：MainActivity.onCreate 缓存分享文本，引擎就绪后主动推
///   `onSharedText`（configureFlutterEngine 时若已有缓存）；本服务
///   `getSharedText` 兜底拉取（推送先于订阅注册的竞态兜底）
/// - 热启动（singleTop 复用 Activity）：onNewIntent → `onSharedText` 推送
///
/// 纯平台通道封装，无业务逻辑——宿主（home_page）订阅 [stream] 拿文本
/// 预填输入框。测试可注入自定义 channel 名走 FakeMethodChannel。
class ShareReceiveService {
  ShareReceiveService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('ai_chat_app/share');

  final MethodChannel _channel;
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  bool _initialized = false;

  /// 收到的分享文本流（broadcast：宿主随时订阅不丢后续事件）
  Stream<String> get stream => _controller.stream;

  /// 注册平台事件监听 + 兜底拉取冷启动缓存。
  /// 幂等：重复调用不重复注册。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      // 冷启动兜底：若原生推送先于本服务 init（订阅未注册），拉取缓存
      final text = await _channel.invokeMethod<String>('getSharedText');
      if (text != null && text.isNotEmpty) _controller.add(text);
    } on PlatformException {
      // 原生侧未实现（如旧 APK 混装）——静默忽略，功能降级为不可用
    } on MissingPluginException {
      // 测试环境无平台插件——静默忽略
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'onSharedText') {
      final text = call.arguments as String?;
      if (text != null && text.isNotEmpty) _controller.add(text);
    }
    return null;
  }

  /// 测试辅助：模拟原生推送
  void debugEmit(String text) => _controller.add(text);

  void dispose() {
    _channel.setMethodCallHandler(null);
    _controller.close();
  }
}
