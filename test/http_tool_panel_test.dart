import 'package:ai_chat_app/models/http_tool.dart';
import 'package:ai_chat_app/models/pending_tool.dart';
import 'package:ai_chat_app/pages/http_tool_panel.dart';
import 'package:ai_chat_app/providers/http_tool_provider.dart';
import 'package:ai_chat_app/providers/pending_tool_provider.dart';
import 'package:ai_chat_app/providers/theme_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 假 HttpToolProvider：不碰真实 DB（sqflite_ffi 异步 IO 在 widget 测试
/// fake async 环境推不动，pop 永远等不到），create/update/delete 同步
/// 完成并记录调用参数供断言。
class _FakeHttpToolProvider extends HttpToolProvider {
  _FakeHttpToolProvider()
      : super(database: DatabaseService.instance);

  final List<HttpTool> created = [];
  final List<HttpTool> updated = [];
  final List<String> deleted = [];

  @override
  Future<void> load() async {}

  @override
  Future<void> create(HttpTool tool) async {
    created.add(tool);
    _seed = [tool];
    notifyListeners();
  }

  @override
  Future<void> update(HttpTool tool) async {
    updated.add(tool);
    _seed = [
      for (final t in _seed) if (t.id == tool.id) tool else t,
    ];
    notifyListeners();
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    _seed = [for (final t in _seed) if (t.id != id) t];
    notifyListeners();
  }

  List<HttpTool> _seed = [];

  @override
  bool get loaded => true;

  @override
  List<HttpTool> get tools => _seed;

  void seed(List<HttpTool> tools) {
    _seed = tools;
    notifyListeners();
  }
}

HttpTool seedTool({String name = 'query_weather', bool enabled = true}) =>
    HttpTool(
      id: 'seed-$name',
      name: name,
      description: '查询天气',
      urlTemplate: 'https://api.example.com/w?city={city}',
      method: 'GET',
      parametersJson: '{"city": {"type": "string"}}',
      enabled: enabled,
      createdAt: 1,
      updatedAt: 1,
    );

/// 假 PendingToolProvider：loaded=true 空列表（面板待审批区不渲染）
class _FakePendingToolProvider extends PendingToolProvider {
  _FakePendingToolProvider()
      : super(database: DatabaseService.instance, httpTools: _fakeHttp());

  static HttpToolProvider _fakeHttp() =>
      HttpToolProvider(database: DatabaseService.instance);

  @override
  Future<void> load() async {}

  @override
  bool get loaded => true;

  @override
  List<PendingTool> get tools => const [];
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late _FakeHttpToolProvider provider;
  late SharedPreferences prefs;

  setUp(() async {
    provider = _FakeHttpToolProvider();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    provider.dispose();
  });

  Widget wrap(Widget child) {
    // 自我迭代批次：面板三区合一后依赖 PendingToolProvider（待审批区）
    // + ThemeProvider（审批卡片圆角）。Fake pending：loaded=true 空列表
    //（待审批区不渲染，不干扰原断言）
    final pending = _FakePendingToolProvider();
    final settings = SettingsService(prefs);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<HttpToolProvider>.value(value: provider),
        ChangeNotifierProvider<PendingToolProvider>.value(value: pending),
        ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(settings: settings),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  group('HttpToolPanel', () {
    /// 滚到面板底部（区 3 HTTP 工具）：三区合一后 31 个内置工具
    /// ListTile 把区 3 挤出首屏，ListView 惰性构建下区 3 子树不构建，
    /// 断言前必须滚到底（jumpTo 大值 + settle）
    Future<void> scrollToHttpSection(WidgetTester tester) async {
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(10000);
      await tester.pumpAndSettle();
    }

    testWidgets('空列表：显示空态文案（滚到区 3）', (tester) async {
      await tester.pumpWidget(wrap(const HttpToolPanel()));
      await tester.pump();
      await scrollToHttpSection(tester);

      expect(find.textContaining('还没有自定义 HTTP 工具'), findsOneWidget);
      expect(find.text('新建'), findsOneWidget);
    });

    testWidgets('有工具：列表显示名称/方法徽章/描述（滚到区 3）', (tester) async {
      provider.seed([seedTool()]);
      await tester.pumpWidget(wrap(const HttpToolPanel()));
      await tester.pump();
      await scrollToHttpSection(tester);

      expect(find.text('query_weather'), findsOneWidget);
      expect(find.text('GET'), findsOneWidget);
      expect(find.text('查询天气'), findsOneWidget);
    });

    testWidgets('启用开关：切换后走 update 且 enabled 翻转（滚到区 3）',
        (tester) async {
      provider.seed([seedTool()]);
      await tester.pumpWidget(wrap(const HttpToolPanel()));
      await tester.pump();
      await scrollToHttpSection(tester);

      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(provider.updated, hasLength(1));
      expect(provider.updated.single.enabled, isFalse);
      expect(provider.updated.single.id, 'seed-query_weather');
    });

    testWidgets('删除：确认弹窗后删除（滚到区 3）', (tester) async {
      provider.seed([seedTool()]);
      await tester.pumpWidget(wrap(const HttpToolPanel()));
      await tester.pump();
      await scrollToHttpSection(tester);

      await tester.tap(find.byTooltip('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除工具'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(provider.deleted, ['seed-query_weather']);
    });

    testWidgets('新建入口：点新建打开编辑页（滚到区 3）', (tester) async {
      await tester.pumpWidget(wrap(const HttpToolPanel()));
      await tester.pump();
      await scrollToHttpSection(tester);

      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();

      expect(find.text('新建 HTTP 工具'), findsOneWidget);
      expect(find.text('URL 模板'), findsOneWidget);
    });
  });

  group('HttpToolEditorPage', () {
    testWidgets('新建合法工具：保存走 create 并返回', (tester) async {
      await tester.pumpWidget(wrap(const HttpToolEditorPage()));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, '工具名'), 'nas_status');
      await tester.enterText(
          find.widgetWithText(TextField, '功能描述（模型据此决定何时调用）'),
          '查询 NAS 状态');
      await tester.enterText(
          find.widgetWithText(TextField, 'URL 模板'),
          'https://nas.local/api/status');

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.created, hasLength(1));
      final created = provider.created.single;
      expect(created.name, 'nas_status');
      expect(created.method, 'GET');
      expect(created.urlTemplate, 'https://nas.local/api/status');
      expect(created.description, '查询 NAS 状态');
      // 编辑页已 pop
      expect(find.byType(HttpToolEditorPage), findsNothing);
    });

    testWidgets('工具名非法：不保存，提示错误', (tester) async {
      await tester.pumpWidget(wrap(const HttpToolEditorPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '工具名'), '非法名!');
      await tester.enterText(
          find.widgetWithText(TextField, 'URL 模板'), 'https://x.com');

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(provider.created, isEmpty);
      expect(find.text('工具名只能用字母/数字/下划线/连字符'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('URL 留空：不保存', (tester) async {
      await tester.pumpWidget(wrap(const HttpToolEditorPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '工具名'), 'ok_name');

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(provider.created, isEmpty);
      expect(find.text('URL 模板不能为空'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('请求头坏 JSON：不保存', (tester) async {
      await tester.pumpWidget(wrap(const HttpToolEditorPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '工具名'), 'ok_name');
      await tester.enterText(
          find.widgetWithText(TextField, 'URL 模板'), 'https://x.com');
      await tester.enterText(
          find.widgetWithText(TextField, '请求头（JSON，可选）'), '不是 JSON');

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(provider.created, isEmpty);
      expect(find.text('请求头不是合法 JSON'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('编辑既有工具：走 update 保留原 id，方法可改', (tester) async {
      final original = seedTool();
      provider.seed([original]);
      await tester.pumpWidget(wrap(HttpToolEditorPage(tool: original)));
      await tester.pumpAndSettle();

      // 切方法为 POST（出现请求体模板字段）
      await tester.tap(find.text('GET'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('POST').last);
      await tester.pumpAndSettle();
      expect(find.text('请求体模板（{param} 占位符）'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(provider.updated, hasLength(1));
      expect(provider.updated.single.id, original.id);
      expect(provider.updated.single.method, 'POST');
      expect(provider.created, isEmpty);
    });

    testWidgets('截断长度非法：不保存', (tester) async {
      await tester.pumpWidget(wrap(const HttpToolEditorPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '工具名'), 'ok_name');
      await tester.enterText(
          find.widgetWithText(TextField, 'URL 模板'), 'https://x.com');
      await tester.enterText(
          find.widgetWithText(TextField, '响应截断长度（字符）'), '10');

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(provider.created, isEmpty);
      expect(find.text('截断长度需在 100–100000 之间'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });
  });
}
