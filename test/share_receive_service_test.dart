import 'dart:async';

import 'package:ai_chat_app/services/share_receive_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShareReceiveService 分享接收桥', () {
    late List<MethodCall> received;

    setUp(() {
      received = [];
      // mock 原生通道：getSharedText 返回缓存值（可变），onSharedText 由测试触发
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('ai_chat_app/share'),
        (call) async {
          received.add(call);
          if (call.method == 'getSharedText') return mockColdStartText;
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ai_chat_app/share'),
              null);
    });

    test('init 兜底拉取：冷启动缓存文本经 stream 发出', () async {
      mockColdStartText = '分享的文本内容';
      final svc = ShareReceiveService();
      final texts = <String>[];
      final sub = svc.stream.listen(texts.add);
      await svc.init();
      await Future.delayed(Duration.zero);
      expect(texts, ['分享的文本内容']);
      // 拉取即消费：原生侧缓存被清（这里验证 getSharedText 被调用过）
      expect(received.map((c) => c.method), contains('getSharedText'));
      await sub.cancel();
      svc.dispose();
    });

    test('init 无缓存：不发事件', () async {
      mockColdStartText = null;
      final svc = ShareReceiveService();
      final texts = <String>[];
      final sub = svc.stream.listen(texts.add);
      await svc.init();
      await Future.delayed(Duration.zero);
      expect(texts, isEmpty);
      await sub.cancel();
      svc.dispose();
    });

    test('onSharedText 推送：热启动文本经 stream 发出', () async {
      mockColdStartText = null;
      final svc = ShareReceiveService();
      final texts = <String>[];
      final sub = svc.stream.listen(texts.add);
      await svc.init();
      // 模拟原生 onNewIntent 推送
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'ai_chat_app/share',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onSharedText', '热启动分享文本'),
        ),
        (_) {},
      );
      await Future.delayed(Duration.zero);
      expect(texts, ['热启动分享文本']);
      await sub.cancel();
      svc.dispose();
    });

    test('空文本推送被忽略', () async {
      mockColdStartText = null;
      final svc = ShareReceiveService();
      final texts = <String>[];
      final sub = svc.stream.listen(texts.add);
      await svc.init();
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'ai_chat_app/share',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('onSharedText', '')),
        (_) {},
      );
      await Future.delayed(Duration.zero);
      expect(texts, isEmpty);
      await sub.cancel();
      svc.dispose();
    });

    test('init 幂等：重复调用不重复拉取', () async {
      mockColdStartText = null;
      final svc = ShareReceiveService();
      await svc.init();
      await svc.init();
      expect(received.where((c) => c.method == 'getSharedText').length, 1);
      svc.dispose();
    });

    test('broadcast 流：多订阅者都能收到', () async {
      mockColdStartText = null;
      final svc = ShareReceiveService();
      final a = <String>[];
      final b = <String>[];
      final subA = svc.stream.listen(a.add);
      final subB = svc.stream.listen(b.add);
      svc.debugEmit('多播文本');
      await Future.delayed(Duration.zero);
      expect(a, ['多播文本']);
      expect(b, ['多播文本']);
      await subA.cancel();
      await subB.cancel();
      svc.dispose();
    });
  });
}

/// mock 原生冷启动缓存（各用例可改）
String? mockColdStartText;
