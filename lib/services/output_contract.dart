/// F10 输出契约：Skill 声明输出格式 → 模型按格式输出 → 专属卡片渲染
///
/// 三段管线（全部纯 Dart 可单测）：
/// 1. **声明**：front matter `output: title=标题, items=条目, total=合计`
///    → [OutputContract]（字段名=显示名清单）
/// 2. **注入**：[instruction] 生成格式指令追加进 system prompt——要求模型
///    回答末尾附 ```yaml 围栏块（每行 `字段名: 值`），围栏前可自由分析
/// 3. **解析**：[extract] 从回复提取 YAML 块解析为字段 map → UI 渲染
///    专属卡片；任何一步失败返回 null → 优雅降级回 markdown 渲染
///    （卡片是增强不是门槛，绝不丢内容）
///
/// 设计取舍：
/// - **YAML 而非 JSON**：行式 `key: value` 无引号/逗号/嵌套括号，模型输出
///   更稳定、解析更简单、用户肉眼可读
/// - **只保留契约声明的字段**：模型多输出的键不进卡片（防噪音）
/// - **仅内存态**：契约随 prompt 资产演进（front matter output 字段），
///   DB 不加列，同 personas 策略
library;

/// 输出契约的单个字段声明
class OutputField {
  const OutputField(this.name, this.label);

  /// YAML 键（模型输出用，如 title）
  final String name;

  /// 中文显示名（卡片行标签，如 标题）
  final String label;
}

/// 输出契约：字段清单（空清单 = 未声明）
class OutputContract {
  const OutputContract({required this.fields});

  /// 契约字段（至少一个；解析时保证）
  final List<OutputField> fields;

  /// 是否声明了契约
  bool get hasFields => fields.isNotEmpty;

  /// 按字段名查显示名（未声明字段返回 null）
  String? labelOf(String name) {
    for (final f in fields) {
      if (f.name == name) return f.label;
    }
    return null;
  }

  /// 解析 front matter output 字段：`title=标题, items=条目`
  ///
  /// - null/空/无有效段 → null（未声明）
  /// - 无 `=显示名` 的段：显示名 = 字段名本身
  /// - 坏段（无字段名）跳过；按字段名去重保序
  static OutputContract? parse(String? raw) {
    if (raw == null) return null;
    final segments = raw.split(',');
    final fields = <OutputField>[];
    final seen = <String>{};
    for (final seg in segments) {
      final s = seg.trim();
      if (s.isEmpty) continue;
      final eq = s.indexOf('=');
      final name = (eq < 0 ? s : s.substring(0, eq)).trim();
      if (name.isEmpty || !seen.add(name)) continue;
      final label =
          eq < 0 ? name : s.substring(eq + 1).trim();
      fields.add(OutputField(name, label.isEmpty ? name : label));
    }
    return fields.isEmpty ? null : OutputContract(fields: fields);
  }

  /// 格式指令（注入 system prompt 的【输出格式】块）
  String get instruction {
    final lines = [
      for (final f in fields) '${f.name}: （${f.label}）',
    ].join('\n');
    return '【输出格式】回答的末尾必须附一个 yaml 代码块，按以下字段'
        '给出结构化结果：\n'
        '```yaml\n$lines\n```\n'
        '要求：代码块前可以正常分析说明；代码块内每行是「字段名: 值」，'
        '值写不下就换行缩进两格续写；某字段无法确定时值写「未确定」。';
  }

  /// 从回复提取契约字段 map；失败返回 null（调用方降级 markdown）
  ///
  /// 提取顺序：
  /// 1. ```yaml 围栏块（规范路径）
  /// 2. ``` 围栏块（模型忘写语言标注的容错）
  /// 3. 都没有 → null
  ///
  /// 解析容错：`key: value` 行（冒号后可有可无空格）；续行（缩进开头）
  /// 并进上一字段值；只保留契约声明的字段；值空视为未给出（不进 map）。
  static Map<String, String>? extract(String reply, OutputContract contract) {
    final yaml = _extractYamlBlock(reply);
    if (yaml == null) return null;
    return parseYamlFields(yaml, contract);
  }

  /// 提取回复中最后一个 yaml/裸围栏代码块内容
  static String? _extractYamlBlock(String reply) {
    // ```yaml 围栏优先（大小写不敏感）
    final yamlFence = RegExp(r'```yaml\s*\n([\s\S]*?)```', caseSensitive: false)
        .allMatches(reply)
        .toList();
    if (yamlFence.isNotEmpty) return yamlFence.last.group(1)!.trim();
    // 裸 ``` 围栏容错
    final bare = RegExp(r'```\s*\n([\s\S]*?)```').allMatches(reply).toList();
    if (bare.isNotEmpty) return bare.last.group(1)!.trim();
    return null;
  }

  /// 解析 YAML 行式字段（key: value + 缩进续行），只保留契约声明的字段
  static Map<String, String>? parseYamlFields(
      String yaml, OutputContract contract) {
    final result = <String, String>{};
    String? currentKey;
    final buffer = <String>[];
    // 逐行收集：key 行结算上一字段，续行（缩进/空行后非 key 行）并入
    void flush() {
      if (currentKey == null) return;
      final value = buffer.join('\n').trim();
      if (value.isNotEmpty) result[currentKey!] = value;
      currentKey = null;
      buffer.clear();
    }

    for (final rawLine in yaml.split('\n')) {
      final line = rawLine.trimRight();
      final m = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$').firstMatch(line);
      if (m != null) {
        // 任何 key 行（含未声明字段）都结算上一字段——未声明字段的行
        // 不能并进上一字段值（防噪音字段污染契约值）
        flush();
        if (contract.labelOf(m.group(1)!) != null) {
          currentKey = m.group(1)!;
          final v = m.group(2)!.trim();
          if (v.isNotEmpty) buffer.add(v);
        }
      } else if (currentKey != null && line.trim().isNotEmpty) {
        // 续行：缩进两格的换行值（instruction 里约定的写法）
        buffer.add(line.trim());
      }
    }
    flush();
    // 一个契约字段都没解析出来 = 输出不符合契约 → 降级
    return result.isEmpty ? null : result;
  }
}
