import 'package:ai_chat_app/widgets/code_block_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 代码块复制按钮内反馈回归测试（UI 批次 1-① 验收标准）
///
/// 需求（docs/UI修改建议.html 一）：复制反馈不用底部 Toast，改为按钮
/// 内状态切换——图标换 16dp 绿色对勾（#34C759）、文案「复制」→「已复制」，
/// 1500ms 后还原；重复点击重新计时，不叠加不闪烁。
///
/// 验收标准逐条测试化：
/// 1. 点击复制后按钮原地显示「✓已复制」，无底部弹条
/// 2. 反馈期间无 Toast/遮罩（输入栏可正常操作，无遮挡）
/// 3. 连续快速点击复制，状态正常刷新（重新计时），无堆叠异常
/// 4. 1.5s 后按钮还原为「复制」初始态
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 剪贴板平台通道 mock（Clipboard.setData 在测试环境无实现）
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') return null;
      if (call.method == 'Clipboard.getData') {
        return const JSONMethodCodec()
            .encodeSuccessEnvelope(<String, dynamic>{'text': null});
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  });

  Future<void> pumpBlock(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CodeBlockWidget(code: 'print("hello");', language: 'dart'),
      ),
    ));
  }

  Finder copyButton() => find.text('复制');

  testWidgets('验收①：点击复制后按钮原地显示「已复制」，无底部弹条',
      (tester) async {
    await pumpBlock(tester);
    expect(copyButton(), findsOneWidget);

    await tester.tap(copyButton());
    await tester.pump(); // 状态切换立即生效

    expect(find.text('已复制'), findsOneWidget,
        reason: '反馈在按钮原地（文案切换），不是弹层');
    expect(find.text('复制'), findsNothing);
    // 绿色对勾图标（#34C759）出现
    final check = tester.widget<Icon>(
      find.byIcon(Icons.check),
    );
    expect(check.color, const Color(0xFF34C759),
        reason: '对勾颜色 = 需求规格 #34C759');
    expect(check.size, 16, reason: '对勾 16dp');
    // 无 Toast 弹层（验收②：反馈期间输入栏可正常操作，无遮挡）——
    // Toast 用 Overlay 插入 rootOverlay；断言全树无 Toast 特征：
    // 深色胶囊（rgba(0,0,0,0.75)）不存在即无 Toast
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          (w.decoration is BoxDecoration) &&
          (w.decoration as BoxDecoration).color == const Color(0xBF000000)),
      findsNothing,
      reason: '无 Toast 深色胶囊浮层',
    );
  });

  testWidgets('验收④：1500ms 后按钮还原为「复制」初始态', (tester) async {
    await pumpBlock(tester);
    await tester.tap(copyButton());
    await tester.pump();
    expect(find.text('已复制'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('复制'), findsOneWidget,
        reason: '1500ms 后还原初始态');
    expect(find.text('已复制'), findsNothing);
    expect(find.byIcon(Icons.check), findsNothing,
        reason: '对勾还原为复制图标');
  });

  testWidgets('验收③：连续快速点击，重新计时不叠加（1500ms 从最后一次点击起算）',
      (tester) async {
    await pumpBlock(tester);
    await tester.tap(copyButton());
    await tester.pump();

    // 1000ms 后再次点击（第一次的还原 Timer 只剩 500ms）
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.tap(find.text('已复制'));
    await tester.pump();

    // 第一次点击后 1500ms（第二次点击后仅 500ms）——不应还原
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('已复制'), findsOneWidget,
        reason: '重复点击重新计时：第一次的 1500ms 不应提前还原');
    expect(find.byIcon(Icons.check), findsOneWidget,
        reason: '对勾只有一个（不叠加）');

    // 第二次点击后再过 1000ms（合计 1500ms）——还原
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('复制内容写入剪贴板（反馈之外的功能本体）', (tester) async {
    // 直接 mock setData 捕获写入内容（getData 回程编解码在测试环境
    // 有 ByteData 兼容问题，改为在 handler 侧记录）
    Object? written;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        written = (call.arguments as Map)['text'];
        return null;
      }
      return null;
    });

    await pumpBlock(tester);
    await tester.tap(copyButton());
    await tester.pump();

    expect(written, 'print("hello");');
  });
}
