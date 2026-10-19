/// 供应商能力开关
class ProviderCapabilities {
  const ProviderCapabilities({
    this.vision = false,
    this.reasoning = false,
    this.toolCalls = false,
  });

  /// 支持图片输入（多模态消息数组）
  final bool vision;

  /// 支持思考流（SSE 中有 reasoning 增量）
  final bool reasoning;

  /// 支持 OpenAI function calling（tools 参数）
  final bool toolCalls;

  Map<String, dynamic> toMap() => {
        'vision': vision ? 1 : 0,
        'reasoning': reasoning ? 1 : 0,
        'tool_calls': toolCalls ? 1 : 0,
      };

  factory ProviderCapabilities.fromMap(Map<String, dynamic> map) =>
      ProviderCapabilities(
        vision: (map['vision'] as int?) == 1,
        reasoning: (map['reasoning'] as int?) == 1,
        toolCalls: (map['tool_calls'] as int?) == 1,
      );

  ProviderCapabilities copyWith({
    bool? vision,
    bool? reasoning,
    bool? toolCalls,
  }) =>
      ProviderCapabilities(
        vision: vision ?? this.vision,
        reasoning: reasoning ?? this.reasoning,
        toolCalls: toolCalls ?? this.toolCalls,
      );

  @override
  bool operator ==(Object other) =>
      other is ProviderCapabilities &&
      other.vision == vision &&
      other.reasoning == reasoning &&
      other.toolCalls == toolCalls;

  @override
  int get hashCode => Object.hash(vision, reasoning, toolCalls);
}

/// 供应商方言：请求/响应中因实现而异的部分
class ProviderDialect {
  const ProviderDialect({
    this.reasoningField,
    this.effortParam,
  });

  /// 思考流字段名（SSE delta 中的 key，如 vLLM 的 reasoning /
  /// DeepSeek 的 reasoning_content）；null = 不解析思考流
  final String? reasoningField;

  /// 推理档位参数（如 glm 的 chat_template_kwargs.reasoning_effort）；
  /// null = 不发送推理档位参数
  final String? effortParam;

  Map<String, dynamic> toMap() => {
        'reasoning_field': reasoningField,
        'effort_param': effortParam,
      };

  factory ProviderDialect.fromMap(Map<String, dynamic> map) =>
      ProviderDialect(
        reasoningField: map['reasoning_field'] as String?,
        effortParam: map['effort_param'] as String?,
      );

  ProviderDialect copyWith({
    String? reasoningField,
    String? effortParam,
  }) =>
      ProviderDialect(
        reasoningField: reasoningField ?? this.reasoningField,
        effortParam: effortParam ?? this.effortParam,
      );

  @override
  bool operator ==(Object other) =>
      other is ProviderDialect &&
      other.reasoningField == reasoningField &&
      other.effortParam == effortParam;

  @override
  int get hashCode => Object.hash(reasoningField, effortParam);
}

/// 供应商配置（Provider Profile）
///
/// 一个 profile = 一组可用的 API 端点 + 凭据 + 能力声明 + 方言声明。
/// 会话通过 providerId 绑定 profile，实现会话级模型切换。
class ProviderProfile {
  ProviderProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    this.defaultModel = '',
    this.capabilities = const ProviderCapabilities(),
    this.dialect = const ProviderDialect(),
    this.isBuiltin = false,
  });

  final String id;

  /// 显示名（如：公司 GLM / DeepSeek / 本地 Ollama）
  String name;

  /// API 根地址（OpenAI 兼容，如 https://api.deepseek.com/v1）
  String baseUrl;

  /// API Key（凭据不入代码库，用户在设置页填入）
  String apiKey;

  /// 该供应商下默认使用的模型名
  String defaultModel;

  /// 能力开关（UI 显隐 + 请求组装依据）
  ProviderCapabilities capabilities;

  /// 方言声明（请求参数与响应解析依据）
  ProviderDialect dialect;

  /// 内置 profile 不可删除，只可编辑凭据
  final bool isBuiltin;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'base_url': baseUrl,
        'api_key': apiKey,
        'default_model': defaultModel,
        'capabilities': capabilities.toMap(),
        'dialect': dialect.toMap(),
        'is_builtin': isBuiltin ? 1 : 0,
      };

  factory ProviderProfile.fromMap(Map<String, dynamic> map) =>
      ProviderProfile(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? '',
        baseUrl: (map['base_url'] as String?) ?? '',
        apiKey: (map['api_key'] as String?) ?? '',
        defaultModel: (map['default_model'] as String?) ?? '',
        capabilities: map['capabilities'] is Map
            ? ProviderCapabilities.fromMap(
                (map['capabilities'] as Map).cast<String, dynamic>())
            : const ProviderCapabilities(),
        dialect: map['dialect'] is Map
            ? ProviderDialect.fromMap(
                (map['dialect'] as Map).cast<String, dynamic>())
            : const ProviderDialect(),
        isBuiltin: (map['is_builtin'] as int?) == 1,
      );

  /// 复制并修改（不可变更新用）
  ProviderProfile copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? defaultModel,
    ProviderCapabilities? capabilities,
    ProviderDialect? dialect,
  }) =>
      ProviderProfile(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        defaultModel: defaultModel ?? this.defaultModel,
        capabilities: capabilities ?? this.capabilities,
        dialect: dialect ?? this.dialect,
        isBuiltin: isBuiltin,
      );

  /// 内置默认：公司 GLM API（公网 focusaim 域名）
  ///
  /// Key 不预填（凭据不入代码库）；方言为 glm 的
  /// chat_template_kwargs.reasoning_effort + vLLM 的 reasoning 字段。
  static ProviderProfile builtinCompany() => ProviderProfile(
        id: builtinCompanyId,
        name: '公司 GLM',
        baseUrl: 'https://aep.focusaim.com/focus_coding_local/v1',
        apiKey: '',
        defaultModel: 'glm5.1',
        capabilities: const ProviderCapabilities(
          vision: true,
          reasoning: true,
        ),
        dialect: const ProviderDialect(
          reasoningField: 'reasoning',
          effortParam: 'reasoning_effort',
        ),
        isBuiltin: true,
      );

  /// 内置公司 profile 的固定 id
  static const builtinCompanyId = 'company-glm';
}
