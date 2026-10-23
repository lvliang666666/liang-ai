import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/memory.dart';
import '../models/provider_profile.dart';
import '../models/skill.dart';
import 'database_service.dart';
import 'settings_service.dart';

/// E1 备份/导出：全量数据 → 单个 JSON 文件（分享出去），导入时整库重灌
///
/// 备份内容：sessions + messages + skills + memories + providers + settings。
/// **API Key 永不进备份**（E1 硬性要求）：providers 导出时 apiKey 强制置空，
/// 导入时同样置空——备份文件泄露不泄露凭据。
class BackupService {
  BackupService({required DatabaseService database, required this.settings})
      : _db = database;

  final DatabaseService _db;
  final SettingsService settings;

  /// 备份文件 schema 版本（导入时校验，向后兼容预留）
  static const schemaVersion = 1;

  /// 组装备份 JSON（不落盘；测试直接断言结构）
  Future<Map<String, Object?>> buildBackup() async {
    final sessions = await _db.getAllSessions();
    final messages = <Map<String, Object?>>[];
    for (final s in sessions) {
      for (final m in await _db.getMessages(s.id)) {
        messages.add(m.toMap());
      }
    }
    final skills = await _db.getAllSkills();
    final memories = await _db.getAllMemories();
    final providers = await _db.getAllProviders();

    return {
      'schema': schemaVersion,
      'app_version': '2.3.8',
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'data': {
        'sessions': [for (final s in sessions) s.toMap()],
        'messages': messages,
        'skills': [for (final s in skills) s.toMap()],
        'memories': [for (final m in memories) m.toMap()],
        // E1 硬性要求：apiKey 强制置空，凭据绝不进备份文件。
        // 行格式用 DatabaseService.providerRow（capabilities/dialect 存
        // JSON 串，与 DB 列格式一致；toMap 的嵌套 Map 无法直接入库）
        'providers': [
          for (final p in providers)
            DatabaseService.providerRow(p, redactKey: true),
        ],
        'settings': {
          'theme_id': settings.themeIdRaw,
          'default_effort': settings.defaultEffortValue,
          'temperature': settings.temperature,
          'swipe_actions': settings.swipeActions,
        },
      },
    };
  }

  /// 备份并调起系统分享面板（复用 FileExportService 的 share 模式）
  Future<ShareResult?> shareBackup() async {
    final backup = await buildBackup();
    final json = const JsonEncoder.withIndent('  ').convert(backup);

    final dir = await getTemporaryDirectory();
    final ts = DateTime.now();
    final name = 'liang_ai_backup_${ts.year}${_pad(ts.month)}${_pad(ts.day)}'
        '_${_pad(ts.hour)}${_pad(ts.minute)}';
    final path = '${dir.path}/$name.json';
    await File(path).writeAsString(json, flush: true);

    return SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: 'application/json')],
      fileNameOverrides: ['$name.json'],
    ));
  }

  /// 从备份文件恢复（整库替换）
  ///
  /// 校验 schema ≤ [schemaVersion] 与必备 section；事务内清空 + 重灌。
  /// providers 导入时 apiKey 强制置空（备份文件里的 Key 本来就是空的，
  /// 双保险防手改文件注入）。返回统计（各 section 条数）。
  Future<BackupStats> restore(String jsonText) async {
    final Object? decoded;
    try {
      decoded = const JsonDecoder().convert(jsonText);
    } catch (_) {
      throw const BackupFormatException('文件不是合法 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupFormatException('备份文件结构不正确');
    }

    final schema = decoded['schema'];
    if (schema is! int || schema > schemaVersion) {
      throw BackupFormatException(
          '备份 schema 版本（$schema）高于当前支持（$schemaVersion），请升级 App');
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw const BackupFormatException('缺少 data 段，文件可能已损坏');
    }
    for (final key in ['sessions', 'messages']) {
      if (data[key] is! List) {
        throw BackupFormatException('缺少 $key 段，文件可能已损坏');
      }
    }

    final sessions =
        (data['sessions'] as List).whereType<Map<String, dynamic>>().toList();
    final messages =
        (data['messages'] as List).whereType<Map<String, dynamic>>().toList();
    final skills = (data['skills'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final memories = (data['memories'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final providers = (data['providers'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    final db = await _db.database;
    await db.transaction((txn) async {
      // 清空（顺序：先子表后父表）
      await txn.delete('messages');
      await txn.delete('sessions');
      await txn.delete('skills');
      await txn.delete('memories');
      await txn.delete('providers');
      // 重灌
      for (final m in sessions) {
        await txn.insert('sessions', ChatSession.fromMap(m).toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final m in messages) {
        await txn.insert('messages', ChatMessage.fromMap(m).toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final s in skills) {
        await txn.insert('skills', Skill.fromMap(s).toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final m in memories) {
        await txn.insert('memories', Memory.fromMap(m).toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final p in providers) {
        // E1 双保险：导入的 provider Key 强制置空。
        // 备份文件存的是 DB 行格式（JSON 串列），直接原样重灌
        await txn.insert(
            'providers',
            DatabaseService.providerRow(
                ProviderProfile.fromMap(p), redactKey: true),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });

    return BackupStats(
      sessions: sessions.length,
      messages: messages.length,
      skills: skills.length,
      memories: memories.length,
      providers: providers.length,
    );
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

/// 恢复统计
class BackupStats {
  const BackupStats({
    required this.sessions,
    required this.messages,
    required this.skills,
    required this.memories,
    required this.providers,
  });

  final int sessions;
  final int messages;
  final int skills;
  final int memories;
  final int providers;
}

/// 备份文件格式错误（导入校验失败）
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}
