/// 共享测试数据库 fixture（E2 schema 测试根治）
///
/// 测试库直接跑生产 [DatabaseService.onCreate] / [DatabaseService.onUpgrade]，
/// schema 与生产同源——生产改表测试立刻见，杜绝手写 CREATE TABLE 漂移
/// （此前测试 schema 停在 v6 缺 memories 表，就是漂移的实证）。
///
/// 用法（替代各测试文件里手写的 OpenDatabaseOptions + CREATE TABLE）：
/// ```dart
/// setUp(() async {
///   db = DatabaseService.instance;
///   final inMemory = await openTestDb();
///   await db.initForTest(inMemory);
/// });
/// tearDown(() => db.close());
/// ```
///
/// 迁移测试（模拟老版本库再升级）用 [openTestDbFromVersion]：
/// - version == DatabaseService.dbVersion：等价 openTestDb()
/// - version < DatabaseService.dbVersion：建 v1 基线 schema 后逐版本
///   迁移上来（跑真实 onUpgrade 链，可验证迁移后 schema 与新装一致）
/// - 需要手写「历史版本 schema」的迁移测试（被测对象本身是迁移逻辑），
///   仍手写老 schema，但升级步骤用 DatabaseService.onUpgrade 本尊。
library;

import 'package:ai_chat_app/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 打开与生产同 schema 的内存测试库（当前版本，跑生产 onCreate）
Future<Database> openTestDb() =>
    openTestDbFromVersion(DatabaseService.dbVersion);

/// 打开内存测试库并跑生产迁移链到 [version]
Future<Database> openTestDbFromVersion(int version) async {
  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: DatabaseService.onCreate,
      onUpgrade: DatabaseService.onUpgrade,
    ),
  );
}
