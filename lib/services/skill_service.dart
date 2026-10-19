import 'package:flutter/services.dart' show rootBundle;

import '../models/skill.dart';
import 'database_service.dart';
import 'skill_parser.dart';

/// Skill 服务：内置资产入库（幂等升级）+ CRUD 委托数据库
class SkillService {
  SkillService({required DatabaseService database}) : _db = database;

  final DatabaseService _db;

  /// 内置 Skill 资产清单（assets/skills/ 下的 .md 文件）
  static const builtinAssets = [
    'assets/skills/default.md',
    'assets/skills/architect.md',
    'assets/skills/copywriter.md',
    'assets/skills/tutor.md',
    'assets/skills/brainstorm.md',
    'assets/skills/translator.md',
  ];

  /// 内置 Skill 以资产为准入库（幂等，随版本演进）
  ///
  /// 每次启动用资产内容 replace 重写内置行：
  /// - v5→v6 迁移来的内置行缺 tools 声明（NULL=全部），资产声明会补上
  /// - 未来内置提示词/工具分配更新，老用户升级后自动生效
  /// 自定义 Skill 行不受影响。
  Future<void> seedBuiltinSkills() async {
    for (final asset in builtinAssets) {
      final raw = await rootBundle.loadString(asset);
      final id = asset.split('/').last.replaceAll('.md', '');
      await _db.insertSkill(SkillParser.parseToSkill(id, raw));
    }
  }

  Future<List<Skill>> getAll() => _db.getAllSkills();

  Future<Skill?> getById(String id) => _db.getSkill(id);

  /// 新建自定义 Skill
  Future<Skill> create({
    required String name,
    required String prompt,
    String icon = '🤖',
    String description = '',
    double? temperature,
    String? effort,
    List<String>? toolNames,
  }) async {
    final skill = Skill(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: name,
      icon: icon,
      description: description,
      prompt: prompt,
      temperature: temperature,
      effort: effort,
      toolNames: toolNames,
    );
    await _db.insertSkill(skill);
    return skill;
  }

  Future<void> update(Skill skill) => _db.updateSkill(skill);

  /// 内置 Skill 复制为自定义副本
  Future<Skill> duplicate(Skill builtin) async {
    final copy = builtin.copyAsCustom(
        DateTime.now().microsecondsSinceEpoch.toRadixString(36));
    await _db.insertSkill(copy);
    return copy;
  }

  /// 删除（内置 Skill 由 UI 层禁止调用此方法）
  Future<void> delete(String id) => _db.deleteSkill(id);
}
