import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/services/widget_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WidgetData', () {
    test('toJson：briefing + sessions 截断到 3 条', () {
      final sessions = List.generate(5, (i) => _session('id$i', '会话$i'));
      final data = WidgetData(briefing: '早安', sessions: sessions);
      final json = data.toJson();
      expect(json['briefing'], '早安');
      expect((json['sessions'] as List).length, 3);
      expect((json['sessions'] as List).first['id'], 'id0');
    });

    test('toJson：空 briefing 不输出该键', () {
      final data = WidgetData(briefing: null, sessions: [_session('a', 'A')]);
      expect(data.toJson().containsKey('briefing'), isFalse);
      final data2 = WidgetData(briefing: '', sessions: const []);
      expect(data2.toJson().containsKey('briefing'), isFalse);
    });

    test('encode：合法 JSON 且原生可解析', () {
      final data = WidgetData(
        briefing: '早上好',
        sessions: [_session('x1', '标题一'), _session('x2', '标题二')],
      );
      final decoded = jsonDecode(data.encode()) as Map<String, dynamic>;
      expect(decoded['briefing'], '早上好');
      final arr = decoded['sessions'] as List;
      expect(arr.length, 2);
      expect(arr[1]['title'], '标题二');
    });
  });

  group('WidgetDataService.buildData', () {
    test('当天简报缓存 → briefing 取 greeting', () {
      final now = DateTime.now();
      final dateKey = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final prefs = _fakePrefs({
        'widgetBriefingDate': dateKey,
        'widgetBriefingText': '今天也要加油',
      });
      final data = WidgetDataService.buildData(
        sessions: [_session('s1', '工作讨论')],
        prefs: prefs,
      );
      expect(data.briefing, '今天也要加油');
      expect(data.sessions.first.id, 's1');
    });

    test('跨天缓存 → briefing 为 null（不显示过期简报）', () {
      final prefs = _fakePrefs({
        'widgetBriefingDate': '2020-01-01',
        'widgetBriefingText': '过期简报',
      });
      final data = WidgetDataService.buildData(sessions: const [], prefs: prefs);
      expect(data.briefing, isNull);
    });

    test('无缓存 → briefing 为 null', () {
      final data = WidgetDataService.buildData(
        sessions: const [], prefs: _fakePrefs(const {}),
      );
      expect(data.briefing, isNull);
    });
  });

  group('WidgetDataPusher', () {
    test('onSessionsChanged 防抖后推送一次', () async {
      final calls = <String>[];
      final binding = TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ai_chat_app/share'),
        (call) async {
          if (call.method == 'updateWidgetData') {
            calls.add(call.arguments['json'] as String);
          }
          return true;
        },
      );
      addTearDown(() => binding.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ai_chat_app/share'), null));

      final pusher = WidgetDataPusher(
        service: WidgetDataService(),
        prefs: _fakePrefs(const {}),
        debounce: const Duration(milliseconds: 10),
      );
      pusher.onSessionsChanged([_session('a', 'A')]);
      pusher.onSessionsChanged([_session('a', 'A'), _session('b', 'B')]);
      pusher.onSessionsChanged([_session('a', 'A')]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls.length, 1); // 防抖：3 次变化只推 1 次
      final decoded = jsonDecode(calls.first) as Map<String, dynamic>;
      expect((decoded['sessions'] as List).length, 1);
      pusher.dispose();
    });

    test('pushNow 立即推送不等防抖', () async {
      final calls = <String>[];
      final binding = TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ai_chat_app/share'),
        (call) async {
          if (call.method == 'updateWidgetData') {
            calls.add(call.arguments['json'] as String);
          }
          return true;
        },
      );
      addTearDown(() => binding.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ai_chat_app/share'), null));

      final pusher = WidgetDataPusher(
        service: WidgetDataService(),
        prefs: _fakePrefs(const {}),
      );
      await pusher.pushNow();
      expect(calls.length, 1);
      pusher.dispose();
    });

    test('平台不可用（MissingPluginException）静默降级且不再重试', () async {
      final binding = TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ai_chat_app/share'),
        (call) async => throw MissingPluginException(),
      );
      addTearDown(() => binding.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ai_chat_app/share'), null));

      final pusher = WidgetDataPusher(
        service: WidgetDataService(),
        prefs: _fakePrefs(const {}),
      );
      // 不抛异常即通过；第二次推送直接短路（_available=false）
      await pusher.pushNow();
      await pusher.pushNow();
      pusher.dispose();
    });
  });
}

ChatSession _session(String id, String title) => ChatSession(
      id: id,
      title: title,
      createdAt: 0,
      updatedAt: 0,
    );

_FakePrefs _fakePrefs(Map<String, Object> values) => _FakePrefs(values);

/// 最小 SharedPreferences 假实现（只读场景够用）
class _FakePrefs implements SharedPreferences {
  _FakePrefs(this._values);
  final Map<String, Object> _values;

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
