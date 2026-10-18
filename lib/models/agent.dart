/// Agent 人格模型
class Agent {
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

  /// 内置 Agent 不可删除，只可复制后修改
  final bool isBuiltin;

  Agent({
    required this.id,
    required this.name,
    this.icon = '🤖',
    this.description = '',
    required this.prompt,
    this.temperature,
    this.effort,
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
        'is_builtin': isBuiltin ? 1 : 0,
      };

  factory Agent.fromMap(Map<String, dynamic> map) => Agent(
        id: map['id'] as String,
        name: map['name'] as String,
        icon: (map['icon'] as String?) ?? '🤖',
        description: (map['description'] as String?) ?? '',
        prompt: (map['prompt'] as String?) ?? '',
        temperature: (map['temperature'] as num?)?.toDouble(),
        effort: map['effort'] as String?,
        isBuiltin: (map['is_builtin'] as int?) == 1,
      );

  /// 复制为可编辑的自定义 Agent（内置 Agent "另存为" 用）
  Agent copyAsCustom(String newId) => Agent(
        id: newId,
        name: '$name 副本',
        icon: icon,
        description: description,
        prompt: prompt,
        temperature: temperature,
        effort: effort,
        isBuiltin: false,
      );
}
