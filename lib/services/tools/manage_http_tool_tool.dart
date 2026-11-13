import 'dart:convert';

import '../../models/http_tool.dart';
import '../../models/pending_tool.dart';
import '../database_service.dart';
import '../tool_registry.dart';

/// 内置工具名清单（重名校验用——防模型提交与内置工具同名的定义，
/// ToolRegistry.register 同名覆盖是现有行为，必须在入口拦）
///
/// 从 builtin_tools.dart 聚合导入会引入循环依赖风险（builtin_tools
/// 不依赖本文件，但保持单向更稳），这里用静态清单 + 测试锁同步
/// （test/manage_http_tool_tool_test 断言清单与 builtinTools 实际
/// name 集合一致，漂移即红）。
const builtinToolNames = <String>[
  // 时间
  'get_current_time', 'date_calc',
  // 设备
  'get_device_info',
  // 计算
  'calculate', 'unit_convert', 'base_convert', 'math_function',
  // 随机
  'random_number', 'random_pick', 'dice_flip',
  // 文本
  'text_stats', 'uuid_generate', 'base64_codec', 'hash_text',
  // 记忆
  'memory_save', 'memory_search', 'memory_forget', 'search_history',
  // 玄学
  'lunar_calendar', 'bazi', 'wuxing', 'zodiac', 'huangli',
  'guanyin', 'tarot', 'zhougong', 'shuzi', 'xingming',
  'dice_iching', 'peach_blossom',
  // 自我迭代
  'manage_http_tool',
  // 注：run_skill 是宿主条件注册（AgentService 在场才注册），不在
  // builtinTools 常量目录——重名校验天然覆盖（模型提交 run_skill 名
  // 的 HTTP 工具会与注册表里的 RunSkillTool 同名覆盖，但 RunSkillTool
  // 只在有 AgentService 的会话注册；此处清单只锁常量目录，防漂移测试
  // 与 builtinTools 对齐）
];

/// 自我迭代工具（v2.32.0 亮点功能）：模型设计并提交新 HTTP 工具
///
/// **审批闸门在工具层**：execute 只做校验 + 写 pending_tools 表，
/// 绝不直接落 http_tools——用户在审批卡片（聊天流/设置页 Tools tab）
/// 点「通过」才生效。模型无法绕过审批自己调用未批准的工具（工具在
/// registry 里存在的前提是已落 http_tools）。
///
/// 防失控边界（v1）：
/// - 只能新增，不能修改/删除已有工具（破坏性操作必须人工）
/// - 重名校验对 http_tools 现有表 + pending 队列双重查重（防覆盖
///   内置工具——ToolRegistry.register 同名覆盖是现有行为，入口必须拦）
/// - 待审批 ≤5 条/会话（防模型刷屏）
/// - URL 仅 http/https（防 file:// 等协议）
///
/// 校验失败抛异常（ToolRegistry.execute 捕获转 isError 结果），
/// 模型能看到错误文本自行修正后重提。
class ManageHttpToolTool extends ToolHandler {
  const ManageHttpToolTool({this.sessionId});

  /// 提交来源会话 id（ChatProvider 构建注册表时注入，pending 归属 +
  /// 审批卡片定位用；null = 测试场景）
  ///
  /// 非 final 语义同 MemorySaveTool.sourceAgent：const 目录里的实例
  /// 是共享模板，注册表构建时按当前会话复制并填入。
  final String? sessionId;

  /// 每会话待审批上限（防模型刷屏）
  static const maxPendingPerSession = 5;

  @override
  String get name => 'manage_http_tool';

  @override
  String get description =>
      '创建一个新的 HTTP 工具并提交用户审批（审批通过后你就能调用它）。'
      '当用户需要接入外部 API（查天气/查快递/调内部系统等）而现有工具'
      '无法覆盖时使用。你需要给出完整的工具定义：工具名（字母数字下划'
      '线连字符）、功能描述、URL 模板（{param} 占位符）、HTTP 方法、'
      '参数定义（JSON Schema properties）。提交后等待用户在审批卡片'
      '上确认，不要重复提交同一工具；被拒绝时根据拒绝原因修改后重提。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description':
                '工具名（OpenAI function name 规范：字母/数字/下划线/连字符，'
                '如 query_weather）',
          },
          'description': {
            'type': 'string',
            'description': '功能描述（一句话说清工具做什么，模型据此决定何时调用）',
          },
          'url_template': {
            'type': 'string',
            'description':
                'URL 模板，{param} 占位符（如 https://api.example.com/weather?city={city}）',
          },
          'method': {
            'type': 'string',
            'enum': ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'],
            'description': 'HTTP 方法，默认 GET',
          },
          'headers_json': {
            'type': 'string',
            'description': '请求头 JSON 对象字符串（可选，如 {"Authorization": "Bearer xxx"}）',
          },
          'body_template': {
            'type': 'string',
            'description': '请求体模板（POST/PUT/PATCH 用，{param} 占位符，可选）',
          },
          'parameters_json': {
            'type': 'string',
            'description':
                '参数定义 JSON Schema properties 段（如 {"city": {"type": "string", "description": "城市名"}}）',
          },
          'response_path': {
            'type': 'string',
            'description': '响应截取路径（点路径如 data.temp，可选，留空返回全文）',
          },
        },
        'required': ['name', 'description', 'url_template'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final sid = sessionId;
    if (sid == null || sid.isEmpty) {
      throw StateError('manage_http_tool 缺少会话上下文（注册表未注入 sessionId）');
    }

    // 1. 必填字段校验
    final name = (arguments['name'] as String?)?.trim() ?? '';
    final description = (arguments['description'] as String?)?.trim() ?? '';
    final urlTemplate = (arguments['url_template'] as String?)?.trim() ?? '';
    if (name.isEmpty) throw ArgumentError('name 不能为空');
    if (description.isEmpty) throw ArgumentError('description 不能为空');
    if (urlTemplate.isEmpty) throw ArgumentError('url_template 不能为空');

    // 2. 工具名规范（OpenAI function name 规范）
    if (!HttpTool.isValidName(name)) {
      throw ArgumentError(
          '工具名 "$name" 不合法：只能用字母/数字/下划线/连字符，最长 64 字符');
    }

    // 3. 重名校验：内置工具名 + 已有 HTTP 工具 + 待审批队列（三重查重，
    //    防覆盖内置工具——ToolRegistry.register 同名覆盖是现有行为）
    final db = DatabaseService.instance;
    final builtinNames = {for (final t in builtinToolNames) t};
    if (builtinNames.contains(name)) {
      throw ArgumentError('工具名 "$name" 与内置工具冲突，请换一个名字');
    }
    final existing = await db.getAllHttpTools();
    if (existing.any((t) => t.name == name)) {
      throw ArgumentError(
          '工具名 "$name" 已存在（HTTP 工具）。本工具只能新增，修改已有工具'
          '请在设置 → Tools 中手动编辑');
    }
    final dupPending = await db.getPendingToolByName(sid, name);
    if (dupPending != null) {
      throw ArgumentError(
          '工具名 "$name" 已在待审批队列中，等待用户处理，不要重复提交');
    }

    // 4. URL 协议白名单（防 file:// 等非 HTTP 协议）
    final lowerUrl = urlTemplate.toLowerCase();
    if (!lowerUrl.startsWith('http://') && !lowerUrl.startsWith('https://')) {
      throw ArgumentError('URL 必须以 http:// 或 https:// 开头');
    }

    // 5. method 白名单
    final method =
        ((arguments['method'] as String?) ?? 'GET').trim().toUpperCase();
    const allowedMethods = {'GET', 'POST', 'PUT', 'DELETE', 'PATCH'};
    if (!allowedMethods.contains(method)) {
      throw ArgumentError(
          'method 必须是 GET/POST/PUT/DELETE/PATCH 之一，收到 "$method"');
    }

    // 6. headers/parameters 必须是合法 JSON 对象（填了才校验）
    final headersJson = ((arguments['headers_json'] as String?) ?? '').trim();
    if (headersJson.isNotEmpty) {
      final decoded = _tryDecode(headersJson);
      if (decoded == null) {
        throw ArgumentError('headers_json 不是合法 JSON 对象');
      }
    }
    final parametersJson =
        ((arguments['parameters_json'] as String?) ?? '').trim();
    if (parametersJson.isNotEmpty) {
      final decoded = _tryDecode(parametersJson);
      if (decoded == null) {
        throw ArgumentError('parameters_json 不是合法 JSON 对象');
      }
    }

    // 7. 待审批数量上限（防刷屏：超限要求先处理积压）
    final pendingCount = await db.countPendingTools(sid);
    if (pendingCount >= maxPendingPerSession) {
      throw ArgumentError(
          '待审批工具已达上限（$maxPendingPerSession 条），请等用户处理现有'
          '审批后再提交新工具');
    }

    // 8. 入待审批队列（不落 http_tools——审批闸门）
    final pending = PendingTool(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      sessionId: sid,
      name: name,
      description: description,
      urlTemplate: urlTemplate,
      method: method,
      headersJson: headersJson,
      bodyTemplate: ((arguments['body_template'] as String?) ?? '').trim(),
      parametersJson: parametersJson,
      responsePath: ((arguments['response_path'] as String?) ?? '').trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insertPendingTool(pending);

    return '工具 "$name" 已提交，等待用户审批。请在回复中告知用户：'
        '审批卡片已在对话中弹出，用户可以试运行后点「通过」或「拒绝」。'
        '通过后你就可以直接调用这个工具了（无需重新加载）。';
  }

  /// JSON 对象解析（坏 JSON/非对象返回 null）
  static Map<String, dynamic>? _tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
