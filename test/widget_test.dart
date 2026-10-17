import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_chat_app/services/settings_service.dart';

void main() {
  group('SettingsService', () {
    test('默认值正确', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs);

      expect(settings.apiKey, SettingsService.defaultApiKey);
      expect(settings.baseUrl, SettingsService.defaultBaseUrl);
      expect(settings.model, 'glm5.1');
      expect(settings.defaultEffortValue, 'max');
      expect(settings.temperature, 0.7);
    });

    test('读写设置', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs);

      await settings.setApiKey('test-key');
      await settings.setBaseUrl('https://example.com/v1');
      await settings.setModel('test-model');
      await settings.setDefaultEffort('low');
      await settings.setTemperature(1.2);

      expect(settings.apiKey, 'test-key');
      expect(settings.baseUrl, 'https://example.com/v1');
      expect(settings.model, 'test-model');
      expect(settings.defaultEffortValue, 'low');
      expect(settings.temperature, 1.2);
    });
  });
}
