import '../database_service.dart';
import '../memory_service.dart';
import '../tool_registry.dart';

/// 记忆工具三件套：memory_save / memory_search / memory_forget
///
/// 供模型主动存取用户长期记忆（跨会话跨 Agent 生效）。
/// 服务绑定应用数据库单例（测试中经 initForTest 指向内存库），
/// 因此工具保持 const 构造，可直接进 builtinTools 常量目录。
///
/// description 引导模型克制使用：只在用户明确表达偏好/事实时存。

/// 保存记忆：用户明确表达偏好/事实/背景时调用
class MemorySaveTool extends ToolHandler {
  const MemorySaveTool({this.sourceAgent});

  /// 来源 Agent 名（ChatProvider 构建注册表时注入，溯源用，可空）
  ///
  /// 非 final：const 目录里的实例是共享模板，注册表构建时按当前会话
  /// 的 Agent 复制并填入来源。
  final String? sourceAgent;

  @override
  String get name => 'memory_save';

  @override
  String get description =>
      '保存一条用户长期记忆（跨会话生效）。只在用户明确表达个人偏好、重要事实、'
      '长期背景时使用（如「记住我喜欢简洁回答」「我在上海工作」），'
      '不要保存临时信息或闲聊内容。tag 为分类标签（偏好/背景/习惯/其他），可省略。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'content': {
            'type': 'string',
            'description': '记忆内容，一句话事实（如「用户喜欢简洁回答」）',
          },
          'tag': {
            'type': 'string',
            'description': '分类标签：偏好/背景/习惯/其他，可省略',
          },
        },
        'required': ['content'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final content = arguments['content'];
    if (content is! String || content.trim().isEmpty) {
      throw ArgumentError('content 不能为空');
    }
    final tag = arguments['tag'];
    final memory = await MemoryService(database: DatabaseService.instance).save(
      content,
      tag: tag is String && tag.trim().isNotEmpty ? tag.trim() : null,
      sourceAgent: sourceAgent,
    );
    return '已记住：${memory.content}'
        '${memory.tag != null ? '（标签：${memory.tag}）' : ''}';
  }
}

/// 检索记忆：需要回忆用户偏好/背景时调用
class MemorySearchTool extends ToolHandler {
  const MemorySearchTool();

  @override
  String get name => 'memory_search';

  @override
  String get description =>
      '检索用户长期记忆。当需要回忆用户的偏好、背景、习惯等信息时使用，'
      '返回匹配的记忆列表。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'keyword': {
            'type': 'string',
            'description': '检索关键词（如「偏好」「工作」「称呼」）',
          },
        },
        'required': ['keyword'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final keyword = arguments['keyword'];
    if (keyword is! String || keyword.trim().isEmpty) {
      throw ArgumentError('keyword 不能为空');
    }
    final hits =
        await MemoryService(database: DatabaseService.instance).search(keyword);
    if (hits.isEmpty) return '没有找到与「${keyword.trim()}」相关的记忆';
    return [
      '找到 ${hits.length} 条相关记忆：',
      for (final m in hits)
        '- ${m.content}${m.tag != null ? '（${m.tag}）' : ''}',
    ].join('\n');
  }
}

/// 遗忘记忆：用户要求删除记忆时调用
class MemoryForgetTool extends ToolHandler {
  const MemoryForgetTool();

  @override
  String get name => 'memory_forget';

  @override
  String get description =>
      '删除用户长期记忆。当用户要求「忘掉/删除某条记忆」时使用，'
      '按关键词匹配删除，返回删除条数。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'keyword': {
            'type': 'string',
            'description': '要删除的记忆关键词（匹配记忆内容）',
          },
        },
        'required': ['keyword'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final keyword = arguments['keyword'];
    if (keyword is! String || keyword.trim().isEmpty) {
      throw ArgumentError('keyword 不能为空');
    }
    final deleted = await MemoryService(database: DatabaseService.instance)
        .deleteByKeyword(keyword);
    if (deleted == 0) return '没有找到与「${keyword.trim()}」相关的记忆，未删除';
    return '已删除 $deleted 条记忆';
  }
}

/// 检索历史会话（M4 情景记忆层）：「之前/上周我们讨论过 X」类问题
///
/// 检索 session_summaries 表（每会话一条「标题+摘要+关键词」，会话
/// 结束时自动生成）。当前会话不参与检索——本会话内容已在上下文里，
/// 「之前」指的是其他会话。
class SearchHistoryTool extends ToolHandler {
  const SearchHistoryTool({this.currentSessionId});

  /// 当前会话 id（ChatProvider 构建注册表时注入，检索时排除）
  ///
  /// 非 final：const 目录里的实例是共享模板，注册表构建时按当前会话
  /// 复制并填入（与 MemorySaveTool.sourceAgent 同模式）。
  final String? currentSessionId;

  @override
  String get name => 'search_history';

  @override
  String get description =>
      '检索历史会话摘要。当用户提到「之前/上次/上周我们讨论过什么」'
      '或需要回顾过往对话的结论时使用，返回匹配的历史会话列表'
      '（标题+摘要+关键词+时间）。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'keyword': {
            'type': 'string',
            'description': '检索关键词（如「报销」「部署方案」「某产品名」）',
          },
        },
        'required': ['keyword'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final keyword = arguments['keyword'];
    if (keyword is! String || keyword.trim().isEmpty) {
      throw ArgumentError('keyword 不能为空');
    }
    final hits = await DatabaseService.instance.searchSessionSummaries(
      keyword,
      excludeSessionId: currentSessionId,
    );
    if (hits.isEmpty) {
      return '没有找到与「${keyword.trim()}」相关的历史会话';
    }
    return [
      '找到 ${hits.length} 个相关历史会话：',
      for (final s in hits)
        '- ${s.title}：${s.summary}'
            '${s.keywords.isNotEmpty ? '（关键词：${s.keywords.join('、')}）' : ''}',
    ].join('\n');
  }
}
