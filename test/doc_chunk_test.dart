import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/doc_chunk.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// F8 长文工作台数据层测试：doc_chunks 表 + FTS 检索 + 级联
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
  });

  tearDown(() async {
    await db.close();
  });

  DocChunk chunk(
    String id, {
    String sessionId = 's1',
    String docName = '报销制度.pdf',
    int page = 1,
    int seq = 0,
    String content = '默认内容',
    String sourcePath = '/sandbox/报销制度.pdf',
  }) =>
      DocChunk(
        id: id,
        sessionId: sessionId,
        docName: docName,
        sourcePath: sourcePath,
        page: page,
        seq: seq,
        content: content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  group('replaceDocChunks 写入与幂等', () {
    test('批量写入后可按 id 读回', () async {
      await db.replaceDocChunks('s1', '报销制度.pdf', [
        chunk('doc_1_0', content: '报销流程说明'),
        chunk('doc_1_1', page: 1, seq: 1, content: '发票粘贴规范'),
      ]);
      final got = await db.getDocChunk('doc_1_0');
      expect(got, isNotNull);
      expect(got!.docName, '报销制度.pdf');
      expect(got.page, 1);
      expect(got.sourcePath, '/sandbox/报销制度.pdf');
    });

    test('同会话同文档重挂覆盖旧块（幂等）', () async {
      await db.replaceDocChunks('s1', '报销制度.pdf',
          [chunk('doc_1_0', content: '旧内容')]);
      await db.replaceDocChunks('s1', '报销制度.pdf',
          [chunk('doc_2_0', content: '新内容')]);
      final hits = await db.searchDocChunks('s1', '新内容');
      expect(hits, hasLength(1));
      expect(hits.first.id, 'doc_2_0');
      // 旧块已清
      expect(await db.getDocChunk('doc_1_0'), isNull);
    });

    test('同会话不同文档互不影响', () async {
      await db.replaceDocChunks('s1', 'A.pdf', [chunk('a1', docName: 'A.pdf')]);
      await db.replaceDocChunks('s1', 'B.pdf', [chunk('b1', docName: 'B.pdf')]);
      expect(await db.getDocNames('s1'), hasLength(2));
    });
  });

  group('searchDocChunks 检索', () {
    test('FTS bigram：中文子串命中', () async {
      await db.replaceDocChunks('s1', '报销制度.pdf', [
        chunk('c1', content: '员工出差报销流程：先贴发票再填单子'),
        chunk('c2', page: 2, content: '年假制度：入职满一年五天'),
      ]);
      final hits = await db.searchDocChunks('s1', '报销流程');
      expect(hits.map((c) => c.id), contains('c1'));
      expect(hits.map((c) => c.id), isNot(contains('c2')));
    });

    test('按 (page, seq) 排序返回', () async {
      await db.replaceDocChunks('s1', '报销制度.pdf', [
        chunk('c3', page: 3, content: '报销额度上限'),
        chunk('c1', page: 1, content: '报销申请入口'),
        chunk('c2', page: 2, content: '报销审批流程'),
      ]);
      final hits = await db.searchDocChunks('s1', '报销');
      expect(hits.map((c) => c.page).toList(), [1, 2, 3]);
    });

    test('docName 限定单文档', () async {
      await db.replaceDocChunks('s1', 'A.pdf',
          [chunk('a1', docName: 'A.pdf', content: '报销流程在 A 文档')]);
      await db.replaceDocChunks('s1', 'B.pdf',
          [chunk('b1', docName: 'B.pdf', content: '报销流程在 B 文档')]);
      final hits = await db.searchDocChunks('s1', '报销流程', docName: 'B.pdf');
      expect(hits.map((c) => c.id), ['b1']);
    });

    test('会话隔离：s2 查不到 s1 的块', () async {
      await db.replaceDocChunks('s1', 'A.pdf',
          [chunk('a1', content: '机密内容专属一')]);
      expect(await db.searchDocChunks('s2', '机密内容'), isEmpty);
    });

    test('单字查询走 LIKE 兜底', () async {
      await db.replaceDocChunks('s1', 'A.pdf',
          [chunk('a1', content: '发票粘贴规范')]);
      final hits = await db.searchDocChunks('s1', '票');
      expect(hits, hasLength(1));
    });

    test('limit 生效', () async {
      await db.replaceDocChunks('s1', 'A.pdf', [
        for (var i = 0; i < 10; i++)
          chunk('c$i', page: i + 1, content: '报销条目$i 的说明文字'),
      ]);
      final hits = await db.searchDocChunks('s1', '报销条目', limit: 3);
      expect(hits, hasLength(3));
    });

    test('空查询返回空', () async {
      expect(await db.searchDocChunks('s1', ''), isEmpty);
      expect(await db.searchDocChunks('s1', '  '), isEmpty);
    });
  });

  group('getDocNames', () {
    test('去重 + 最近挂载在前', () async {
      await db.replaceDocChunks('s1', '旧文档.pdf',
          [chunk('o1', docName: '旧文档.pdf')]);
      await Future.delayed(const Duration(milliseconds: 5));
      await db.replaceDocChunks('s1', '新文档.pdf',
          [chunk('n1', docName: '新文档.pdf')]);
      expect(await db.getDocNames('s1'), ['新文档.pdf', '旧文档.pdf']);
    });
  });

  group('会话删除级联', () {
    test('deleteSession 清 doc_chunks + FTS 索引', () async {
      await db.insertSession(ChatSession(
          id: 's9', title: '测试', createdAt: 1, updatedAt: 1));
      await db.replaceDocChunks('s9', 'A.pdf',
          [chunk('z1', sessionId: 's9', content: '将被级联删除的内容')]);
      expect(await db.getDocChunk('z1'), isNotNull);
      await db.deleteSession('s9');
      expect(await db.getDocChunk('z1'), isNull);
      // FTS 索引同步清理（再检索无残留命中）
      expect(await db.searchDocChunks('s9', '级联删除'), isEmpty);
    });
  });

  group('DB 迁移 v19→v20', () {
    test('v19 老库跑迁移链后 doc_chunks 表存在且可写', () async {
      // 手写 v19 schema（被测对象是迁移逻辑本身，见 test_db.dart 头注释），
      // 升级步骤用 DatabaseService.onUpgrade 本尊
      final raw = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 19, onCreate: (db, _) async {
          // v19 最小 schema：只建被迁移链依赖的表（v20 步只建新表，
          // 不读旧表，最小 schema 足够）
          await db.execute('CREATE TABLE sessions ('
              'id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER, '
              'updated_at INTEGER, pinned INTEGER NOT NULL DEFAULT 0)');
          await db.execute('CREATE TABLE messages (id TEXT PRIMARY KEY)');
        }, onUpgrade: DatabaseService.onUpgrade),
      );
      final tables = await raw.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='doc_chunks'");
      expect(tables, hasLength(1));
      // 迁移后的表可写可读
      await raw.insert('doc_chunks', {
        'id': 'm1',
        'session_id': 's1',
        'doc_name': 'A.pdf',
        'source_path': '',
        'page': 1,
        'seq': 0,
        'content': '迁移后写入',
        'created_at': 1,
      });
      final rows = await raw.query('doc_chunks', where: 'id = ?',
          whereArgs: ['m1']);
      expect(rows, hasLength(1));
      await raw.close();
    });
  });
}
