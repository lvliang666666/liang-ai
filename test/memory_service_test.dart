import 'package:ai_chat_app/models/memory.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/memory_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late MemoryService service;

  setUp(() async {
    db = DatabaseService.instance;
    final inMemory = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 7,
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE memories (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              tag TEXT,
              source_skill TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
        },
      ),
    );
    await db.initForTest(inMemory);
    service = MemoryService(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('Memory 模型', () {
    test('toMap/fromMap 往返一致', () {
      final m = Memory(
        id: 'm1',
        content: '用户喜欢简洁回答',
        tag: '偏好',
        sourceSkill: '默认助手',
        createdAt: 1000,
        updatedAt: 2000,
      );
      final restored = Memory.fromMap(m.toMap());
      expect(restored.id, 'm1');
      expect(restored.content, '用户喜欢简洁回答');
      expect(restored.tag, '偏好');
      expect(restored.sourceSkill, '默认助手');
      expect(restored.createdAt, 1000);
      expect(restored.updatedAt, 2000);
    });

    test('可空字段容错：tag/sourceSkill 为 null', () {
      final m = Memory(id: 'm1', content: 'x', createdAt: 1, updatedAt: 1);
      final restored = Memory.fromMap(m.toMap());
      expect(restored.tag, isNull);
      expect(restored.sourceSkill, isNull);
    });

    test('copyWith 更新部分字段', () {
      final m = Memory(
          id: 'm1', content: '旧', tag: '旧标签', createdAt: 1, updatedAt: 1);
      final updated = m.copyWith(content: '新', updatedAt: 99);
      expect(updated.content, '新');
      expect(updated.tag, '旧标签'); // 未指定保留
      expect(updated.updatedAt, 99);
      expect(updated.createdAt, 1); // 不可变
      expect(updated.id, 'm1');
    });
  });

  group('MemoryService CRUD', () {
    test('save 新建 + getAll 倒序', () async {
      await service.saveAt('第一条', now: 1000);
      await service.saveAt('第二条', now: 2000);

      final all = await service.getAll();
      expect(all.length, 2);
      expect(all[0].content, '第二条'); // updated_at 倒序
      expect(all[1].content, '第一条');
    });

    test('save 带标签与来源', () async {
      final m = await service.save('用户在上海', tag: '背景', sourceSkill: '导师');
      expect(m.tag, '背景');
      expect(m.sourceSkill, '导师');
      expect((await service.getAll()).first.tag, '背景');
    });

    test('save 去重：同 content 更新时间戳而非新增', () async {
      await service.saveAt('喜欢简洁', now: 1000);
      final updated = await service.saveAt('喜欢简洁', now: 5000);

      expect(updated.updatedAt, 5000);
      expect(updated.createdAt, 1000); // 原条目时间保留
      expect(await service.count(), 1); // 没有新增
    });

    test('save 去重后 tag/sourceSkill 以新值为准', () async {
      await service.saveAt('事实A', tag: '旧标签', now: 1000);
      final updated = await service.saveAt('事实A', tag: '新标签', now: 2000);
      expect(updated.tag, '新标签');
    });

    test('save 空内容抛 ArgumentError', () {
      expect(() => service.save('   '), throwsArgumentError);
    });

    test('save 内容自动 trim', () async {
      final m = await service.saveAt('  有空格  ', now: 1);
      expect(m.content, '有空格');
    });

    test('search 关键词 LIKE 匹配', () async {
      await service.saveAt('用户喜欢简洁回答', now: 1);
      await service.saveAt('用户在上海工作', now: 2);
      await service.saveAt('项目用 Flutter', now: 3);

      final hits = await service.search('用户');
      expect(hits.length, 2);

      expect((await service.search('Flutter')).length, 1);
      expect((await service.search('不存在的词')), isEmpty);
    });

    test('search 空关键词返回空列表', () async {
      await service.saveAt('x', now: 1);
      expect(await service.search(''), isEmpty);
      expect(await service.search('  '), isEmpty);
    });

    test('delete 按 id 删除', () async {
      final m = await service.saveAt('待删', now: 1);
      await service.delete(m.id);
      expect(await service.count(), 0);
    });

    test('deleteByKeyword 删除匹配项并返回条数', () async {
      await service.saveAt('记住A', now: 1);
      await service.saveAt('记住B', now: 2);
      await service.saveAt('无关C', now: 3);

      final deleted = await service.deleteByKeyword('记住');
      expect(deleted, 2);
      expect(await service.count(), 1);
      expect((await service.getAll()).first.content, '无关C');
    });

    test('deleteByKeyword 无匹配返回 0', () async {
      await service.saveAt('x', now: 1);
      expect(await service.deleteByKeyword('不存在'), 0);
      expect(await service.count(), 1);
    });

    test('deleteAll 清空', () async {
      await service.saveAt('a', now: 1);
      await service.saveAt('b', now: 2);
      await service.deleteAll();
      expect(await service.count(), 0);
    });
  });

  group('recentText 注入文本', () {
    test('无记忆返回空字符串', () async {
      expect(await service.recentText(), '');
    });

    test('按 updated_at 倒序拼接，带标题行', () async {
      await service.saveAt('记忆一', now: 1000);
      await service.saveAt('记忆二', now: 2000);

      final text = await service.recentText();
      expect(text, '''
【用户记忆】（长期有效，跨会话）
- 记忆二
- 记忆一''');
    });

    test('limit 截断：只取最近 N 条', () async {
      for (var i = 1; i <= 5; i++) {
        await service.saveAt('记忆$i', now: i * 1000);
      }
      final text = await service.recentText(limit: 2);
      expect(text, '''
【用户记忆】（长期有效，跨会话）
- 记忆5
- 记忆4''');
    });
  });

  group('容量上限', () {
    test('超过 200 条删最旧', () async {
      for (var i = 1; i <= MemoryService.maxMemories + 10; i++) {
        await service.saveAt('记忆$i', now: i);
      }
      expect(await service.count(), MemoryService.maxMemories);
      // 最旧的 10 条被删，最新保留
      final all = await service.getAll();
      expect(all.first.content, '记忆${MemoryService.maxMemories + 10}');
      expect(
          anyOfMemoryExists(all, '记忆10'), isFalse); // 第 10 条已被挤出
    });

    test('去重更新不触发误删（更新旧条目时间戳后它变成最新）', () async {
      for (var i = 1; i <= MemoryService.maxMemories; i++) {
        await service.saveAt('记忆$i', now: i);
      }
      // 更新最旧的一条 → 时间戳变最新，不应被挤出
      await service.saveAt('记忆1', now: MemoryService.maxMemories + 1);
      expect(await service.count(), MemoryService.maxMemories);
      final all = await service.getAll();
      expect(all.first.content, '记忆1'); // 升到最新
      // 满员状态下更新不增不减：没有任何条目被挤出
      //（记忆2 时间戳 2 仍是最旧，但总数未超上限，无需删除）
      expect(anyOfMemoryExists(all, '记忆2'), isTrue);
      expect(anyOfMemoryExists(all, '记忆1'), isTrue);
    });
  });
}

bool anyOfMemoryExists(List<Memory> list, String content) =>
    list.any((m) => m.content == content);
