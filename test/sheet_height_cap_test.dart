import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/commitment.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/morning_briefing_service.dart';
import 'package:ai_chat_app/widgets/app_bottom_sheet.dart';
import 'package:ai_chat_app/widgets/commitment_follow_up_sheet.dart';
import 'package:ai_chat_app/widgets/morning_briefing_sheet.dart';
import 'package:ai_chat_app/widgets/token_usage_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// Sheet 高度上限接线回归测试（v2.30.2 用户反馈）
///
/// 背景：showAppBottomSheet 用 isScrollControlled:true（松约束上限=
/// 全屏高），SheetScaffold 的 Column+Expanded(ListView) 在松约束下
/// 撑满最大可用高度——内容多的 Sheet 直接顶到状态栏，标题被通知栏
/// 遮挡（用户：「页面占满屏幕了，上面通知栏也挡住了一部分内容」）。
///
/// v2.16.1 的状态栏保护只覆盖键盘在场场景（SheetKeyboardInset 的
/// keyboardCap）；无键盘时 60% 上限同样必须由 SheetKeyboardInset
/// 施加。晨报/承诺跟进/Token 用量三个 Sheet 漏包（前两个还是自动
/// 弹出，最容易被注意到）——修复后用本测试锁住接线，防止未来
/// 新增/重构 Sheet 再漏。
///
/// 测试方式：真实走 showAppBottomSheet 弹出路径（showModalBottomSheet
/// 的松约束宿主），量测 SheetScaffold 根 RenderBox 高度 ≤ 60% 屏高。
/// 组件本身的布局数学（键盘/状态栏交互）由 sheet_keyboard_inset_test
/// 覆盖，这里只验证「入口确实包了上限」。
void main() {
  const screenW = 800.0;
  const screenH = 1200.0;
  const maxSheetHeight = screenH * 0.6; // 720

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // DB 初始化在 FakeAsync 区外（setUpAll 天然满足）；只读场景不建表也能跑
    final inMemory = await openTestDb();
    await DatabaseService.instance.initForTest(inMemory);
  });

  void setupView(WidgetTester tester) {
    tester.view.physicalSize = const Size(screenW, screenH);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 量测当前路由栈里 SheetScaffold 的实际渲染高度
  double sheetHeight(WidgetTester tester) {
    final box = tester.renderObject<RenderBox>(
      find.byType(SheetScaffold).first,
    );
    return box.size.height;
  }

  testWidgets('晨间简报 Sheet：高度 ≤ 60% 屏高（不顶满全屏）', (tester) async {
    setupView(tester);
    const briefing = MorningBriefing(
      dateKey: '2026-10-30',
      greeting: '早上好，今天也要加油',
      almanac: '宜出行会友，忌动土开仓',
      fortune: '上签，宜稳步推进',
      memory: '你最近在准备考试，加油',
      flashback: '上周今天聊了报销流程',
      huangliRaw: '【黄历】2026 年 10 月 30 日\n宜：出行、会友\n忌：动土、开仓',
      fortuneRaw: '【观音灵签】第 01 签 · 上上签',
      fromLlm: true,
    );

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showMorningBriefingSheet(context, briefing),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('今日简报 · 2026-10-30'), findsOneWidget);
    expect(sheetHeight(tester), lessThanOrEqualTo(maxSheetHeight + 0.5));
  });

  testWidgets('承诺跟进 Sheet：高度 ≤ 60% 屏高', (tester) async {
    setupView(tester);
    final commitment = Commitment(
      id: 'c1',
      sessionId: 's1',
      content: '发周报',
      dueDate: '2026-10-30',
      status: Commitment.statusPending,
      followUp: '周报发了吗？进展如何',
      createdAt: 1000,
      updatedAt: 1000,
    );

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showCommitmentFollowUpSheet(
                  context, [commitment, commitment, commitment]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('承诺跟进'), findsOneWidget);
    expect(sheetHeight(tester), lessThanOrEqualTo(maxSheetHeight + 0.5));
  });

  testWidgets('Token 用量 Sheet：高度 ≤ 60% 屏高', (tester) async {
    setupView(tester);
    final chat = _StubChat();

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showTokenUsageSheet(context, chat),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Token 用量'), findsOneWidget);
    expect(sheetHeight(tester), lessThanOrEqualTo(maxSheetHeight + 0.5));
  });
}

/// TokenUsageSheet 需要一个 ChatProvider 实例（ListenableBuilder 订阅）。
/// 只读 getters 走空会话默认值，不触发 DB 写/网络。
class _StubChat extends ChatProvider {
  _StubChat()
      : super(
          database: DatabaseService.instance,
          api: _NoApi(),
          session: ChatSession(
            id: 's1',
            title: '测试',
            createdAt: 1000,
            updatedAt: 1000,
          ),
          profile: ProviderProfile.builtinCompany(),
          model: 'glm5.1',
        );
}

/// 永不被调用的 ApiService 占位（ChatProvider 构造必需；dispose 需真实类型）
class _NoApi implements ApiService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  void dispose() {}
}
