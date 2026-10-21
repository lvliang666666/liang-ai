import 'package:ai_chat_app/models/memory.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/memory_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 归一化函数暴露给测试断言用（与 MemoryService.normalize 同源）
String norm(String s) => MemoryService.normalize(s);

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

    test('近似去重：仅标点/空白/大小写差异视为同一条', () async {
      await service.saveAt('用户喜欢简洁回答。', now: 1000);
      final updated = await service.saveAt('用户，喜欢 简洁回答', now: 2000);
      expect(await service.count(), 1);
      expect(updated.updatedAt, 2000);
      expect(updated.createdAt, 1000); // 原条目时间保留
    });

    test('近似去重：英文大小写归一化', () async {
      await service.saveAt('User likes Flutter', now: 1000);
      await service.saveAt('user likes flutter', now: 2000);
      expect(await service.count(), 1);
    });

    test('包含合并：新句包含旧句时保留信息更全的新句', () async {
      await service.saveAt('用户在上海工作', now: 1000);
      final updated =
          await service.saveAt('用户在上海工作，公司做人工智能', now: 2000);
      expect(await service.count(), 1);
      expect(updated.content, '用户在上海工作，公司做人工智能');
    });

    test('包含合并：旧句信息更全时保留旧句（只刷新时间戳）', () async {
      await service.saveAt('用户喜欢简洁回答，讨厌冗长废话', now: 1000);
      final updated = await service.saveAt('用户喜欢简洁回答', now: 2000);
      expect(await service.count(), 1);
      expect(updated.content, '用户喜欢简洁回答，讨厌冗长废话');
      expect(updated.updatedAt, 2000);
    });

    test('部分重叠不合并：互不包含的两句正常共存', () async {
      await service.saveAt('用户在上海浦东新区工作，公司做人工智能', now: 1000);
      await service.saveAt('用户在上海工作', now: 2000);
      expect(await service.count(), 2); // 「上海工作」不是长句的子串
    });

    test('包含合并不误伤：短边不足 6 字不合并', () async {
      await service.saveAt('用户喜欢简洁回答风格', now: 1000);
      await service.saveAt('喜欢简洁', now: 2000);
      expect(await service.count(), 2); // 「喜欢简洁」只有 4 字，不合并
    });

    test('否定句守卫：「喜欢」与「不喜欢」不合并', () async {
      await service.saveAt('用户不喜欢冗长回答', now: 1000);
      await service.saveAt('用户喜欢冗长回答', now: 2000);
      expect(await service.count(), 2);
    });

    test('归档行不参与去重：新记忆与归档内容相同仍正常新建', () async {
      // 手工造一条归档行
      await service.saveAt('用户喜欢简洁回答', tag: Memory.archiveTag, now: 1);
      await service.saveAt('用户喜欢简洁回答', now: 2);
      expect(await service.count(), 2);
      final all = await service.getAll();
      final active = all.where((m) => !m.isArchived).toList();
      expect(active.single.content, '用户喜欢简洁回答');
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

    test('deleteByKeyword 不删归档行', () async {
      await service.saveAt('用户喜欢简洁回答', now: 1);
      await service.saveAt('用户喜欢简洁回答', tag: Memory.archiveTag, now: 2);

      final deleted = await service.deleteByKeyword('简洁');
      expect(deleted, 1); // 只删活跃那条
      expect(await service.count(), 1);
      expect((await service.getAll()).single.isArchived, isTrue);
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

    test('归档行置尾单独成段，不占活跃条数名额', () async {
      await service.saveAt('活跃记忆A', now: 1000);
      await service.saveAt('活跃记忆B', now: 2000);
      await service.saveAt('归档摘要内容', tag: Memory.archiveTag, now: 500);

      final text = await service.recentText(limit: 2);
      expect(text, '''
【用户记忆】（长期有效，跨会话）
- 活跃记忆B
- 活跃记忆A
【历史归档】（早期记忆的压缩摘要，仅供参考）
- 归档摘要内容''');
    });

    test('只有归档行时也正常渲染归档段', () async {
      await service.saveAt('归档摘要内容', tag: Memory.archiveTag, now: 1);
      final text = await service.recentText();
      expect(text, '''
【用户记忆】（长期有效，跨会话）
【历史归档】（早期记忆的压缩摘要，仅供参考）
- 归档摘要内容''');
    });
  });

  group('容量上限（滚动压缩）', () {
    test('超过 200 条：最旧 40 条活跃记忆压缩为一条归档摘要', () async {
      for (var i = 1; i <= MemoryService.maxMemories + 10; i++) {
        await service.saveAt('记忆$i', now: i);
      }
      // 210 - 40（压缩） + 1（归档行） = 171
      expect(await service.count(), MemoryService.maxMemories + 10 - 40 + 1);
      final all = await service.getAll();
      // 最新记忆保留
      expect(all.first.content, '记忆${MemoryService.maxMemories + 10}');
      // 最旧 40 条（记忆1~40）已从活跃区消失
      expect(anyOfMemoryExists(all, '记忆1'), isFalse);
      expect(anyOfMemoryExists(all, '记忆40'), isFalse);
      // 第 41 条仍在
      expect(anyOfMemoryExists(all, '记忆41'), isTrue);
      // 归档摘要行存在且包含被压缩条目的内容
      final archived = all.where((m) => m.isArchived).toList();
      expect(archived.length, 1);
      expect(archived.single.content, contains('记忆1'));
      expect(archived.single.content, contains('记忆40'));
      expect(archived.single.tag, Memory.archiveTag);
    });

    test('归档行永不二次压缩：池满后归档行保留', () async {
      // 第一轮压缩产生归档行
      for (var i = 1; i <= MemoryService.maxMemories + 40; i++) {
        await service.saveAt('记忆$i', now: i);
      }
      final firstArchive = (await service.getAll())
          .where((m) => m.isArchived)
          .toList();
      expect(firstArchive.length, 1);

      // 再灌 40 条触发第二轮压缩，旧归档行仍在
      for (var i = 241; i <= 280; i++) {
        await service.saveAt('记忆$i', now: i);
      }
      final archives = (await service.getAll())
          .where((m) => m.isArchived)
          .toList();
      expect(archives.length, 2); // 两轮各一条，互不合并
      expect(archives.any((m) => m.id == firstArchive.single.id), isTrue);
    });

    test('去重更新不触发误压缩（更新旧条目时间戳后它变成最新）', () async {
      for (var i = 1; i <= MemoryService.maxMemories; i++) {
        await service.saveAt('记忆$i', now: i);
      }
      // 更新最旧的一条 → 时间戳变最新，不应被压缩
      await service.saveAt('记忆1', now: MemoryService.maxMemories + 1);
      expect(await service.count(), MemoryService.maxMemories);
      final all = await service.getAll();
      expect(all.first.content, '记忆1'); // 升到最新
      // 满员状态下更新不增不减：没有任何条目被压缩
      expect(all.where((m) => m.isArchived), isEmpty);
      expect(anyOfMemoryExists(all, '记忆2'), isTrue);
    });
  });

  group('归一化 normalize', () {
    test('去空白/标点/大小写', () {
      expect(norm('用户，喜欢 简洁回答。'), '用户喜欢简洁回答');
      expect(norm('User Likes Flutter!'), 'userlikesflutter');
      expect(norm('  有 空格  '), '有空格');
    });

    test('中文引号与破折号也去除', () {
      expect(norm('「记住」——这件事'), '记住这件事');
    });
  });

  group('变更信号 changeSignal', () {
    int counter = 0;
    late VoidCallback listener;

    setUp(() {
      counter = MemoryService.changeSignal.value;
      listener = () => counter++;
      MemoryService.changeSignal.addListener(listener);
    });

    tearDown(() {
      MemoryService.changeSignal.removeListener(listener);
    });

    test('save 新增触发信号', () async {
      await service.save('新记忆');
      expect(counter, greaterThan(MemoryService.changeSignal.value - 2));
      expect(counter, MemoryService.changeSignal.value);
    });

    test('save 去重更新同样触发信号', () async {
      await service.save('同内容');
      final afterFirst = MemoryService.changeSignal.value;
      await service.save('同内容'); // 去重 → update 路径
      expect(MemoryService.changeSignal.value, afterFirst + 1);
    });

    test('delete 触发信号', () async {
      final m = await service.save('待删');
      final afterSave = MemoryService.changeSignal.value;
      await service.delete(m.id);
      expect(MemoryService.changeSignal.value, afterSave + 1);
    });

    test('deleteByKeyword 命中触发信号，未命中不触发', () async {
      await service.save('关键词记忆ABC');
      final afterSave = MemoryService.changeSignal.value;

      await service.deleteByKeyword('不存在的关键词');
      expect(MemoryService.changeSignal.value, afterSave); // 未命中不触发

      await service.deleteByKeyword('ABC');
      expect(MemoryService.changeSignal.value, afterSave + 1);
    });

    test('deleteAll 触发信号', () async {
      await service.save('a');
      final afterSave = MemoryService.changeSignal.value;
      await service.deleteAll();
      expect(MemoryService.changeSignal.value, afterSave + 1);
    });
  });
}

bool anyOfMemoryExists(List<Memory> list, String content) =>
    list.any((m) => m.content == content);
