import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import 'database_service.dart';

/// FTS5 检索底座（F1）：中文 bigram 分词 + 会话消息全文搜索
///
/// **为什么 bigram 自管索引**（2026-10-28 实证）：
/// - unicode61 对连续 CJK 整段成 token，「报销」查不到「…报销流程…」
/// - trigram 需要 ≥3 字符，两字中文词（最高频查询）查不到
/// - bigram：文本切 2-gram 空格连接存 FTS（unicode61 按空格分词），
///   查询词同样切 bigram 用 AND 连接——任意 ≥2 字子串都能命中；
///   单字（1 字符）FTS 无法表达，走 LIKE 兜底
/// - 触发器方案不可行（触发器内无法调用 Dart bigram 函数），
///   同步在应用层做：insert/update/delete 三路径同步写 FTS 表
///
/// 索引表结构（DB v13）：
/// - messages_fts：FTS5 虚表（content 列，unicode61），rowid = messages.rowid
/// - messages_fts_rowid：id ↔ rowid 映射（messages 主键是 TEXT，
///   FTS rowid 是 INTEGER，映射表桥接；应用层同步时先查映射）
///
/// 高亮：FTS 索引存的是变形文本（bigram+空格），snippet() 不可用；
/// 命中后在 Dart 侧对原文做 String.indexOf 定位高亮偏移，简单可靠。
class FtsService {
  FtsService(this._db);

  final DatabaseService _db;

  /// 索引同步是 best-effort：FTS 是可重建的派生数据（rebuildIndex 全量补齐），
  /// 同步失败（典型：流式收尾的 fire-and-forget 落库与测试 tearDown 的
  /// db.close() 竞态，或进程退出瞬间）绝不能炸主链路——消息落库成功即
  /// 数据无损，索引缺行只影响该条可搜性，下次全量重建自动修复。
  /// 搜索侧 JOIN messages 天然过滤孤儿索引行，不会误报。
  Future<void> _guarded(Future<void> Function() op, String label) async {
    try {
      await op();
    } catch (e) {
      debugPrint('FtsService.$label 失败（索引可重建，忽略）：$e');
    }
  }

  /// 文本切 bigram（空格连接）。≤2 字符原样返回（单字查询走 LIKE 兜底，
  /// 两字词本身就是一个 bigram）
  static String bigram(String text) {
    final runes = text.runes.toList();
    if (runes.length <= 2) return text;
    final out = <String>[];
    for (var i = 0; i + 2 <= runes.length; i++) {
      out.add(String.fromCharCodes(runes.sublist(i, i + 2)));
    }
    return out.join(' ');
  }

  /// 查询词转 FTS MATCH 表达式：切 bigram 后每项加引号用 AND 连接。
  /// 单字返回 null（调用方走 LIKE 兜底）。
  /// 特殊字符（引号）剥掉防 MATCH 语法错误。
  static String? bigramQuery(String query) {
    final q = query.replaceAll('"', '').trim();
    if (q.isEmpty) return null;
    final runes = q.runes.toList();
    if (runes.length < 2) return null;
    final out = <String>[];
    for (var i = 0; i + 2 <= runes.length; i++) {
      out.add('"${String.fromCharCodes(runes.sublist(i, i + 2))}"');
    }
    return out.join(' AND ');
  }

  /// 写入/更新一条消息的 FTS 索引（应用层同步，insert/update 共用）
  Future<void> indexMessage(ChatMessage message) => _guarded(() async {
        final db = await _db.database;
        final content = message.content;
        if (content.trim().isEmpty) {
          await removeMessage(message.id);
          return;
        }
        // 查现有映射
        final rows = await db.query('messages_fts_rowid',
            where: 'id = ?', whereArgs: [message.id]);
        if (rows.isNotEmpty) {
          // 已有索引：更新（先删旧 rowid 行再插）
          final rowid = rows.first['rowid'] as int;
          await db
              .execute('DELETE FROM messages_fts WHERE rowid = ?', [rowid]);
          await db.insert('messages_fts', {
            'rowid': rowid,
            'content': bigram(content),
          });
        } else {
          // 新索引：分配新 rowid（自增），写映射表
          final rowid = await db.insert('messages_fts', {
            'content': bigram(content),
          });
          await db.insert('messages_fts_rowid', {
            'id': message.id,
            'rowid': rowid,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }, 'indexMessage');

  /// 删除一条消息的 FTS 索引
  Future<void> removeMessage(String messageId) => _guarded(() async {
        final db = await _db.database;
        final rows = await db.query('messages_fts_rowid',
            where: 'id = ?', whereArgs: [messageId]);
        if (rows.isEmpty) return;
        final rowid = rows.first['rowid'] as int;
        await db.execute('DELETE FROM messages_fts WHERE rowid = ?', [rowid]);
        await db.delete('messages_fts_rowid',
            where: 'id = ?', whereArgs: [messageId]);
      }, 'removeMessage');

  /// 删除一个会话全部消息的 FTS 索引（deleteSession 级联）
  Future<void> removeSession(String sessionId) => _guarded(() async {
        final db = await _db.database;
        final rows = await db.rawQuery('''
      SELECT r.id, r.rowid FROM messages_fts_rowid r
      JOIN messages m ON m.id = r.id
      WHERE m.session_id = ?
    ''', [sessionId]);
        for (final row in rows) {
          await db.execute(
              'DELETE FROM messages_fts WHERE rowid = ?', [row['rowid']]);
          await db.delete('messages_fts_rowid',
              where: 'id = ?', whereArgs: [row['id']]);
        }
      }, 'removeSession');

  /// 全文搜索会话消息
  ///
  /// [query] ≥2 字走 FTS bigram 匹配；1 字走 LIKE 兜底。
  /// [sessionId] 限定会话（null = 全部会话）。
  /// [limit] 返回上限（默认 50，按时间倒序）。
  /// 返回命中消息列表（含会话归属，UI 显示会话名 + 缩略）。
  Future<List<ChatMessage>> searchMessages(
    String query, {
    String? sessionId,
    int limit = 50,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final db = await _db.database;

    final sessionFilter =
        sessionId != null ? 'AND m.session_id = ?' : '';
    final args = <Object?>[];

    if (q.runes.length >= 2) {
      // FTS bigram 路径
      final match = bigramQuery(q);
      if (match == null) return const [];
      args.add(match);
      if (sessionId != null) args.add(sessionId);
      args.add(limit);
      final rows = await db.rawQuery('''
        SELECT m.* FROM messages_fts f
        JOIN messages m ON m.id = (SELECT id FROM messages_fts_rowid WHERE rowid = f.rowid)
        WHERE messages_fts MATCH ? $sessionFilter
        ORDER BY m.created_at DESC
        LIMIT ?
      ''', args);
      return rows.map(ChatMessage.fromMap).toList();
    }

    // 单字 LIKE 兜底
    args.add('%$q%');
    if (sessionId != null) args.add(sessionId);
    args.add(limit);
    final rows = await db.rawQuery('''
      SELECT * FROM messages m
      WHERE content LIKE ? $sessionFilter
      ORDER BY created_at DESC
      LIMIT ?
    ''', args);
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// 重建全量索引（迁移时对存量消息跑一次；幂等，可重复调用）
  Future<void> rebuildIndex() async {
    final db = await _db.database;
    await db.execute('DELETE FROM messages_fts');
    await db.execute('DELETE FROM messages_fts_rowid');
    final rows = await db.query('messages',
        columns: ['id', 'content'], where: "content != ''");
    for (final row in rows) {
      final id = row['id'] as String;
      final content = row['content'] as String;
      final rowid =
          await db.insert('messages_fts', {'content': bigram(content)});
      await db.insert('messages_fts_rowid', {'id': id, 'rowid': rowid});
    }
  }
}
