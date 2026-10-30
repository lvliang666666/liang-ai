import '../models/agent.dart';

/// F10 Prompt 工程产品化：Skill 变量插槽
///
/// Skill 的 system prompt 里可写 `{{变量名}}` 占位符，发送前替换为实际值：
/// - **内置变量**（自动填充，无需用户输入）：`{{date}}` 今天日期、
///   `{{weekday}}` 星期几、`{{time}}` 当前时间
/// - **自定义变量**（选 Skill 时弹表单填写）：prompt 里出现即收集，
///   值由用户填入（会话内记住，切会话重填）
/// - **人格预设**：front matter `personas:` 声明（`名称=值` 逗号分隔），
///   预设值填充到 `{{persona}}` 变量——预设完全建立在变量系统上，
///   零特殊路径（选预设 = 选了 persona 变量的值）
///
/// 未填写的自定义变量替换为空串（prompt 里残留 `{{x}}` 会误导模型）；
/// 未知形式（`{{ }}`/嵌套）不匹配正则，原样保留。
class SkillVariables {
  SkillVariables._();

  /// 变量占位符：`{{name}}`（name 不含花括号与空白）
  static final RegExp _pattern = RegExp(r'\{\{([^\{\}\s]+)\}\}');

  /// 内置变量名 → 值生成器（发送时刻求值，非构造时刻）
  static const builtinNames = ['date', 'weekday', 'time'];

  /// 是否内置变量（内置变量不出现在表单里）
  static bool isBuiltin(String name) => builtinNames.contains(name);

  /// 内置变量的当前值
  static String builtinValue(String name, DateTime now) => switch (name) {
        'date' =>
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
        'weekday' => const [
          '周一', '周二', '周三', '周四', '周五', '周六', '周日',
        ][now.weekday - 1],
        'time' =>
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
        _ => '',
      };

  /// 从 prompt 提取全部自定义变量名（去重保序；内置变量排除）
  ///
  /// 表单渲染与「是否需要填写」判断共用。
  static List<String> extractCustom(String prompt) {
    final seen = <String>{};
    final out = <String>[];
    for (final m in _pattern.allMatches(prompt)) {
      final name = m.group(1)!;
      if (isBuiltin(name)) continue;
      if (seen.add(name)) out.add(name);
    }
    return out;
  }

  /// 变量替换：内置变量按 [now] 求值，自定义变量查 [values]（缺省空串）
  ///
  /// 单遍 replaceAllMapped（先收集后替换，避免替换值里再含 `{{}}`
  /// 被二次展开——用户填的内容按字面量对待）。
  static String render(
    String prompt, {
    Map<String, String> values = const {},
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return prompt.replaceAllMapped(_pattern, (m) {
      final name = m.group(1)!;
      if (isBuiltin(name)) return builtinValue(name, at);
      return values[name] ?? '';
    });
  }

  /// 解析 front matter `personas:` 字段值 → 有序预设清单
  ///
  /// 格式：`正式=正式商务,轻松=轻松口语`（名称=值，逗号分隔）。
  /// 坏段（无 = /空名/空值）跳过；全部坏段返回空清单。
  /// 名称重复时后者覆盖前者（保序）。
  static List<SkillPersona> parsePersonas(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final out = <String, String>{};
    for (final seg in raw.split(',')) {
      final idx = seg.indexOf('=');
      if (idx <= 0) continue;
      final name = seg.substring(0, idx).trim();
      final value = seg.substring(idx + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      out[name] = value;
    }
    return [for (final e in out.entries) SkillPersona(e.key, e.value)];
  }
}

/// 人格预设（F10）：`{{persona}}` 变量的候选值
class SkillPersona {
  const SkillPersona(this.name, this.value);

  /// 展示名（如「正式」）
  final String name;

  /// 填入 `{{persona}}` 的实际值（如「正式商务」）
  final String value;
}

/// Agent 扩展：F10 变量/预设的便捷读取
extension AgentSkillVariables on Agent {
  /// prompt 中的自定义变量清单（空 = 无需填写表单）
  List<String> get customVariables => SkillVariables.extractCustom(prompt);
}
