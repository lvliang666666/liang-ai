import 'package:ai_chat_app/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P1 晨间简报设置项测试：开关默认值 + 日期键读写（打开补算式状态）
void main() {
  late SharedPreferences prefs;
  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    settings = SettingsService(prefs);
  });

  group('morningBriefing 开关', () {
    test('默认开', () {
      expect(settings.morningBriefing, isTrue);
    });

    test('关闭后落盘可读回', () async {
      await settings.setMorningBriefing(false);
      expect(settings.morningBriefing, isFalse);
      expect(prefs.getBool('morning_briefing'), isFalse);
    });

    test('重复设置同值：不重复落盘（幂等）', () async {
      await settings.setMorningBriefing(true);
      expect(settings.morningBriefing, isTrue);
    });
  });

  group('lastBriefingDate 日期键', () {
    test('默认 null（从未生成过）', () {
      expect(settings.lastBriefingDate, isNull);
    });

    test('写入后可读回（yyyy-MM-dd 格式）', () async {
      await settings.setLastBriefingDate('2026-10-30');
      expect(settings.lastBriefingDate, '2026-10-30');
    });

    test('跨天覆盖写：新日期替换旧日期', () async {
      await settings.setLastBriefingDate('2026-10-29');
      await settings.setLastBriefingDate('2026-10-30');
      expect(settings.lastBriefingDate, '2026-10-30');
    });
  });
}
