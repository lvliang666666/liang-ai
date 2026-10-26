import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_chat_app/services/settings_service.dart';

/// I6 会话独立草稿：SettingsService 草稿 API 行为测试
void main() {
  group('会话草稿（I6）', () {
    late SettingsService settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      settings = SettingsService(prefs);
    });

    test('无草稿返回空串', () {
      expect(settings.getDraft('s1'), '');
      expect(settings.idleDraft, '');
    });

    test('保存后可读回', () async {
      await settings.setDraft('s1', '未发送的问题');
      expect(settings.getDraft('s1'), '未发送的问题');
    });

    test('不同会话草稿互相隔离', () async {
      await settings.setDraft('s1', '会话一的草稿');
      await settings.setDraft('s2', '会话二的草稿');
      expect(settings.getDraft('s1'), '会话一的草稿');
      expect(settings.getDraft('s2'), '会话二的草稿');
    });

    test('空文本保存 = 清除草稿', () async {
      await settings.setDraft('s1', '有内容');
      await settings.setDraft('s1', '');
      expect(settings.getDraft('s1'), '');
    });

    test('clearDraft 删除会话时清草稿', () async {
      await settings.setDraft('s1', '内容');
      await settings.clearDraft('s1');
      expect(settings.getDraft('s1'), '');
    });

    test('空闲态草稿独立存取', () async {
      await settings.setIdleDraft('主页打的字');
      expect(settings.idleDraft, '主页打的字');
      // 与会话草稿互不影响
      await settings.setDraft('s1', '会话草稿');
      expect(settings.idleDraft, '主页打的字');
      expect(settings.getDraft('s1'), '会话草稿');
      await settings.setIdleDraft('');
      expect(settings.idleDraft, '');
    });

    test('LRU 淘汰：超上限后最久未写的草稿被清', () async {
      // 写满上限 + 1 条
      for (var i = 0; i <= SettingsService.draftLimit; i++) {
        await settings.setDraft('s$i', '草稿$i');
      }
      // s0 最先写（最久未写），应被淘汰；其余保留
      expect(settings.getDraft('s0'), '');
      expect(settings.getDraft('s1'), '草稿1');
      expect(
          settings.getDraft('s${SettingsService.draftLimit}'),
          '草稿${SettingsService.draftLimit}');
    });

    test('重写旧草稿提升 LRU 位置：不被淘汰', () async {
      for (var i = 0; i <= SettingsService.draftLimit; i++) {
        await settings.setDraft('s$i', '草稿$i');
      }
      // 填充后最旧的是 s0（最后写入的循环尾），重写 s1（第二旧）提升到最新
      await settings.setDraft('s1', '草稿1更新');
      // 此时最旧的 s0 被淘汰，s1 保留且内容更新
      expect(settings.getDraft('s0'), '');
      expect(settings.getDraft('s1'), '草稿1更新');
    });
  });

  group('自动记忆沉淀开关（M2）', () {
    late SettingsService settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      settings = SettingsService(prefs);
    });

    test('默认开（升级用户行为不变）', () {
      expect(settings.autoMemory, isTrue);
    });

    test('关闭后可读回，再开恢复', () async {
      await settings.setAutoMemory(false);
      expect(settings.autoMemory, isFalse);
      await settings.setAutoMemory(true);
      expect(settings.autoMemory, isTrue);
    });

    test('同值写入幂等（不触发通知）', () async {
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.setAutoMemory(settings.autoMemory);
      expect(notified, 0);
      await settings.setAutoMemory(false);
      expect(notified, 1);
    });
  });
}
