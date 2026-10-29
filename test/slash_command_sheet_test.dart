import 'package:ai_chat_app/models/skill.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/home/slash_command_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// I12 斜杠命令测试：短语 KV 存取 / 面板过滤 / 分组渲染 / 交互回调
void main() {
  group('SettingsService 斜杠短语 KV', () {
    late SettingsService settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService(await SharedPreferences.getInstance());
    });

    test('默认空列表', () {
      expect(settings.slashPhrases, isEmpty);
    });

    test('添加后可读回，最近添加在最前', () async {
      await settings.addSlashPhrase('帮我写周报');
      await settings.addSlashPhrase('总结这段话');
      expect(settings.slashPhrases, ['总结这段话', '帮我写周报']);
    });

    test('重复添加去重并提到最前', () async {
      await settings.addSlashPhrase('A');
      await settings.addSlashPhrase('B');
      await settings.addSlashPhrase('A');
      expect(settings.slashPhrases, ['A', 'B']);
    });

    test('空白短语被忽略', () async {
      await settings.addSlashPhrase('   ');
      expect(settings.slashPhrases, isEmpty);
    });

    test('超上限淘汰最久未用', () async {
      for (var i = 0; i <= SettingsService.slashPhraseLimit; i++) {
        await settings.addSlashPhrase('短语$i');
      }
      expect(settings.slashPhrases.length, SettingsService.slashPhraseLimit);
      expect(settings.slashPhrases.contains('短语0'), isFalse,
          reason: '最早添加的应被淘汰');
      expect(settings.slashPhrases.contains('短语1'), isTrue);
    });

    test('删除短语（不存在时静默）', () async {
      await settings.addSlashPhrase('A');
      await settings.removeSlashPhrase('A');
      expect(settings.slashPhrases, isEmpty);
      // 不存在：不抛异常
      await settings.removeSlashPhrase('不存在');
      expect(settings.slashPhrases, isEmpty);
    });

    test('变更触发 notifyListeners', () async {
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.addSlashPhrase('A');
      await settings.removeSlashPhrase('A');
      expect(notified, 2);
    });
  });

  group('SlashCommandSheet.filter', () {
    final skills = [
      Skill(id: 's1', name: '架构师', prompt: '', description: '系统设计'),
      Skill(id: 's2', name: '翻译官', prompt: '', description: '中英互译'),
    ];

    test('空查询返回原样', () {
      final (s, p) = SlashCommandSheet.filter(skills, ['短语A'], '');
      expect(s.length, 2);
      expect(p, ['短语A']);
    });

    test('按名称过滤 Skill（不区分大小写）', () {
      final (s, p) = SlashCommandSheet.filter(skills, [], '架构');
      expect(s.map((e) => e.id), ['s1']);
    });

    test('按描述过滤 Skill', () {
      final (s, _) = SlashCommandSheet.filter(skills, [], '互译');
      expect(s.map((e) => e.id), ['s2']);
    });

    test('按全文过滤短语', () {
      final (_, p) = SlashCommandSheet.filter(skills, ['写周报', '开会'], '周报');
      expect(p, ['写周报']);
    });

    test('无命中返回空', () {
      final (s, p) = SlashCommandSheet.filter(skills, ['短语'], '量子');
      expect(s, isEmpty);
      expect(p, isEmpty);
    });
  });

  group('SlashCommandSheet 面板', () {
    late SettingsService settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService(await SharedPreferences.getInstance());
    });

    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('分组渲染：Skill 与短语各自带组标题', (tester) async {
      await settings.addSlashPhrase('帮我写周报');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        skills: [Skill(id: 's1', name: '架构师', prompt: '', icon: '🏗️')],
        settings: settings,
        onSelectSkill: (_) {},
        onSelectPhrase: (_) {},
      )));
      await tester.pump();

      expect(find.text('斜杠命令'), findsOneWidget);
      expect(find.text('Skill'), findsOneWidget);
      expect(find.text('快捷短语'), findsOneWidget);
      expect(find.text('架构师'), findsOneWidget);
      expect(find.text('帮我写周报'), findsOneWidget);
    });

    testWidgets('点 Skill 触发 onSelectSkill', (tester) async {
      Skill? picked;
      await tester.pumpWidget(wrap(SlashCommandSheet(
        skills: [Skill(id: 's1', name: '架构师', prompt: '')],
        settings: settings,
        onSelectSkill: (s) => picked = s,
        onSelectPhrase: (_) {},
      )));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('slash-skill-s1')));
      await tester.pump();

      expect(picked?.id, 's1');
    });

    testWidgets('点短语触发 onSelectPhrase', (tester) async {
      String? picked;
      await settings.addSlashPhrase('帮我写周报');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        skills: const [],
        settings: settings,
        onSelectSkill: (_) {},
        onSelectPhrase: (p) => picked = p,
      )));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('slash-phrase-帮我写周报')));
      await tester.pump();

      expect(picked, '帮我写周报');
    });

    testWidgets('搜索过滤实时生效', (tester) async {
      await settings.addSlashPhrase('帮我写周报');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        skills: [Skill(id: 's1', name: '架构师', prompt: '')],
        settings: settings,
        onSelectSkill: (_) {},
        onSelectPhrase: (_) {},
      )));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '周报');
      await tester.pump();

      expect(find.text('帮我写周报'), findsOneWidget);
      expect(find.text('架构师'), findsNothing);
    });

    testWidgets('长按删除入口：点删除键回调且条目消失', (tester) async {
      final deleted = <String>[];
      await settings.addSlashPhrase('待删短语');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        skills: const [],
        settings: settings,
        onSelectSkill: (_) {},
        onSelectPhrase: (_) {},
        onDeletePhrase: (p) {
          deleted.add(p);
          settings.removeSlashPhrase(p);
        },
      )));
      await tester.pump();

      await tester.tap(find.byTooltip('删除短语'));
      await tester.pump();

      expect(deleted, ['待删短语']);
      expect(find.text('待删短语'), findsNothing);
    });

    testWidgets('onDeletePhrase 为空时不显示删除键', (tester) async {
      await settings.addSlashPhrase('短语');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        skills: const [],
        settings: settings,
        onSelectSkill: (_) {},
        onSelectPhrase: (_) {},
      )));
      await tester.pump();

      expect(find.byTooltip('删除短语'), findsNothing);
    });

    testWidgets('全空显示空态文案', (tester) async {
      await tester.pumpWidget(wrap(SlashCommandSheet(
        skills: const [],
        settings: settings,
        onSelectSkill: (_) {},
        onSelectPhrase: (_) {},
      )));
      await tester.pump();

      expect(find.text('暂无可用 Skill 或短语'), findsOneWidget);
    });

    testWidgets('搜索无命中显示「没有找到」', (tester) async {
      await tester.pumpWidget(wrap(SlashCommandSheet(
        skills: [Skill(id: 's1', name: '架构师', prompt: '')],
        settings: settings,
        onSelectSkill: (_) {},
        onSelectPhrase: (_) {},
      )));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '量子');
      await tester.pump();

      expect(find.textContaining('没有找到'), findsOneWidget);
    });
  });
}
