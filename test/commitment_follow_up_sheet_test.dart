import 'package:ai_chat_app/models/commitment.dart';
import 'package:ai_chat_app/widgets/commitment_follow_up_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_chat_app/services/settings_service.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Commitment commitment(String id,
          {String? followUp = '周报发了吗？进展如何',
          String status = Commitment.statusPending}) =>
      Commitment(
        id: id,
        sessionId: 's1',
        content: '发周报',
        dueDate: '2026-10-30',
        status: status,
        followUp: followUp,
        createdAt: 1000,
        updatedAt: 1000,
      );

  Future<void> pumpSheet(
    WidgetTester tester,
    List<Commitment> commitments, {
    Future<void> Function(Commitment, String)? onSettle,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final settings =
        SettingsService(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<SettingsService>.value(value: settings),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CommitmentFollowUpSheet(
              commitments: commitments,
              onSettle: onSettle,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('CommitmentFollowUpSheet', () {
    testWidgets('渲染跟进语 + 承诺内容 + 到期日', (tester) async {
      await pumpSheet(tester, [commitment('c1')]);

      expect(find.text('周报发了吗？进展如何'), findsOneWidget);
      expect(find.textContaining('发周报'), findsOneWidget);
      expect(find.textContaining('到期：2026-10-30'), findsOneWidget);
    });

    testWidgets('三条操作按钮齐全（继续聊/已完成/忽略）', (tester) async {
      await pumpSheet(tester, [commitment('c1')]);

      expect(find.byKey(const ValueKey('continue-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('done-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('dismiss-c1')), findsOneWidget);
    });

    testWidgets('点已完成：卡片移除 + 全部处理完自动关闭', (tester) async {
      final settled = <(String, String)>[];
      await pumpSheet(tester, [commitment('c1')],
          onSettle: (c, s) async => settled.add((c.id, s)));

      await tester.tap(find.byKey(const ValueKey('done-c1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('发周报'), findsNothing,
          reason: '处理后卡片从列表移除');
      expect(settled, [('c1', Commitment.statusDone)]);
    });

    testWidgets('多条承诺：处理一条其余保留', (tester) async {
      await pumpSheet(tester, [commitment('c1'), commitment('c2')],
          onSettle: (_, __) async {});

      await tester.tap(find.byKey(const ValueKey('dismiss-c1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('continue-c1')), findsNothing);
      expect(find.byKey(const ValueKey('continue-c2')), findsOneWidget,
          reason: '只移除被处理的，其余保留');
    });

    testWidgets('无跟进语时用本地模板兜底显示', (tester) async {
      await pumpSheet(tester, [commitment('c1', followUp: null)]);

      expect(find.textContaining('发周报'), findsWidgets,
          reason: '本地模板含承诺内容');
    });

    testWidgets('空列表：显示完成态文案', (tester) async {
      await pumpSheet(tester, const []);

      expect(find.text('都处理完了，没有待跟进的承诺'), findsOneWidget);
    });
  });

  group('SettingsService 承诺跟进开关', () {
    test('默认开 + 读写往返', () async {
      SharedPreferences.setMockInitialValues({});
      final settings =
          SettingsService(await SharedPreferences.getInstance());
      expect(settings.commitmentFollowUp, isTrue);

      await settings.setCommitmentFollowUp(false);
      expect(settings.commitmentFollowUp, isFalse);

      final settings2 =
          SettingsService(await SharedPreferences.getInstance());
      expect(settings2.commitmentFollowUp, isFalse, reason: '持久化生效');
    });

    test('lastFollowUpDate 读写往返', () async {
      SharedPreferences.setMockInitialValues({});
      final settings =
          SettingsService(await SharedPreferences.getInstance());
      expect(settings.lastFollowUpDate, isNull);

      await settings.setLastFollowUpDate('2026-10-30');
      expect(settings.lastFollowUpDate, '2026-10-30');
    });
  });
}
