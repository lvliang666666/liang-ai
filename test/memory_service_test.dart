import 'package:ai_chat_app/models/memory.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/memory_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

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
    final inMemory = await openTestDb();
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
        sourceAgent: '默认助手',
        createdAt: 1000,
        updatedAt: 2000,
      );
      final restored = Memory.fromMap(m.toMap());
      expect(restored.id, 'm1');
      expect(restored.content, '用户喜欢简洁回答');
      expect(restored.tag, '偏好');
      expect(restored.sourceAgent, '默认助手');
      expect(restored.createdAt, 1000);
      expect(restored.updatedAt, 2000);
    });

    test('可空字段容错：tag/sourceAgent 为 null', () {
      final m = Memory(id: 'm1', content: 'x', createdAt: 1, updatedAt: 1);
      final restored = Memory.fromMap(m.toMap());
      expect(restored.tag, isNull);
      expect(restored.sourceAgent, isNull);
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
      final m = await service.save('用户在上海', tag: '背景', sourceAgent: '导师');
      expect(m.tag, '背景');
      expect(m.sourceAgent, '导师');
      expect((await service.getAll()).first.tag, '背景');
    });

    test('save 去重：同 content 更新时间戳而非新增', () async {
      await service.saveAt('喜欢简洁', now: 1000);
      final updated = await service.saveAt('喜欢简洁', now: 5000);

      expect(updated.updatedAt, 5000);
      expect(updated.createdAt, 1000); // 原条目时间保留
      expect(await service.count(), 1); // 没有新增
    });

    test('save 去重后 tag/sourceAgent 以新值为准', () async {
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

  group('置顶（M1 策展台）', () {
    test('setPinned 置顶与取消，pinned 字段持久化', () async {
      final m = await service.saveAt('置顶记忆', now: 1);
      expect(m.pinned, isFalse); // 默认不置顶

      await service.setPinned(m.id, true);
      expect((await service.getAll()).first.pinned, isTrue);

      await service.setPinned(m.id, false);
      expect((await service.getAll()).first.pinned, isFalse);
    });

    test('setPinned 不存在的 id 静默返回', () async {
      await service.setPinned('不存在', true); // 不抛异常即可
      expect(await service.count(), 0);
    });

    test('recentText：置顶排最前带（置顶）标记，不占 limit 名额', () async {
      await service.saveAt('普通记忆一', now: 1000);
      await service.saveAt('普通记忆二', now: 2000);
      final pinned = await service.saveAt('置顶偏好', now: 500); // 最旧
      await service.setPinned(pinned.id, true);

      final text = await service.recentText(limit: 1);
      expect(text, '''
【用户记忆】（长期有效，跨会话）
- 置顶偏好（置顶）
- 普通记忆二'''); // limit=1 只取 1 条普通，置顶额外
    });

    test('recentText：全部置顶时普通段为空仍正常渲染', () async {
      final m = await service.saveAt('只有置顶', now: 1);
      await service.setPinned(m.id, true);

      final text = await service.recentText();
      expect(text, '''
【用户记忆】（长期有效，跨会话）
- 只有置顶（置顶）''');
    });

    test('update 改写内容与标签，updatedAt 刷新', () async {
      final m = await service.saveAt('原始内容', tag: '旧标签', now: 1000);
      await service.update(m.id, content: '  改写后  ', tag: '新标签');

      final all = await service.getAll();
      expect(all.single.content, '改写后');
      expect(all.single.tag, '新标签');
      expect(all.single.updatedAt, greaterThan(1000));
      expect(all.single.createdAt, 1000); // 创建时间保留
    });

    test('update 只改 tag 时内容保留；空内容不覆盖', () async {
      final m = await service.saveAt('保留内容', now: 1);
      await service.update(m.id, tag: '只改标签');
      expect((await service.getAll()).single.content, '保留内容');

      await service.update(m.id, content: '   ');
      expect((await service.getAll()).single.content, '保留内容');
    });

    test('update 不存在的 id 静默返回', () async {
      await service.update('不存在', content: 'x'); // 不抛异常即可
      expect(await service.count(), 0);
    });

    test('置顶条不参与滚动压缩淘汰', () async {
      // 灌满触发压缩，但把最旧一条置顶保护起来
      final protected = await service.saveAt('置顶的旧记忆', now: 1);
      await service.setPinned(protected.id, true);
      for (var i = 2; i <= MemoryService.maxMemories + 10; i++) {
        await service.saveAt('记忆$i', now: i);
      }

      final all = await service.getAll();
      // 置顶条存活（未被压缩进摘要）
      expect(anyOfMemoryExists(all, '置顶的旧记忆'), isTrue);
      final pinnedRow = all.firstWhere((m) => m.content == '置顶的旧记忆');
      expect(pinnedRow.pinned, isTrue);
      // 未置顶的最旧 40 条照常压缩
      expect(anyOfMemoryExists(all, '记忆2'), isFalse);
      expect(anyOfMemoryExists(all, '记忆41'), isFalse);
      expect(anyOfMemoryExists(all, '记忆42'), isTrue);
    });

    test('置顶条不进归档摘要内容', () async {
      final protected = await service.saveAt('置顶秘密', now: 1);
      await service.setPinned(protected.id, true);
      for (var i = 2; i <= MemoryService.maxMemories + 10; i++) {
        await service.saveAt('记忆$i', now: i);
      }

      final archives =
          (await service.getAll()).where((m) => m.isArchived).toList();
      expect(archives.length, 1);
      expect(archives.single.content, isNot(contains('置顶秘密')));
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

  group('M3 分层与衰减', () {
    test('classifyLayer：偏好关键词 → preference', () {
      expect(MemoryService.classifyLayer('用户喜欢简洁回答'),
          Memory.layerPreference);
      expect(MemoryService.classifyLayer('希望代码多写注释'),
          Memory.layerPreference);
      expect(MemoryService.classifyLayer('讨厌啰嗦的解释'),
          Memory.layerPreference);
    });

    test('classifyLayer：画像关键词 → profile', () {
      expect(MemoryService.classifyLayer('用户在上海做后端开发'),
          Memory.layerProfile);
      expect(MemoryService.classifyLayer('用户是学生，专业是计算机'),
          Memory.layerProfile);
      expect(MemoryService.classifyLayer('用户的技术栈是 Flutter 和 Dart'),
          Memory.layerProfile);
    });

    test('classifyLayer：无关键词 → event（默认层）', () {
      expect(MemoryService.classifyLayer('用户最近在准备一场考试'),
          Memory.layerEvent);
      expect(MemoryService.classifyLayer('普通内容'), Memory.layerEvent);
    });

    test('saveAt 显式 layer 合法时优先；非法值走自动分类', () async {
      final explicit =
          await service.saveAt('内容甲', layer: Memory.layerProfile, now: 1);
      expect(explicit.layer, Memory.layerProfile);

      final invalid =
          await service.saveAt('喜欢简洁', layer: '不存在的层', now: 2);
      expect(invalid.layer, Memory.layerPreference); // 自动分类兜底
    });

    test('recentText 分层配额：画像 5 + 偏好 5 + 事件 10', () async {
      // 灌 8 画像 + 8 偏好 + 15 事件（各超配额），全部未置顶
      for (var i = 1; i <= 8; i++) {
        await service.saveAt('用户是画像$i号工程师', layer: Memory.layerProfile,
            now: i);
      }
      for (var i = 1; i <= 8; i++) {
        await service.saveAt('用户喜欢风格$i简洁', layer: Memory.layerPreference,
            now: 100 + i);
      }
      for (var i = 1; i <= 15; i++) {
        await service.saveAt('事件$i发生了', layer: Memory.layerEvent,
            now: 1000 + i);
      }

      final text = await service.recentText();
      final lines = text.split('\n').skip(1).toList(); // 去标题行
      // 总条数 = 5 + 5 + 10 = 20（配额封顶）
      expect(lines.length, 20);
      // 各层条数：画像 5 / 偏好 5 / 事件 10
      int countLayer(String kw) => lines.where((l) => l.contains(kw)).length;
      expect(countLayer('画像'), 5);
      expect(countLayer('风格'), 5);
      expect(countLayer('事件'), 10);
    });

    test('recentText 事件衰减：比最新记忆旧 30 天以上的事件不注入', () async {
      final day = 24 * 60 * 60 * 1000;
      // 基准：最新记忆 updatedAt = 100 * day
      await service.saveAt('最新事件', layer: Memory.layerEvent,
          now: 100 * day);
      // 29 天前的事件：存活
      await service.saveAt('近期事件', layer: Memory.layerEvent,
          now: 100 * day - 29 * day);
      // 31 天前的事件：衰减
      await service.saveAt('陈旧事件', layer: Memory.layerEvent,
          now: 100 * day - 31 * day);
      // 画像/偏好层不衰减：100 天前的照样注入
      await service.saveAt('用户是老画像', layer: Memory.layerProfile,
          now: 1);
      await service.saveAt('用户喜欢老偏好', layer: Memory.layerPreference,
          now: 1);

      final text = await service.recentText();
      expect(text, contains('最新事件'));
      expect(text, contains('近期事件'));
      expect(text, isNot(contains('陈旧事件')), reason: '超 30 天的事件层记忆不注入');
      expect(text, contains('用户是老画像'));
      expect(text, contains('用户喜欢老偏好'));
    });

    test('衰减不删除：过期事件仍在库中（面板可见可删）', () async {
      final day = 24 * 60 * 60 * 1000;
      await service.saveAt('最新事件', layer: Memory.layerEvent,
          now: 100 * day);
      await service.saveAt('陈旧事件', layer: Memory.layerEvent,
          now: 100 * day - 31 * day);

      expect(await service.count(), 2); // 不删除
      final all = await service.getAll();
      expect(anyOfMemoryExists(all, '陈旧事件'), isTrue);
    });

    test('置顶事件层记忆不衰减（永久记忆语义优先）', () async {
      final day = 24 * 60 * 60 * 1000;
      await service.saveAt('最新事件', layer: Memory.layerEvent,
          now: 100 * day);
      final old = await service.saveAt('置顶的陈旧事件',
          layer: Memory.layerEvent, now: 100 * day - 60 * day);
      await service.setPinned(old.id, true);

      final text = await service.recentText();
      expect(text, contains('置顶的陈旧事件（置顶）'),
          reason: '置顶条走 pinned 通道，不经过衰减过滤');
    });

    test('Memory.isDecayed：非事件层恒 false；事件层按天数判定', () {
      final day = 24 * 60 * 60 * 1000;
      final base = 100 * day;
      final profile = Memory(
          id: 'a',
          content: 'x',
          layer: Memory.layerProfile,
          createdAt: 1,
          updatedAt: base - 100 * day);
      expect(profile.isDecayed(base), isFalse);

      final freshEvent = Memory(
          id: 'b',
          content: 'x',
          layer: Memory.layerEvent,
          createdAt: 1,
          updatedAt: base - 29 * day);
      expect(freshEvent.isDecayed(base), isFalse);

      final staleEvent = Memory(
          id: 'c',
          content: 'x',
          layer: Memory.layerEvent,
          createdAt: 1,
          updatedAt: base - 31 * day);
      expect(staleEvent.isDecayed(base), isTrue);
    });

    test('Memory.fromMap：非法 layer 值回退 event（备份导入防御）', () {
      final m = Memory.fromMap({
        'id': 'x',
        'content': '内容',
        'layer': '不合法的层',
        'created_at': 1,
        'updated_at': 1,
      });
      expect(m.layer, Memory.layerEvent);

      final missing = Memory.fromMap({
        'id': 'y',
        'content': '内容',
        'created_at': 1,
        'updated_at': 1,
      });
      expect(missing.layer, Memory.layerEvent);
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
