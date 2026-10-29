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
      toolNames: _parseTools(meta['tools']),
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

  // ===== T3 Agent 分享码 =====

  /// Agent 序列化为分享码文本（YAML front matter + 正文，与资产 .md 同构）
  ///
  /// 分享码 = 一段纯文本，粘贴即导入（T3）。字段缺省策略与解析对称：
  /// temperature/effort 为 null 不输出；toolNames null 不输出（=全部）、
  /// [] 输出 `tools: none`、非空逗号连接。
  static String toShareCode(Agent agent) {
    final buf = StringBuffer('---\n');
    buf.writeln('name: ${agent.name}');
    buf.writeln('icon: ${agent.icon}');
    if (agent.description.isNotEmpty) {
      buf.writeln('description: ${agent.description}');
    }
    if (agent.temperature != null) {
      buf.writeln('temperature: ${agent.temperature}');
    }
    if (agent.effort != null) {
      buf.writeln('effort: ${agent.effort}');
    }
    if (agent.toolNames != null) {
      buf.writeln(
          'tools: ${agent.toolNames!.isEmpty ? 'none' : agent.toolNames!.join(', ')}');
    }
    buf.writeln('---');
    buf.write(agent.prompt);
    return buf.toString();
  }

  /// 从分享码文本解析为可入库的自定义 Agent（T3 导入）
  ///
  /// 复用 [parse]（front matter 规范一致）；[id] 由调用方生成。
  /// name 缺省用「导入的 Agent」；isBuiltin 恒 false。
  static Agent fromShareCode(String id, String raw) {
    final r = parse(raw);
    return Agent(
      id: id,
      name: (r.name == null || r.name!.trim().isEmpty) ? '导入的 Agent' : r.name!,
      icon: r.icon ?? '🤖',
      description: r.description ?? '',
      prompt: r.prompt,
      temperature: r.temperature,
      effort: r.effort,
      toolNames: r.toolNames,
      isBuiltin: false,
    );
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
