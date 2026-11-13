import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/http_tool.dart';
import 'package:ai_chat_app/models/pending_tool.dart';
import 'package:ai_chat_app/providers/pending_tool_provider.dart';
import 'package:ai_chat_app/providers/http_tool_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 自我迭代工具（v2.32.0）：manage_http_tool 校验 + 审批流转
///
/// 核心行为：
/// - 校验通过 → 入 pending_tools 队列（不落 http_tools——审批闸门）
/// - 重名拒绝（内置工具名 / 已有 HTTP 工具 / 待审批队列三重查重）
/// - 非法名 / 空 URL / 非 http 协议 / 非法 method / 坏 JSON 拒绝
/// - 待审批上限 5 条/会话
/// - 审批通过：pending → http_tools + provider 刷新
/// - 拒绝：pending 删除
/// - 会话删除级联删 pending
/// - builtinToolNames 清单与 builtinTools 实际 name 集合一致（防漂移）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late PendingToolProvider pendingProvider;
  late HttpToolProvider httpProvider;
  late ManageHttpToolTool tool;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    SharedPreferences.setMockInitialValues({});
    httpProvider = HttpToolProvider(database: db);
    await httpProvider.load();
    pendingProvider = PendingToolProvider(database: db, httpTools: httpProvider);
    await pendingProvider.load();
    tool = ManageHttpToolTool(sessionId: 's1');
  });

  tearDown(() async {
    await db.close();
  });

  ChatSession session(String id) => ChatSession(
        id: id,
        title: '测试会话',
        createdAt: 1000,
        updatedAt: 1000,
      );

  Map<String, dynamic> validArgs({String name = 'query_weather'}) => {
        'name': name,
        'description': '查询指定城市的实时天气',
        'url_template': 'https://api.example.com/weather?city={city}',
        'method': 'GET',
        'parameters_json':
            '{"city": {"type": "string", "description": "城市名"}}',
      };

  group('manage_http_tool 校验', () {
    test('校验通过：入 pending 队列，不落 http_tools（审批闸门）', () async {
      await db.insertSession(session('s1'));
      final result = await tool.execute(validArgs());

      expect(result, contains('已提交'));
      final pendings = await db.getPendingToolsForSession('s1');
      expect(pendings.length, 1);
      expect(pendings.first.name, 'query_weather');
      // 审批闸门：http_tools 必须为空
      final httpTools = await db.getAllHttpTools();
      expect(httpTools, isEmpty);
    });

    test('重名：与已有 HTTP 工具同名拒绝', () async {
      await db.insertSession(session('s1'));
      await httpProvider.create(PendingTool(
        id: 'existing',
        sessionId: 's1',
        name: 'query_weather',
        urlTemplate: 'https://old.example.com',
        createdAt: 1,
      ).toHttpTool());

      await expectLater(
        tool.execute(validArgs()),
        throwsA(isA<ArgumentError>()),
      );
      // 未入队
      expect(await db.countPendingTools('s1'), 0);
    });

    test('重名：与内置工具同名拒绝', () async {
      await db.insertSession(session('s1'));
      await expectLater(
        tool.execute(validArgs(name: 'calculate')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('重名：待审批队列中同名拒绝（防重复提交）', () async {
      await db.insertSession(session('s1'));
      await tool.execute(validArgs());
      // 同名再提：拒绝
      await expectLater(
        tool.execute(validArgs()),
        throwsA(isA<ArgumentError>()),
      );
      expect(await db.countPendingTools('s1'), 1);
    });

    test('非法工具名拒绝（空格/中文/超长）', () async {
      await db.insertSession(session('s1'));
      for (final bad in ['查天气', 'has space', 'a${'x' * 70}']) {
        await expectLater(
          tool.execute(validArgs(name: bad)),
          throwsA(isA<ArgumentError>()),
          reason: '非法名 "$bad" 应被拒',
        );
      }
    });

    test('非 http 协议 URL 拒绝', () async {
      await db.insertSession(session('s1'));
      await expectLater(
        tool.execute(validArgs()
          ..['url_template'] = 'file:///etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('非法 method 拒绝', () async {
      await db.insertSession(session('s1'));
      await expectLater(
        tool.execute(validArgs()..['method'] = 'TRACE'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('坏 JSON headers/parameters 拒绝', () async {
      await db.insertSession(session('s1'));
      await expectLater(
        tool.execute(validArgs()..['parameters_json'] = '{bad json'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('待审批超上限拒绝（防刷屏）', () async {
      await db.insertSession(session('s1'));
      for (var i = 0; i < ManageHttpToolTool.maxPendingPerSession; i++) {
        await tool.execute(validArgs(name: 'tool_$i'));
      }
      expect(
        await db.countPendingTools('s1'),
        ManageHttpToolTool.maxPendingPerSession,
      );
      // 第 6 条：拒绝
      await expectLater(
        tool.execute(validArgs(name: 'tool_over')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('缺会话上下文拒绝（注册表未注入 sessionId）', () async {
      await db.insertSession(session('s1'));
      const noSession = ManageHttpToolTool();
      await expectLater(
        noSession.execute(validArgs()),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('审批流转（PendingToolProvider）', () {
    test('approve：pending → http_tools + 双 provider 刷新', () async {
      await db.insertSession(session('s1'));
      await tool.execute(validArgs());
      await pendingProvider.load();
      expect(pendingProvider.tools.length, 1);

      final approved = await pendingProvider.approve(pendingProvider.tools.first);
      expect(httpToolNameIn(httpProvider.tools), contains('query_weather'));
      expect(pendingProvider.tools, isEmpty);
      expect(approved.name, 'query_weather');
    });

    test('reject：pending 删除，http_tools 不受影响', () async {
      await db.insertSession(session('s1'));
      await tool.execute(validArgs());
      await pendingProvider.load();

      await pendingProvider.reject(pendingProvider.tools.first);
      expect(pendingProvider.tools, isEmpty);
      expect(httpProvider.tools, isEmpty);
    });

    test('会话删除级联删 pending', () async {
      await db.insertSession(session('s1'));
      await tool.execute(validArgs());
      expect(await db.countPendingTools('s1'), 1);

      await db.deleteSession('s1');
      expect(await db.countPendingTools('s1'), 0);
    });
  });

  group('builtinToolNames 清单防漂移', () {
    test('清单与 builtinTools 实际 name 集合一致', () {
      final actual = {for (final t in builtinTools) t.name};
      final declared = builtinToolNames.toSet();
      expect(
        declared.difference(actual),
        isEmpty,
        reason: '清单里有但 builtinTools 没有（改名后清单未同步）',
      );
      expect(
        actual.difference(declared),
        isEmpty,
        reason: 'builtinTools 有但清单没登记（新工具忘了加重名校验）',
      );
    });
  });
}

/// HTTP 工具名集合（断言辅助）
Set<String> httpToolNameIn(Iterable<HttpTool> tools) =>
    {for (final t in tools) t.name};
