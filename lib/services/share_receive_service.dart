import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// F9/F7 分享载荷：文本（F9）或图片（F7，base64 + mime 已就绪）
sealed class SharePayload {
  const SharePayload();
}

class ShareTextPayload extends SharePayload {
  const ShareTextPayload(this.text);
  final String text;
}

class ShareImagePayload extends SharePayload {
  const ShareImagePayload({required this.base64, required this.mime});
  final String base64;
  final String mime;

  Uint8List get bytes => base64Decode(base64);
}

/// P2 桌面小组件 deep link：widget 点击 → ACTION_VIEW liangai://…
/// （new / chat/<id> / briefing），原生缓存后按 {type: "link"} 推送
class ShareLinkPayload extends SharePayload {
  const ShareLinkPayload(this.link);
  final String link;
}

/// F9/F7 分享即问：接收系统分享（文本/图片）的 Flutter 侧桥。
///
/// 与 MainActivity（MethodChannel `ai_chat_app/share`）配对：
/// - 冷启动：MainActivity.onCreate 缓存分享，引擎就绪后主动推
///   `onSharedPayload`；本服务 `getSharedPayload` 兜底拉取（推送先于
///   订阅注册的竞态兜底）
/// - 热启动（singleTop 复用 Activity）：onNewIntent → `onSharedPayload` 推送
/// - 图片：原生只传 content:// Uri，本服务经 `readShareImage` 桥方法
///   读字节转 base64（平台线程读文件）
///
/// 纯平台通道封装，无业务逻辑——宿主（home_page）订阅 [stream] 分发。
/// 测试可注入自定义 channel 走 mock handler。
class ShareReceiveService {
  ShareReceiveService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('ai_chat_app/share');

  final MethodChannel _channel;
  final StreamController<SharePayload> _controller =
      StreamController<SharePayload>.broadcast();
  bool _initialized = false;

  /// 收到的分享载荷流（broadcast：宿主随时订阅不丢后续事件）
  Stream<SharePayload> get stream => _controller.stream;

  /// 注册平台事件监听 + 兜底拉取冷启动缓存。
  /// 幂等：重复调用不重复注册。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      // 冷启动兜底：若原生推送先于本服务 init（订阅未注册），拉取缓存
      final payload = await _fetchPayload();
      if (payload != null) _controller.add(payload);
    } on PlatformException {
      // 原生侧未实现（如旧 APK 混装）——静默忽略，功能降级为不可用
    } on MissingPluginException {
      // 测试环境无平台插件——静默忽略
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'onSharedPayload') {
      final payload = await _payloadFromMap(call.arguments);
      if (payload != null) _controller.add(payload);
    }
    return null;
  }

  /// 拉取原生缓存并解析为载荷
  Future<SharePayload?> _fetchPayload() async {
    final map = await _channel
        .invokeMethod<Map<Object?, Object?>>('getSharedPayload');
    return _payloadFromMap(map);
  }

  /// 解析原生 payload map：{type: text, text} / {type: image, uri} /
  /// {type: link, link}（P2 widget deep link）
  Future<SharePayload?> _payloadFromMap(Object? map) async {
    if (map is! Map) return null;
    final type = map['type'];
    if (type == 'link') {
      final link = map['link'];
      if (link is String && link.isNotEmpty) return ShareLinkPayload(link);
      return null;
    }
    if (type == 'text') {
      final text = map['text'];
      if (text is String && text.isNotEmpty) return ShareTextPayload(text);
      return null;
    }
    if (type == 'image') {
      final uri = map['uri'];
      if (uri is! String || uri.isEmpty) return null;
      try {
        final result = await _channel
            .invokeMethod<Map<Object?, Object?>>('readShareImage', {
          'uri': uri,
        });
        final b64 = result?['base64'];
        final mime = result?['mime'];
        if (b64 is String && b64.isNotEmpty) {
          return ShareImagePayload(
              base64: b64, mime: mime is String ? mime : 'image/png');
        }
        return null;
      } on PlatformException {
        // 图片读取失败（权限/文件被删）——静默忽略该次分享
        return null;
      }
    }
    return null;
  }

  /// 测试辅助：模拟原生推送文本
  void debugEmitText(String text) => _controller.add(ShareTextPayload(text));

  /// 测试辅助：模拟原生推送图片
  void debugEmitImage({required String base64, String mime = 'image/png'}) =>
      _controller.add(ShareImagePayload(base64: base64, mime: mime));

  /// 测试辅助：模拟原生推送 widget deep link
  void debugEmitLink(String link) => _controller.add(ShareLinkPayload(link));

  void dispose() {
    _channel.setMethodCallHandler(null);
    _controller.close();
  }
}
