import '../models/agent.dart';

/// Agent 提示词文档解析器
///
/// 规范：Markdown + YAML front matter
/// ```md
/// ---
/// name: 技术架构师
/// icon: 🏗️
/// description: 严谨的系统设计专家
/// temperature: 0.3
/// effort: high
/// ---
/// 你是资深软件架构师……（正文 = system prompt）
/// ```
///
/// front matter 只支持扁平 key: value（无需完整 YAML 库）；
/// 无 front matter 时整个内容视为 prompt。
class AgentParser {
  AgentParser._();

  /// 解析文档文本为 Agent 字段
  static AgentParseResult parse(String raw) {
    final text = raw.trim();
    if (!text.startsWith('---')) {
      return AgentParseResult(prompt: raw.trim());
    }

    final end = text.indexOf('\n---', 3);
    if (end < 0) {
      // 有开头无结尾：整体视为 prompt（容错）
      return AgentParseResult(prompt: text);
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

    return AgentParseResult(
      name: meta['name'],
      icon: meta['icon'],
      description: meta['description'],
      temperature: _parseDouble(meta['temperature']),
      effort: _parseEffort(meta['effort']),
      prompt: prompt,
    );
  }

  /// 从文档解析并生成完整 Agent（用于内置资产入库）
  static Agent parseToAgent(String id, String raw, {bool isBuiltin = true}) {
    final r = parse(raw);
    return Agent(
      id: id,
      name: r.name ?? id,
      icon: r.icon ?? '🤖',
      description: r.description ?? '',
      prompt: r.prompt,
      temperature: r.temperature,
      effort: r.effort,
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
}

/// 解析结果
class AgentParseResult {
  AgentParseResult({
    this.name,
    this.icon,
    this.description,
    this.temperature,
    this.effort,
    required this.prompt,
  });

  final String? name;
  final String? icon;
  final String? description;
  final double? temperature;
  final String? effort;
  final String prompt;
}
