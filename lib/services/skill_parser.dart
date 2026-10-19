import '../models/skill.dart';

/// Skill 提示词文档解析器
///
/// 规范：Markdown + YAML front matter
/// ```md
/// ---
/// name: 技术架构师
/// icon: 🏗️
/// description: 严谨的系统设计专家
/// temperature: 0.3
/// effort: high
/// tools: calculate
/// ---
/// 你是资深软件架构师……（正文 = system prompt）
/// ```
///
/// front matter 只支持扁平 key: value（无需完整 YAML 库）；
/// 无 front matter 时整个内容视为 prompt。
///
/// tools 字段：逗号分隔的内置工具名列表；
/// 值为空或 `none` → []（无工具）；键缺省 → null（全部工具）。
class SkillParser {
  SkillParser._();

  /// 解析文档文本为 Skill 字段
  static SkillParseResult parse(String raw) {
    final text = raw.trim();
    if (!text.startsWith('---')) {
      return SkillParseResult(prompt: raw.trim());
    }

    final end = text.indexOf('\n---', 3);
    if (end < 0) {
      // 有开头无结尾：整体视为 prompt（容错）
      return SkillParseResult(prompt: text);
    }

    final frontMatter = text.substring(3, end).trim();
    final prompt = text.substring(end + 4).trim();

    final meta = <String, String>{};
    for (final line in frontMatter.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim();
      // 去掉包裹引号
      final unquoted = _stripQuotes(value);
      if (key.isNotEmpty) meta[key] = unquoted;
    }

    return SkillParseResult(
      name: meta['name'],
      icon: meta['icon'],
      description: meta['description'],
      temperature: _parseDouble(meta['temperature']),
      effort: _parseEffort(meta['effort']),
      toolNames: _parseTools(meta['tools']),
      prompt: prompt,
    );
  }

  /// 从文档解析并生成完整 Skill（用于内置资产入库）
  static Skill parseToSkill(String id, String raw, {bool isBuiltin = true}) {
    final r = parse(raw);
    return Skill(
      id: id,
      name: r.name ?? id,
      icon: r.icon ?? '🤖',
      description: r.description ?? '',
      prompt: r.prompt,
      temperature: r.temperature,
      effort: r.effort,
      toolNames: r.toolNames,
      isBuiltin: isBuiltin,
    );
  }

  static String _stripQuotes(String v) {
    if (v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) ||
            (v.startsWith("'") && v.endsWith("'")))) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  static double? _parseDouble(String? v) {
    if (v == null || v.isEmpty) return null;
    return double.tryParse(v);
  }

  static String? _parseEffort(String? v) {
    if (v == null) return null;
    return switch (v.trim().toLowerCase()) {
      'max' || 'high' || 'low' => v.trim().toLowerCase(),
      _ => null,
    };
  }

  /// tools 字段解析：缺省 → null（全部）；空/none → []（无）；逗号分隔 → 子集
  static List<String>? _parseTools(String? v) {
    if (v == null) return null;
    final trimmed = v.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.toLowerCase() == 'none') return const [];
    final names = trimmed
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return names;
  }
}

/// 解析结果
class SkillParseResult {
  SkillParseResult({
    this.name,
    this.icon,
    this.description,
    this.temperature,
    this.effort,
    this.toolNames,
    required this.prompt,
  });

  final String? name;
  final String? icon;
  final String? description;
  final double? temperature;
  final String? effort;

  /// null = 未声明（全部工具）；[] = 无工具；非空 = 子集
  final List<String>? toolNames;
  final String prompt;
}
