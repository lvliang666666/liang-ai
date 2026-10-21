import 'dart:convert';

import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/memory_service.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 记忆工具三件套（memory_save / memory_search / memory_forget）行为测试。
///
/// 经 ToolRegistry.execute 走真实链路（参数 JSON 解析 + 异常转 isError），
/// 数据层用 sqflite_ffi 内存库（initForTest 注入单例）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late ToolRegistry registry;

  Future<ToolCallResult> call(String name, Map<String, dynamic> args) =>
      registry.execute(ToolCall(
        id: 'c',
        name: name,
        argumentsJson: args.isEmpty ? '{}' : jsonEncode(args),
      ));

  setUp(() async {
    db = DatabaseService.instance;
    final inMemory = await openTestDb();
    await db.initForTest(inMemory);
    registry = ToolRegistry()..registerAll(builtinTools);
  });

  tearDown(() async {
    await db.close();
  });

  group('工具目录', () {
    test('注册表含全部 29 个内置工具（26 + 记忆 3）', () {
      expect(registry.length, 29);
      expect(
        registry.names,
        containsAll(['memory_save', 'memory_search', 'memory_forget']),
      );
    });
  });

  group('memory_save', () {
    test('保存记忆：返回确认文本，数据落库', () async {
      final r = await call('memory_save', {'content': '用户喜欢简洁回答'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('已记住'));
      expect(r.content, contains('用户喜欢简洁回答'));

      final all = await MemoryService(database: db).getAll();
      expect(all.length, 1);
      expect(all.first.content, '用户喜欢简洁回答');
    });

    test('带 tag 保存：确认文本含标签', () async {
      final r = await call(
          'memory_save', {'content': '用户在上海', 'tag': '背景'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('背景'));

      final all = await MemoryService(database: db).getAll();
      expect(all.first.tag, '背景');
    });

    test('空 tag 视为无标签', () async {
      final r = await call('memory_save', {'content': '事实', 'tag': '  '});
      expect(r.isError, isFalse, reason: r.content);
      expect((await MemoryService(database: db).getAll()).first.tag, isNull);
    });

    test('缺 content：isError 结果，loop 不断', () async {
      final r = await call('memory_save', {});
      expect(r.isError, isTrue);
      expect(r.content, contains('content'));
    });

    test('空 content：isError 结果', () async {
      final r = await call('memory_save', {'content': '   '});
      expect(r.isError, isTrue);
    });

    test('重复保存同内容：去重不新增', () async {
      await call('memory_save', {'content': '喜欢简洁'});
      await call('memory_save', {'content': '喜欢简洁'});
      expect(await MemoryService(database: db).count(), 1);
    });
  });

  group('memory_search', () {
    test('关键词命中：返回匹配列表', () async {
      await call('memory_save', {'content': '用户喜欢简洁回答'});
      await call('memory_save', {'content': '用户在上海工作'});
      await call('memory_save', {'content': '项目用 Flutter'});

      final r = await call('memory_search', {'keyword': '用户'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('找到 2 条'));
      expect(r.content, contains('用户喜欢简洁回答'));
      expect(r.content, contains('用户在上海工作'));
      expect(r.content, isNot(contains('Flutter')));
    });

    test('无命中：友好提示不报错', () async {
      await call('memory_save', {'content': '喜欢简洁'});
      final r = await call('memory_search', {'keyword': '不存在'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('没有找到'));
    });

    test('缺 keyword：isError 结果', () async {
      final r = await call('memory_search', {});
      expect(r.isError, isTrue);
    });
  });

  group('memory_forget', () {
    test('按关键词删除：返回删除条数', () async {
      await call('memory_save', {'content': '记住A'});
      await call('memory_save', {'content': '记住B'});
      await call('memory_save', {'content': '无关C'});

      final r = await call('memory_forget', {'keyword': '记住'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('已删除 2 条'));
      expect(await MemoryService(database: db).count(), 1);
    });

    test('无匹配：提示未删除', () async {
      await call('memory_save', {'content': 'x'});
      final r = await call('memory_forget', {'keyword': '不存在'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('没有找到'));
      expect(await MemoryService(database: db).count(), 1);
    });

    test('缺 keyword：isError 结果', () async {
      final r = await call('memory_forget', {});
      expect(r.isError, isTrue);
    });
  });
}
