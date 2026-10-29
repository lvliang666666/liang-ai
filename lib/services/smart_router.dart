/// F4 智能路由（规则版）：按消息内容自动选推理档位
///
/// 思考强制开启的模型不适合让模型自评复杂度（自评消耗一轮思考且
/// 不可靠），规则版是正解。规则按优先级短路：
///
/// 1. **max 触发词**：深入/推理/证明/详细/逐步/分析/为什么/原理/对比/
///    代码/实现/调试/报错/优化/重构/数学/计算/逻辑 —— 需要深度思考
/// 2. **low 触发**：短消息（≤12 字）且无工具意图（不以「/」开头、
///    无明确工具动词）—— 寒暄/翻译短句/简单事实问答不值得 max
/// 3. **默认 high**：其余情况（均衡档）
///
/// 纯函数零依赖，可单测；设置页开关控制是否启用（默认关——
/// 用户手动选档的行为完全不变）。
class SmartRouter {
  SmartRouter._();

  /// max 档触发词（命中任一即深度推理）
  static const maxKeywords = [
    '深入', '推理', '证明', '详细', '逐步', '分析', '为什么', '原理',
    '对比', '代码', '实现', '调试', '报错', '优化', '重构', '数学',
    '计算', '逻辑', '推导', '算法', '架构', '设计', '总结一下', '解释',
  ];

  /// 工具意图动词（出现则不判 low——工具调用轮次需要 high 兜底）
  static const toolIntentKeywords = [
    '几点', '时间', '日期', '天气', '计算', '换算', '转换', '随机',
    '掷', '抽', '签', '占', '卦', '运势', '星座', '农历', '黄历',
    '记住', '忘记', '搜索', '查一下', '帮我查',
  ];

  /// 路由决策：返回 max/high/low
  ///
  /// [text] 用户消息正文；[hasAttachments] 带附件（图片/PDF 解析
  /// 需要视觉理解，直接 max）。
  static String route(String text, {bool hasAttachments = false}) {
    // 附件消息：视觉/文档理解，深度思考
    if (hasAttachments) return 'max';

    final t = text.trim();
    if (t.isEmpty) return 'high';

    // 1. max 触发词短路
    for (final kw in maxKeywords) {
      if (t.contains(kw)) return 'max';
    }

    // 2. low：短消息且无工具意图
    final hasToolIntent = toolIntentKeywords.any(t.contains);
    if (t.length <= 12 && !hasToolIntent && !t.startsWith('/')) {
      return 'low';
    }

    // 3. 默认均衡
    return 'high';
  }
}
