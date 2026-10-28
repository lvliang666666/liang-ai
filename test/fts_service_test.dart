import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/fts_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// F1 FTS5 检索底座测试：bigram 分词 + 索引同步 + 搜索
///
/// 核心行为（2026-10-28 探查实证）：
/// - bigram 索引让任意 ≥2 字中文子串可查（unicode61/trigram 都做不到）
/// - 单字走 LIKE 兜底
/// - CRUD 三路径同步：insert/update/delete/截断删除/删会话级联
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late FtsService fts;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    fts = db.ftsOrNull!;
  });

  tearDown(() async {
    await db.close();
  });

  ChatMessage msg(String id, String content,
          {String sessionId = 's1', int at = 1000, String role = 'user'}) =>
      ChatMessage(
        id: id,
        sessionId: sessionId,
        role: role,
        content: content,
        createdAt: at,
      );

  group('bigram 分词', () {
    test('长文本切 2-gram 空格连接', () {
      expect(FtsService.bigram('报销流程'), '报销 销流 流程');
    });

    test('两字词原样返回', () {
      expect(FtsService.bigram('报销'), '报销');
    });

    test('单字原样返回（查询走 LIKE 兜底）', () {
      expect(FtsService.bigram('报'), '报');
    });

    test('英文同样切 bigram（子串可查）', () {
      expect(FtsService.bigram('flutter'), 'fl lu ut tt te er');
    });

    test('查询表达式：bigram 加引号 AND 连接', () {
      expect(FtsService.bigramQuery('报销流程'), '"报销" AND "销流" AND "流程"');
    });

    test('查询词含引号被剥掉（防 MATCH 语法错误）', () {
      expect(FtsService.bigramQuery('报"销'), '"报销"');
    });

    test('空查询/单字查询返回 null（走 LIKE 兜底）', () {
      expect(FtsService.bigramQuery(''), isNull);
      expect(FtsService.bigramQuery('  '), isNull);
      expect(FtsService.bigramQuery('报'), isNull);
    });
  });

  group('索引同步（CRUD 三路径）', () {
    test('insertMessage 后可搜到', () async {
      await db.insertMessage(msg('m1', '今天讨论了报销流程'));
      final hits = await fts.searchMessages('报销');
      expect(hits, hasLength(1));
      expect(hits.first.id, 'm1');
    });

    test('updateMessageContent 后索引跟随新内容', () async {
      await db.insertMessage(msg('m1', '今天讨论了报销流程'));
      await db.updateMessageContent('m1', content: '改成了差旅报销的事');
      final hitsOld = await fts.searchMessages('讨论');
      expect(hitsOld, isEmpty, reason: '旧内容应从索引移除');
      final hitsNew = await fts.searchMessages('差旅');
      expect(hitsNew, hasLength(1));
    });

    test('deleteMessage 后索引同步删除', () async {
      await db.insertMessage(msg('m1', '今天讨论了报销流程'));
      await db.deleteMessage('m1');
      final hits = await fts.searchMessages('报销');
      expect(hits, isEmpty);
    });

    test('deleteMessagesFrom 截断删除同步清索引', () async {
      await db.insertMessage(msg('m1', '第一条关于报销', at: 1000));
      await db.insertMessage(msg('m2', '第二条关于差旅', at: 2000));
      await db.insertMessage(msg('m3', '第三条关于开会', at: 3000));
      // 截断删除 m2 及其后
      await db.deleteMessagesFrom('m2', 2000);
      expect(await fts.searchMessages('差旅'), isEmpty);
      expect(await fts.searchMessages('开会'), isEmpty);
      expect(await fts.searchMessages('报销'), hasLength(1));
    });

    test('deleteSession 级联清索引', () async {
      await db.insertMessage(msg('m1', '会话一关于报销', sessionId: 's1'));
      await db.insertMessage(msg('m2', '会话二关于开会', sessionId: 's2'));
      await db.deleteSession('s1');
      expect(await fts.searchMessages('报销'), isEmpty);
      expect(await fts.searchMessages('开会'), hasLength(1));
    });

    test('空内容消息不进索引', () async {
      await db.insertMessage(msg('m1', ''));
      await db.insertMessage(msg('m2', '   '));
      final rows = await (await db.database)
          .rawQuery('SELECT COUNT(*) AS c FROM messages_fts');
      expect(rows.first['c'], 0);
    });

    test('流式更新（同 id 反复 update）不产生重复索引行', () async {
      await db.insertMessage(msg('m1', '流'));
      await db.updateMessageContent('m1', content: '流式');
      await db.updateMessageContent('m1', content: '流式回答内容');
      final rows = await (await db.database)
          .rawQuery('SELECT COUNT(*) AS c FROM messages_fts');
      expect(rows.first['c'], 1, reason: '同 id 更新应复用同一索引行');
      final hits = await fts.searchMessages('流式回答');
      expect(hits, hasLength(1));
    });
  });

  group('searchMessages 查询行为', () {
    test('两字中文词命中', () async {
      await db.insertMessage(msg('m1', '报销流程怎么走'));
      await db.insertMessage(msg('m2', '明天开会'));
      final hits = await fts.searchMessages('开会');
      expect(hits, hasLength(1));
      expect(hits.first.id, 'm2');
    });

    test('三字以上子串命中（跨 bigram 边界）', () async {
      await db.insertMessage(msg('m1', '今天讨论了报销流程的事情'));
      final hits = await fts.searchMessages('销流程');
      expect(hits, hasLength(1), reason: '销流程 跨两个 bigram，AND 连接应命中');
    });

    test('英文子串命中', () async {
      await db.insertMessage(msg('m1', 'flutter is awesome'));
      final hits = await fts.searchMessages('awesome');
      expect(hits, hasLength(1));
    });

    test('单字走 LIKE 兜底', () async {
      await db.insertMessage(msg('m1', '报销流程'));
      final hits = await fts.searchMessages('报');
      expect(hits, hasLength(1));
    });

    test('sessionId 限定会话', () async {
      await db.insertMessage(msg('m1', '报销流程', sessionId: 's1'));
      await db.insertMessage(msg('m2', '报销流程', sessionId: 's2'));
      final hits = await fts.searchMessages('报销', sessionId: 's2');
      expect(hits, hasLength(1));
      expect(hits.first.sessionId, 's2');
    });

    test('limit 截断且按时间倒序', () async {
      for (var i = 0; i < 5; i++) {
        await db.insertMessage(msg('m$i', '报销事项 $i', at: 1000 + i));
      }
      final hits = await fts.searchMessages('报销', limit: 3);
      expect(hits, hasLength(3));
      expect(hits.first.createdAt, greaterThan(hits.last.createdAt));
    });

    test('不存在的词返回空', () async {
      await db.insertMessage(msg('m1', '报销流程'));
      expect(await fts.searchMessages('不存在的词'), isEmpty);
    });

    test('空查询返回空', () async {
      await db.insertMessage(msg('m1', '报销流程'));
      expect(await fts.searchMessages(''), isEmpty);
      expect(await fts.searchMessages('   '), isEmpty);
    });

    test('查询词含引号不炸 MATCH', () async {
      await db.insertMessage(msg('m1', '他说"你好"然后走了'));
      final hits = await fts.searchMessages('"你好"');
      expect(hits, hasLength(1));
    });
  });

  group('rebuildIndex 全量重建', () {
    test('空索引时重建补齐存量消息', () async {
      // 直接插 DB（绕过 insertMessage 的索引同步，模拟老库存量数据）
      final database = await db.database;
      await database.insert('messages', msg('m1', '存量消息关于报销').toMap());
      await database.insert('messages', msg('m2', '存量消息关于开会').toMap());
      // 索引为空 → rebuild
      await db.rebuildFtsIndexIfEmpty();
      expect(await fts.searchMessages('报销'), hasLength(1));
      expect(await fts.searchMessages('开会'), hasLength(1));
    });

    test('索引非空时 rebuildFtsIndexIfEmpty 零操作（幂等）', () async {
      await db.insertMessage(msg('m1', '已有索引的消息'));
      // 再插一条绕过同步的（模拟异常态），rebuildIfEmpty 不应触发
      final database = await db.database;
      await database.insert('messages', msg('m2', '没进索引的消息').toMap());
      await db.rebuildFtsIndexIfEmpty();
      // m1 可查（索引在），m2 不可查（没重建）
      expect(await fts.searchMessages('已有索引'), hasLength(1));
      expect(await fts.searchMessages('没进索引'), isEmpty);
    });

    test('rebuildIndex 幂等可重复调用', () async {
      final database = await db.database;
      await database.insert('messages', msg('m1', '重建测试消息').toMap());
      await fts.rebuildIndex();
      await fts.rebuildIndex();
      final rows =
          await database.rawQuery('SELECT COUNT(*) AS c FROM messages_fts');
      expect(rows.first['c'], 1, reason: '重复重建不产生重复索引');
      expect(await fts.searchMessages('重建测试'), hasLength(1));
    });
  });

  group('DB v13 迁移', () {
    test('v12 老库升级后 FTS 表存在且可搜索', () async {
      // 手写 v12 schema（被测对象是迁移链），升级用生产 onUpgrade 本尊
      final dbFile = await openTestDbFromVersion(12);
      // v12 schema 应已有 sessions/messages 等表（fixture 建的 v1 基线
      // 逐版本迁移上来），插一条消息验证升级后索引可用
      await dbFile.insert('messages', {
        'id': 'm1',
        'session_id': 's1',
        'role': 'user',
        'content': '迁移后可搜索的消息',
        'reasoning': '',
        'attachments': '[]',
        'tool_calls': '[]',
        'pinned': 0,
        'created_at': 1000,
      });
      // 升级到 v13（fixture 已在打开时跑完迁移链，这里验证表存在）
      // FTS5 虚表带影子表（_data/_idx/_content/_docsize/_config），
      // 精确断言两个目标表名
      final tables = await dbFile.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name IN ('messages_fts', 'messages_fts_rowid')");
      expect(tables, hasLength(2),
          reason: 'messages_fts 虚表 + messages_fts_rowid 映射表');
      // 应用层补索引后可搜索
      final svc = DatabaseService.instance;
      await svc.initForTest(dbFile);
      await svc.rebuildFtsIndexIfEmpty();
      final hits = await svc.ftsOrNull!.searchMessages('可搜索');
      expect(hits, hasLength(1));
      await svc.close();
    });
  });

  group('FTS5 不可用降级（v2.11.0 真机白屏修复）', () {
    test('ftsAvailable=false：ftsOrNull 为 null，CRUD 不炸', () async {
      // 模拟真机系统 SQLite 无 FTS5 模块（探测失败态）
      DatabaseService.ftsAvailable = false;
      addTearDown(() => DatabaseService.ftsAvailable = null);

      // 消息 CRUD 三路径正常（索引同步被跳过）
      await db.insertMessage(msg('m1', '今天讨论了报销流程'));
      await db.updateMessageContent('m1', content: '改后的内容');
      await db.deleteMessage('m1');
      expect(db.ftsOrNull, isNull, reason: 'FTS5 不可用时服务不创建');
    });

    test('LIKE 兜底搜索：多字查询同样命中', () async {
      DatabaseService.ftsAvailable = false;
      addTearDown(() => DatabaseService.ftsAvailable = null);

      await db.insertMessage(msg('m1', '今天讨论了报销流程'));
      await db.insertMessage(msg('m2', '明天去公园玩', sessionId: 's2'));

      // 多字查询走 LIKE 兜底（正常走 FTS 的路径也降级）
      final hits = await db.searchMessagesLike('报销');
      expect(hits, hasLength(1));
      expect(hits.first.id, 'm1');

      // 会话过滤
      final scoped = await db.searchMessagesLike('玩', sessionId: 's2');
      expect(scoped, hasLength(1));
      expect(scoped.first.id, 'm2');

      // 无命中
      expect(await db.searchMessagesLike('不存在的词'), isEmpty);
      // 空查询
      expect(await db.searchMessagesLike('  '), isEmpty);
    });

    test('抽屉搜索降级路径：ftsOrNull null 时走 LIKE', () async {
      DatabaseService.ftsAvailable = false;
      addTearDown(() => DatabaseService.ftsAvailable = null);

      await db.insertMessage(msg('m1', '今天讨论了报销流程'));
      // 模拟 session_drawer_panel 的降级表达式
      final hits = await DatabaseService.instance.ftsOrNull
              ?.searchMessages('报销', limit: 20) ??
          await db.searchMessagesLike('报销', limit: 20);
      expect(hits, hasLength(1));
      expect(hits.first.id, 'm1');
    });

    test('close 后探测状态重置（下个库重新探测）', () async {
      DatabaseService.ftsAvailable = false;
      await db.close();
      expect(DatabaseService.ftsAvailable, isNull,
          reason: '探测结果随库关闭重置');
    });
  });
}
