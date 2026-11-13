import 'package:ai_chat_app/models/http_tool.dart';
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

/// 工具审批卡片 UI 测试（自我迭代批次）
///
/// 核心行为：
/// - pending 存在：渲染卡片（工具名/方法徽标/描述/URL）
/// - 试运行区展开/收起
/// - 通过按钮调 approve（pending → http_tools）
/// - 拒绝按钮调 reject（pending 删除）
///
/// **Fake provider 纪律**（同 http_tool_panel_test）：testWidgets 体是
/// fakeAsync 区，sqflite_ffi 真实异步 IO 推不动——tap 触发的 approve/
/// reject 回调链里的 DB 写永远等不到完成，测试挂死（"did not
/// complete"）。approve/reject/load 全部覆写为同步内存态，DB 交互
/// （审批流转/级联删）由 manage_http_tool_tool_test 的纯 test 组覆盖
/// （真异步区，IO 正常推进）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late _FakeHttpToolProvider httpProvider;
  late _FakePendingToolProvider pendingProvider;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    httpProvider = _FakeHttpToolProvider();
    pendingProvider = _FakePendingToolProvider(httpTools: httpProvider);
  });

  tearDown(() {
    httpProvider.dispose();
    pendingProvider.dispose();
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
      pendingProvider.seed([pending()]);
      await tester.pumpWidget(wrap(ToolApprovalCard(
          pending: pendingProvider.tools.first)));
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
      pendingProvider.seed([pending()]);
      await tester.pumpWidget(wrap(ToolApprovalCard(
          pending: pendingProvider.tools.first)));
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
      pendingProvider.seed([pending()]);
      await tester.pumpWidget(wrap(ToolApprovalCard(
          pending: pendingProvider.tools.first)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('通过'));
      // 审批后弹 Toast（2200ms 隐藏 Timer）——pumpAndSettle 不等 Timer，
      // 固定 pump 清掉生命周期（2200 停留 + 200 淡出余量）
      await tester.pump(const Duration(milliseconds: 2200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(pendingProvider.tools, isEmpty);
      expect(
        httpProvider.tools.any((t) => t.name == 'query_weather'),
        isTrue,
      );
    });

    testWidgets('拒绝：pending 删除，http_tools 不受影响', (tester) async {
      pendingProvider.seed([pending()]);
      await tester.pumpWidget(wrap(ToolApprovalCard(
          pending: pendingProvider.tools.first)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('拒绝'));
      // 同上：清 Toast Timer
      await tester.pump(const Duration(milliseconds: 2200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(pendingProvider.tools, isEmpty);
      expect(httpProvider.tools, isEmpty);
    });
  });
}

/// 假 HttpToolProvider：IO 空转，approve 转正写内存态（断言用）
class _FakeHttpToolProvider extends HttpToolProvider {
  _FakeHttpToolProvider() : super(database: DatabaseService.instance);

  @override
  Future<void> load() async {}

  @override
  bool get loaded => true;

  List<HttpTool> _seed = [];

  @override
  List<HttpTool> get tools => _seed;

  void seed(List<HttpTool> tools) {
    _seed = tools;
    notifyListeners();
  }

  /// approve 转正入口（PendingToolProvider.approve 调用）：写内存态
  void addTool(HttpTool tool) {
    _seed = [..._seed, tool];
    notifyListeners();
  }
}

/// 假 PendingToolProvider：IO 空转，approve/reject 同步内存态
class _FakePendingToolProvider extends PendingToolProvider {
  _FakePendingToolProvider({required _FakeHttpToolProvider httpTools})
      : _httpTools = httpTools,
        super(database: DatabaseService.instance, httpTools: httpTools);

  final _FakeHttpToolProvider _httpTools;

  List<PendingTool> _seed = [];

  @override
  Future<void> load() async {}

  @override
  bool get loaded => true;

  @override
  List<PendingTool> get tools => _seed;

  void seed(List<PendingTool> tools) {
    _seed = tools;
    notifyListeners();
  }

  @override
  Future<HttpTool> approve(PendingTool tool) async {
    _seed = [for (final t in _seed) if (t.id != tool.id) t];
    final httpTool = tool.toHttpTool();
    // 转正写 HttpToolProvider 内存态（真实实现走 DB + load，此处同步）
    _httpTools.addTool(httpTool);
    notifyListeners();
    return httpTool;
  }

  @override
  Future<void> reject(PendingTool tool) async {
    _seed = [for (final t in _seed) if (t.id != tool.id) t];
    notifyListeners();
  }
}
