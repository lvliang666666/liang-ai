import 'dart:io';

import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/message_attachment.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 阶段 1 验证：附件模型序列化 + DB v2→v3 迁移
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MessageAttachment 序列化', () {
    test('图片附件 round-trip（含 base64）', () {
      const a = MessageAttachment(
        type: AttachmentType.image,
        name: 'photo.jpg',
        base64Data: 'aGVsbG8=',
      );

      final list = MessageAttachment.decodeList(
          MessageAttachment.encodeList([a]));

      expect(list, hasLength(1));
      expect(list.first.isImage, isTrue);
      expect(list.first.name, 'photo.jpg');
      expect(list.first.base64Data, 'aGVsbG8=');
      expect(list.first.extractedText, isNull);
    });

    test('文件附件 round-trip（含提取文本）', () {
      const a = MessageAttachment(
        type: AttachmentType.file,
        name: '说明.md',
        extractedText: '# 标题\n正文内容',
      );

      final list = MessageAttachment.decodeList(
          MessageAttachment.encodeList([a]));

      expect(list, hasLength(1));
      expect(list.first.isFile, isTrue);
      expect(list.first.name, '说明.md');
      expect(list.first.extractedText, '# 标题\n正文内容');
      expect(list.first.base64Data, isNull);
    });

    test('混合列表 round-trip 保持顺序', () {
      const list0 = [
        MessageAttachment(
            type: AttachmentType.image, name: 'a.png', base64Data: 'x'),
        MessageAttachment(
            type: AttachmentType.file, name: 'b.txt', extractedText: 'y'),
        MessageAttachment(
            type: AttachmentType.image, name: 'c.jpg', base64Data: 'z'),
      ];

      final list = MessageAttachment.decodeList(
          MessageAttachment.encodeList(list0));

      expect(list.map((e) => e.name).toList(), ['a.png', 'b.txt', 'c.jpg']);
      expect(list.map((e) => e.type).toList(), [
        AttachmentType.image,
        AttachmentType.file,
        AttachmentType.image,
      ]);
    });

    test('空列表与 null 输入', () {
      expect(MessageAttachment.decodeList(null), isEmpty);
      expect(MessageAttachment.decodeList(''), isEmpty);
      expect(
        MessageAttachment.decodeList(
            MessageAttachment.encodeList(const [])),
        isEmpty,
      );
    });

    test('脏数据容错：坏 JSON 返回空列表', () {
      expect(MessageAttachment.decodeList('not-json{{'), isEmpty);
      expect(MessageAttachment.decodeList('[{broken'), isEmpty);
    });
  });

  group('ChatMessage 附件字段', () {
    test('默认无附件', () {
      final m = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '你好',
        createdAt: 1000,
      );
      expect(m.attachments, isEmpty);
      expect(m.hasAttachments, isFalse);
    });

    test('toMap/fromMap round-trip 带附件', () {
      final m = ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '看这张图',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.image, name: 'x.png', base64Data: 'QQ=='),
          MessageAttachment(
              type: AttachmentType.file, name: 'a.md', extractedText: '内容'),
        ],
        createdAt: 1000,
      );

      final restored = ChatMessage.fromMap(m.toMap());

      expect(restored.hasAttachments, isTrue);
      expect(restored.attachments, hasLength(2));
      expect(restored.attachments.first.base64Data, 'QQ==');
      expect(restored.attachments.last.extractedText, '内容');
    });
  });

  group('DB v2→v3 迁移', () {
    late Directory tmpDir;
    late String dbPath;

    setUp(() async {
      tmpDir =
          await Directory.systemTemp.createTemp('attachment_migration_test');
      dbPath = '${tmpDir.path}${Platform.pathSeparator}migrate.db';
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    /// 建一个 v2 结构的库（无 attachments 列），塞入旧数据
    Future<Database> createV2Db() async {
      final db = await databaseFactory.openDatabase(dbPath,
          options: OpenDatabaseOptions(version: 2, onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            effort TEXT NOT NULL DEFAULT 'max',
            agent_id TEXT
          )
        ''');
        await d.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            reasoning TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL
          )
        ''');
        await d.execute(
          'CREATE INDEX idx_messages_session ON messages(session_id, created_at)',
        );
        await d.execute('''
          CREATE TABLE agents (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            icon TEXT NOT NULL DEFAULT '🤖',
            description TEXT NOT NULL DEFAULT '',
            prompt TEXT NOT NULL DEFAULT '',
            temperature REAL,
            effort TEXT,
            is_builtin INTEGER NOT NULL DEFAULT 0
          )
        ''');
      }));
      return db;
    }

    test('v2 库打开自动升 v3，旧消息不受影响且新消息可带附件', () async {
      // 1. 建 v2 库并写入旧数据
      final v2db = await createV2Db();
      await v2db.insert('sessions', {
        'id': 's1',
        'title': '旧会话',
        'created_at': 1000,
        'updated_at': 1000,
        'effort': 'max',
      });
      await v2db.insert('messages', {
        'id': 'm1',
        'session_id': 's1',
        'role': 'user',
        'content': '旧消息',
        'reasoning': '',
        'created_at': 1000,
      });
      await v2db.close();

      // 2. 用 DatabaseService 重新打开（触发生产 onUpgrade 本尊 v2→v5 迁移链）
      final reopened = await databaseFactory.openDatabase(dbPath,
          options: OpenDatabaseOptions(
            version: 5,
            onUpgrade: DatabaseService.onUpgrade,
          ));
      final svc = DatabaseService.instance;
      await svc.initForTest(reopened);

      // 3. 旧消息读出不受影响（attachments 默认空）
      final old = await svc.getMessages('s1');
      expect(old, hasLength(1));
      expect(old.first.content, '旧消息');
      expect(old.first.attachments, isEmpty);

      // 4. 新消息可带附件正常写入读出
      await svc.insertMessage(ChatMessage(
        id: 'm2',
        sessionId: 's1',
        role: 'user',
        content: '新消息带图',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.image, name: 'p.jpg', base64Data: 'QQ=='),
        ],
        createdAt: 2000,
      ));

      final all = await svc.getMessages('s1');
      expect(all, hasLength(2));
      expect(all.last.attachments, hasLength(1));
      expect(all.last.attachments.first.base64Data, 'QQ==');

      await svc.close();
    });

    test('全新 v3 库直接建表含 attachments 列', () async {
      // 生产 onCreate 本尊建当前版本库（attachments 列必然在内）
      final db = await databaseFactory.openDatabase(dbPath,
          options: OpenDatabaseOptions(
            version: DatabaseService.dbVersion,
            onCreate: DatabaseService.onCreate,
          ));
      final svc = DatabaseService.instance;
      await svc.initForTest(db);

      await svc.insertMessage(ChatMessage(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '直接带附件',
        attachments: const [
          MessageAttachment(
              type: AttachmentType.file, name: 'f.txt', extractedText: 'T'),
        ],
        createdAt: 1000,
      ));

      final msgs = await svc.getMessages('s1');
      expect(msgs, hasLength(1));
      expect(msgs.first.attachments.first.extractedText, 'T');

      await svc.close();
    });
  });
}
