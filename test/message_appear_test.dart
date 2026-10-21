import 'package:ai_chat_app/widgets/message_appear.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MessageAppear：首次构建播放淡入+上滑，动画结束后完全可见', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageAppear(child: Text('新消息')),
        ),
      ),
    );

    // 动画进行中：透明度 < 1（入场动画已启动）
    final fadeBefore = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.text('新消息'),
        matching: find.byType(FadeTransition),
      ).first,
    );
    expect(fadeBefore.opacity.value, lessThan(1.0));

    // 动画结束后：完全可见
    await tester.pumpAndSettle();
    final fadeAfter = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.text('新消息'),
        matching: find.byType(FadeTransition),
      ).first,
    );
    expect(fadeAfter.opacity.value, 1.0);
  });

  testWidgets('MessageAppear：父组件重建不重播动画（State 保留）', (tester) async {
    var rebuildCount = 0;
    Future<void> rebuild() async {
      rebuildCount++;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageAppear(
              key: ValueKey('stable'),
              child: Text('消息 v$rebuildCount'),
            ),
          ),
        ),
      );
    }

    await rebuild();
    await tester.pumpAndSettle();

    // 父组件重建（模拟流式 setState）：同 key 元素树保留，动画不重播
    await rebuild();
    await tester.pump(); // 若重播，此刻透明度会 < 1
    final fade = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.text('消息 v2'),
        matching: find.byType(FadeTransition),
      ).first,
    );
    expect(fade.opacity.value, 1.0);
  });

  testWidgets('MessageAppear：key 变化（新消息）重新播放动画', (tester) async {
    Widget host(String id) => MaterialApp(
          home: Scaffold(
            body: MessageAppear(
              key: ValueKey(id),
              child: Text('消息 $id'),
            ),
          ),
        );

    await tester.pumpWidget(host('a'));
    await tester.pumpAndSettle();

    // 新消息（不同 key）：旧元素树销毁，新 State 重新 forward
    await tester.pumpWidget(host('b'));
    final fade = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.text('消息 b'),
        matching: find.byType(FadeTransition),
      ).first,
    );
    expect(fade.opacity.value, lessThan(1.0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FadeTransition>(
        find.ancestor(
          of: find.text('消息 b'),
          matching: find.byType(FadeTransition),
        ).first,
      ).opacity.value,
      1.0,
    );
  });
}
