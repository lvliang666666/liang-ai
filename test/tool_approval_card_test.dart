import 'package:ai_chat_app/models/pending_tool.dart';
import 'package:ai_chat_app/providers/http_tool_provider.dart';
import 'package:ai_chat_app/providers/pending_tool_provider.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:ai_chat_app/widgets/tool_approval_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 工具审批卡片 UI 测试（自我迭代批次）
///
/// 核心行为：
/// - pending 存在：渲染卡片（工具名/方法徽标/描述/URL）
/// - 试运行区展开/收起
/// - 通过按钮调 approve（pending → http_tools）
/// - 拒绝按钮调 reject（pending 删除）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late PendingToolProvider pendingProvider;
  late HttpToolProvider httpProvider;
  late SharedPreferences prefs;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    httpProvider = HttpToolProvider(database: db);
    await httpProvider.load();
    pendingProvider =
        PendingToolProvider(database: db, httpTools: httpProvider);
    await pendingProvider.load();
  });

  tearDown(() async {
    await db.close();
  });

  PendingTool pending({String name = 'query_weather'}) => PendingTool(
        id: 'p1',
        sessionId: 's1',
        name: name,
        description: '查询指定城市的实时天气',
        urlTemplate: 'https://api.example.com/weather?city={city}',
        method: 'GET',
        parametersJson:
            '{"city": {"type": "string", "description": "城市名"}}',
        createdAt: 1000,
      );

  Widget wrap(Widget child) {
    final settings = SettingsService(prefs);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<HttpToolProvider>.value(value: httpProvider),
        ChangeNotifierProvider<PendingToolProvider>.value(
            value: pendingProvider),
        ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(settings: settings),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: ListView(children: [child]))),
    );
  }

  group('ToolApprovalCard 渲染', () {
    testWidgets('渲染工具名/方法徽标/描述/URL', (tester) async {
      await tester.pumpWidget(wrap(ToolApprovalCard(pending: pending())));
      await tester.pumpAndSettle();

      expect(find.text('新工具待审批'), findsOneWidget);
      expect(find.text('query_weather'), findsOneWidget);
      expect(find.text('GET'), findsOneWidget);
      expect(find.text('查询指定城市的实时天气'), findsOneWidget);
      expect(find.textContaining('api.example.com'), findsOneWidget);
      // 操作按钮
      expect(find.text('通过'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.text('试运行'), findsOneWidget);
    });

    testWidgets('试运行展开：参数表单按 parameters 动态生成', (tester) async {
      await tester.pumpWidget(wrap(ToolApprovalCard(pending: pending())));
      await tester.pumpAndSettle();

      // 展开试运行
      await tester.tap(find.text('试运行'));
      await tester.pumpAndSettle();

      // 参数输入框按 schema 生成（city 一项，label = 参数名）
      expect(find.widgetWithText(TextField, 'city'), findsOneWidget);
      expect(find.text('发送请求'), findsOneWidget);
    });

    testWidgets('通过：调 approve（pending 消失 + http_tools 出现）',
        (tester) async {
      await db.insertPendingTool(PendingTool(
        id: 'p1',
        sessionId: 's1',
        name: 'query_weather',
        description: '查询天气',
        urlTemplate: 'https://api.example.com/weather?city={city}',
        createdAt: 1000,
      ));
      await pendingProvider.load();
      expect(pendingProvider.tools.length, 1);

      await tester.pumpWidget(wrap(ToolApprovalCard(
          pending: pendingProvider.tools.first)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('通过'));
      await tester.pumpAndSettle();

      expect(pendingProvider.tools, isEmpty);
      expect(
        httpProvider.tools.any((t) => t.name == 'query_weather'),
        isTrue,
      );
    });

    testWidgets('拒绝：pending 删除，http_tools 不受影响', (tester) async {
      await db.insertPendingTool(PendingTool(
        id: 'p1',
        sessionId: 's1',
        name: 'query_weather',
        urlTemplate: 'https://api.example.com',
        createdAt: 1000,
      ));
      await pendingProvider.load();

      await tester.pumpWidget(wrap(ToolApprovalCard(
          pending: pendingProvider.tools.first)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();

      expect(pendingProvider.tools, isEmpty);
      expect(httpProvider.tools, isEmpty);
    });
  });
}
