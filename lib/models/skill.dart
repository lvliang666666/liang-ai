import 'dart:convert';

/// Skill 模型：prompt + 工具子集 + 参数 的组合包（类 GPTs）
///
/// 一个 Skill 声明自己的系统提示词、允许调用的内置工具、温度/推理档位预设。
/// v1.7.0 起完全取代旧 Agent 体系（一套系统）。
class Skill {
  final String id;

  /// 显示名（如：技术架构师）
  String name;

  /// 图标（emoji，如 🏗️）
  String icon;

  /// 一句话描述（列表/选择器中展示）
  String description;

  /// 系统提示词本体（front matter 之后的正文）
  String prompt;

  /// 可选：覆盖全局温度（null = 用全局设置）
  double? temperature;

  /// 可选：覆盖默认推理档位 max/high/low（null = 用会话设置）
  String? effort;

  /// 允许调用的内置工具名列表
  ///
  /// - null = 全部内置工具（默认；迁移来的老数据、未声明 tools 的资产）
  /// - [] = 无工具（纯提示词 Skill）
  /// - 非空 = 指定子集
  List<String>? toolNames;

  /// 内置 Skill 不可删除，只可复制后修改
  final bool isBuiltin;

  Skill({
    required this.id,
    required this.name,
    this.icon = '🤖',
    this.description = '',
    required this.prompt,
    this.temperature,
    this.effort,
    this.toolNames,
    this.isBuiltin = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'icon': icon,
        'description': description,
        'prompt': prompt,
        'temperature': temperature,
        'effort': effort,
        'tools': toolNames == null ? null : jsonEncode(toolNames),
        'is_builtin': isBuiltin ? 1 : 0,
      };

  factory Skill.fromMap(Map<String, dynamic> map) => Skill(
        id: map['id'] as String,
        name: map['name'] as String,
        icon: (map['icon'] as String?) ?? '🤖',
        description: (map['description'] as String?) ?? '',
        prompt: (map['prompt'] as String?) ?? '',
        temperature: (map['temperature'] as num?)?.toDouble(),
        effort: map['effort'] as String?,
        toolNames: _parseToolNames(map['tools']),
        isBuiltin: (map['is_builtin'] as int?) == 1,
      );

  /// tools 列容错解析：NULL → null（全部）；JSON 数组 → 列表；坏数据 → null
  static List<String>? _parseToolNames(Object? raw) {
    if (raw == null) return null;
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return null;
  }

  /// 复制为可编辑的自定义 Skill（内置 Skill "另存为" 用）
  Skill copyAsCustom(String newId) => Skill(
        id: newId,
        name: '$name 副本',
        icon: icon,
        description: description,
        prompt: prompt,
        temperature: temperature,
        effort: effort,
        toolNames: toolNames == null ? null : List.of(toolNames!),
        isBuiltin: false,
      );
}
