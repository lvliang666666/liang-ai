import 'package:ai_chat_app/services/share_receive_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShareReceiveService 分享接收桥（F9 文本 + F7 图片）', () {
    late List<MethodCall> received;
    Map<Object?, Object?>? mockColdStartPayload;
    Map<Object?, Object?>? mockImageReadResult;

    setUp(() {
      received = [];
      mockColdStartPayload = null;
      mockImageReadResult = null;
      // mock 原生通道：getSharedPayload 返回缓存（可变），readShareImage
      // 返回图片字节（可变），onSharedPayload 由测试触发
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('ai_chat_app/share'),
        (call) async {
          received.add(call);
          if (call.method == 'getSharedPayload') return mockColdStartPayload;
          if (call.method == 'readShareImage') return mockImageReadResult;
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ai_chat_app/share'),
              null);
    });

    /// 模拟原生推送 payload
    Future<void> pushPayload(Map<Object?, Object?> payload) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'ai_chat_app/share',
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('onSharedPayload', payload)),
        (_) {},
      );
    }

    group('文本分享（F9）', () {
      test('init 兜底拉取：冷启动缓存文本经 stream 发出', () async {
        mockColdStartPayload = {'type': 'text', 'text': '分享的文本内容'};
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await Future.delayed(Duration.zero);
        expect(payloads, hasLength(1));
        expect(payloads.first, isA<ShareTextPayload>());
        expect((payloads.first as ShareTextPayload).text, '分享的文本内容');
        // 拉取即消费：getSharedPayload 被调用过
        expect(received.map((c) => c.method), contains('getSharedPayload'));
        await sub.cancel();
        svc.dispose();
      });

      test('onSharedPayload 推送：热启动文本经 stream 发出', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await pushPayload({'type': 'text', 'text': '热启动分享文本'});
        await Future.delayed(Duration.zero);
        expect(payloads, hasLength(1));
        expect((payloads.first as ShareTextPayload).text, '热启动分享文本');
        await sub.cancel();
        svc.dispose();
      });

      test('空文本推送被忽略', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await pushPayload({'type': 'text', 'text': ''});
        await Future.delayed(Duration.zero);
        expect(payloads, isEmpty);
        await sub.cancel();
        svc.dispose();
      });
    });

    group('图片分享（F7）', () {
      test('图片 payload：经 readShareImage 读字节转 base64', () async {
        mockColdStartPayload = null;
        mockImageReadResult = {'base64': 'aGVsbG8=', 'mime': 'image/png'};
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await pushPayload({'type': 'image', 'uri': 'content://share/img.png'});
        await Future.delayed(Duration.zero);
        expect(payloads, hasLength(1));
        final img = payloads.first as ShareImagePayload;
        expect(img.base64, 'aGVsbG8=');
        expect(img.mime, 'image/png');
        expect(img.bytes, isA<List<int>>());
        // readShareImage 被调用且带 uri
        final read = received.firstWhere((c) => c.method == 'readShareImage');
        expect(read.arguments['uri'], 'content://share/img.png');
        await sub.cancel();
        svc.dispose();
      });

      test('图片读取失败（PlatformException）静默忽略', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        // readShareImage 返回 null（读取失败语义）
        mockImageReadResult = null;
        await pushPayload({'type': 'image', 'uri': 'content://broken.png'});
        await Future.delayed(Duration.zero);
        expect(payloads, isEmpty);
        await sub.cancel();
        svc.dispose();
      });

      test('mime 缺省回退 image/png', () async {
        mockColdStartPayload = null;
        mockImageReadResult = {'base64': 'aGVsbG8='};
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await pushPayload({'type': 'image', 'uri': 'content://x'});
        await Future.delayed(Duration.zero);
        expect((payloads.first as ShareImagePayload).mime, 'image/png');
        await sub.cancel();
        svc.dispose();
      });
    });

    group('通用行为', () {
      test('init 无缓存：不发事件', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await Future.delayed(Duration.zero);
        expect(payloads, isEmpty);
        await sub.cancel();
        svc.dispose();
      });

      test('init 幂等：重复调用不重复拉取', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        await svc.init();
        await svc.init();
        expect(
            received.where((c) => c.method == 'getSharedPayload').length, 1);
        svc.dispose();
      });

      test('broadcast 流：多订阅者都能收到', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        final a = <SharePayload>[];
        final b = <SharePayload>[];
        final subA = svc.stream.listen(a.add);
        final subB = svc.stream.listen(b.add);
        svc.debugEmitText('多播文本');
        await Future.delayed(Duration.zero);
        expect(a, hasLength(1));
        expect(b, hasLength(1));
        await subA.cancel();
        await subB.cancel();
        svc.dispose();
      });

      test('未知 payload 类型被忽略', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await pushPayload({'type': 'video', 'uri': 'content://v'});
        await Future.delayed(Duration.zero);
        expect(payloads, isEmpty);
        await sub.cancel();
        svc.dispose();
      });
    });

    group('P2 widget deep link', () {
      test('推送 {type: link} → ShareLinkPayload', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await pushPayload({'type': 'link', 'link': 'liangai://chat/abc'});
        await Future.delayed(Duration.zero);
        expect(payloads, hasLength(1));
        expect(payloads.first, isA<ShareLinkPayload>());
        expect((payloads.first as ShareLinkPayload).link, 'liangai://chat/abc');
        await sub.cancel();
        svc.dispose();
      });

      test('冷启动兜底拉取 link 缓存', () async {
        mockColdStartPayload = {'type': 'link', 'link': 'liangai://new'};
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await Future.delayed(Duration.zero);
        expect(payloads, hasLength(1));
        expect((payloads.first as ShareLinkPayload).link, 'liangai://new');
        await sub.cancel();
        svc.dispose();
      });

      test('link 为空串被忽略', () async {
        mockColdStartPayload = null;
        final svc = ShareReceiveService();
        final payloads = <SharePayload>[];
        final sub = svc.stream.listen(payloads.add);
        await svc.init();
        await pushPayload({'type': 'link', 'link': ''});
        await Future.delayed(Duration.zero);
        expect(payloads, isEmpty);
        await sub.cancel();
        svc.dispose();
      });
    });
  });
}
