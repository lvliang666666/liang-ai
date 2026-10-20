import 'package:flutter/foundation.dart';

import '../models/skill.dart';
import '../services/skill_service.dart';

/// Skill 列表状态：加载 + CRUD 同步
class SkillProvider extends ChangeNotifier {
  SkillProvider({required SkillService service}) : _service = service;

  final SkillService _service;
  List<Skill> _skills = [];
  bool _loaded = false;

  List<Skill> get skills => _skills;
  bool get loaded => _loaded;

  /// 内置 Skill（列表前段）
  List<Skill> get builtins =>
      _skills.where((s) => s.isBuiltin).toList();

  /// 自定义 Skill
  List<Skill> get customs =>
      _skills.where((s) => !s.isBuiltin).toList();

  Future<void> load() async {
    await _service.seedBuiltinSkills(); // 幂等：以资产为准重写内置行
    _skills = await _service.getAll();
    _loaded = true;
    notifyListeners();
  }

  Skill? byId(String? id) {
    if (id == null) return null;
    for (final s in _skills) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<Skill> create({
    required String name,
    required String prompt,
    String icon = '🤖',
    String description = '',
    double? temperature,
    String? effort,
    List<String>? toolNames,
  }) async {
    final skill = await _service.create(
      name: name,
      prompt: prompt,
      icon: icon,
      description: description,
      temperature: temperature,
      effort: effort,
      toolNames: toolNames,
    );
    _skills = [..._skills, skill];
    notifyListeners();
    return skill;
  }

  Future<void> update(Skill skill) async {
    await _service.update(skill);
    _skills = [
      for (final s in _skills) if (s.id == skill.id) skill else s
    ];
    notifyListeners();
  }

  /// 内置 Skill 复制为自定义副本
  Future<Skill> duplicate(Skill builtin) async {
    final copy = await _service.duplicate(builtin);
    _skills = [..._skills, copy];
    notifyListeners();
    return copy;
  }

  Future<void> delete(String id) async {
    await _service.delete(id);
    _skills = _skills.where((s) => s.id != id).toList();
    notifyListeners();
  }
}
