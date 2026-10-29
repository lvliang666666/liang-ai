import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/home/slash_command_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// I12 斜杠命令测试：短语 KV 存取 / 面板过滤 / 交互回调
///
/// v2.16.0 验收反馈后面板收窄为「快捷短语」单一功能（Skill 切换
/// 走输入栏 tag 入口，不进面板），filter 只处理短语。
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
    test('空查询返回原样', () {
      final p = SlashCommandSheet.filter(['短语A', '短语B'], '');
      expect(p, ['短语A', '短语B']);
    });

    test('按全文过滤短语', () {
      final p = SlashCommandSheet.filter(['写周报', '开会'], '周报');
      expect(p, ['写周报']);
    });

    test('不区分大小写', () {
      final p = SlashCommandSheet.filter(['TODO List', '开会'], 'todo');
      expect(p, ['TODO List']);
    });

    test('无命中返回空', () {
      final p = SlashCommandSheet.filter(['短语'], '量子');
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

    testWidgets('渲染短语列表与标题', (tester) async {
      await settings.addSlashPhrase('帮我写周报');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        settings: settings,
        onSelectPhrase: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('快捷短语'), findsOneWidget);
      expect(find.text('帮我写周报'), findsOneWidget);
    });

    testWidgets('点短语触发 onSelectPhrase', (tester) async {
      String? picked;
      await settings.addSlashPhrase('帮我写周报');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        settings: settings,
        onSelectPhrase: (p) => picked = p,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('slash-phrase-帮我写周报')));
      await tester.pump();

      expect(picked, '帮我写周报');
    });

    testWidgets('搜索过滤实时生效', (tester) async {
      await settings.addSlashPhrase('帮我写周报');
      await settings.addSlashPhrase('开会纪要');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        settings: settings,
        onSelectPhrase: (_) {},
      )));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '周报');
      await tester.pump();

      expect(find.text('帮我写周报'), findsOneWidget);
      expect(find.text('开会纪要'), findsNothing);
    });

    testWidgets('长按删除入口：点删除键回调且条目消失', (tester) async {
      final deleted = <String>[];
      await settings.addSlashPhrase('待删短语');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        settings: settings,
        onSelectPhrase: (_) {},
        onDeletePhrase: (p) {
          deleted.add(p);
          settings.removeSlashPhrase(p);
        },
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('删除短语'));
      await tester.pump();

      expect(deleted, ['待删短语']);
      expect(find.text('待删短语'), findsNothing);
    });

    testWidgets('onDeletePhrase 为空时不显示删除键', (tester) async {
      await settings.addSlashPhrase('短语');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        settings: settings,
        onSelectPhrase: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.byTooltip('删除短语'), findsNothing);
    });

    testWidgets('全空显示空态文案', (tester) async {
      await tester.pumpWidget(wrap(SlashCommandSheet(
        settings: settings,
        onSelectPhrase: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('暂无快捷短语'), findsOneWidget);
    });

    testWidgets('搜索无命中显示「没有找到」', (tester) async {
      await settings.addSlashPhrase('短语');
      await tester.pumpWidget(wrap(SlashCommandSheet(
        settings: settings,
        onSelectPhrase: (_) {},
      )));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '量子');
      await tester.pump();

      expect(find.textContaining('没有找到'), findsOneWidget);
    });
  });
}
