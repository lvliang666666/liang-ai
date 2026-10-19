import 'package:ai_chat_app/models/skill.dart';
import 'package:ai_chat_app/pages/skill_editor_page.dart';
import 'package:ai_chat_app/providers/skill_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/skill_service.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late SkillProvider skillProvider;

  setUp(() async {
    final inMemory = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, title TEXT NOT NULL,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              effort TEXT NOT NULL DEFAULT 'max', agent_id TEXT,
              skill_id TEXT, provider_id TEXT, model TEXT
            )
          ''');
          await d.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
              content TEXT NOT NULL DEFAULT '', reasoning TEXT NOT NULL DEFAULT '',
              attachments TEXT NOT NULL DEFAULT '[]',
              tool_calls TEXT NOT NULL DEFAULT '[]', tool_call_id TEXT,
              created_at INTEGER NOT NULL
            )
          ''');
          await d.execute(
            'CREATE INDEX idx_messages_session ON messages(session_id, created_at)',
          );
          await d.execute('''
            CREATE TABLE skills (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              icon TEXT NOT NULL DEFAULT '🤖', description TEXT NOT NULL DEFAULT '',
              prompt TEXT NOT NULL DEFAULT '', temperature REAL, effort TEXT,
              tools TEXT, is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await d.execute('''
            CREATE TABLE providers (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              base_url TEXT NOT NULL DEFAULT '', api_key TEXT NOT NULL DEFAULT '',
              default_model TEXT NOT NULL DEFAULT '',
              capabilities TEXT NOT NULL DEFAULT '{}',
              dialect TEXT NOT NULL DEFAULT '{}',
              is_builtin INTEGER NOT NULL DEFAULT 0
            )
          ''');
        },
      ),
    );
    db = DatabaseService.instance;
    await db.initForTest(inMemory);

    skillProvider = SkillProvider(service: SkillService(database: db));
    await skillProvider.load();
  });

  tearDown(() async {
    skillProvider.dispose();
    await db.close();
  });

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SkillProvider>.value(value: skillProvider),
        ],
        child: MaterialApp(home: child),
      );

  /// 内置 Skill（资产种子里的第一个）
  Skill builtinSkill() => skillProvider.builtins.first;

  group('SkillEditorPage', () {
    testWidgets('新建默认全勾：直接保存 → toolNames == null', (tester) async {
      await tester.pumpWidget(wrap(const SkillEditorPage()));

      // 填名称（基本信息分区）
      await tester.enterText(
          find.widgetWithText(TextField, '名称'), '测试 Skill');
      await tester.pump();

      // 切到提示词分区填写（PageView 未缓存页不在树中，需先切页）
      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, '系统提示词（System Prompt）'), '你是测试');
      await tester.pump();

      // 切到可用工具分区确认全勾
      await tester.tap(find.text('可用工具'));
      await tester.pumpAndSettle();
      for (final t in builtinTools) {
        final tile = tester.widget<CheckboxListTile>(
          find.ancestor(
            of: find.text(t.name),
            matching: find.byType(CheckboxListTile),
          ),
        );
        expect(tile.value, isTrue, reason: '${t.name} 默认应勾选');
      }

      // 保存（create 是异步 DB 写入，pop 在 await 之后）
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // pop 回来了
      expect(find.byType(SkillEditorPage), findsNothing);

      // provider 中新增的 Skill：toolNames == null（全勾语义）
      final created =
          skillProvider.customs.firstWhere((s) => s.name == '测试 Skill');
      expect(created.toolNames, isNull);
      expect(created.prompt, '你是测试');
    });

    testWidgets('新建去勾一个工具：保存 → toolNames 为显式子集', (tester) async {
      await tester.pumpWidget(wrap(const SkillEditorPage()));

      await tester.enterText(
          find.widgetWithText(TextField, '名称'), '子集 Skill');
      await tester.pump();

      // 切到提示词分区填写
      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, '系统提示词（System Prompt）'), 'p');
      await tester.pump();

      // 切到可用工具分区，去勾第一个工具
      await tester.tap(find.text('可用工具'));
      await tester.pumpAndSettle();
      final removedTool = builtinTools.first;
      await tester.tap(find.text(removedTool.name));
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      final created =
          skillProvider.customs.firstWhere((s) => s.name == '子集 Skill');
      expect(created.toolNames, isNotNull);
      expect(created.toolNames!.length, builtinTools.length - 1);
      expect(created.toolNames, isNot(contains(removedTool.name)));
    });

    testWidgets('名称留空点保存：不 pop，仍在编辑页', (tester) async {
      await tester.pumpWidget(wrap(const SkillEditorPage()));

      // 只填提示词，名称留空（先切到提示词分区）
      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, '系统提示词（System Prompt）'), 'p');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pump(const Duration(milliseconds: 400)); // 动画 + SnackBar

      // 未 pop：编辑页还在
      expect(find.byType(SkillEditorPage), findsOneWidget);
      // 提示了名称错误
      expect(find.text('名称不能为空'), findsOneWidget);

      // 收尾：让 SnackBar timer 走完，避免 pending timer 报错
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('内置 Skill：只读查看，无保存按钮', (tester) async {
      await tester.pumpWidget(wrap(SkillEditorPage(skill: builtinSkill())));
      await tester.pumpAndSettle();

      // 标题为查看
      expect(find.text('查看 Skill'), findsOneWidget);
      // 无保存按钮
      expect(find.text('保存'), findsNothing);
      // 名称输入框禁用
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, '名称'),
      );
      expect(nameField.enabled, isFalse);
      // 工具勾选框禁用（切到可用工具分区）
      await tester.tap(find.text('可用工具'));
      await tester.pumpAndSettle();
      final tile = tester.widget<CheckboxListTile>(
        find.ancestor(
          of: find.text(builtinTools.first.name),
          matching: find.byType(CheckboxListTile),
        ),
      );
      expect(tile.onChanged, isNull);

      // 取消退出
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(SkillEditorPage), findsNothing);
    });
  });
}
