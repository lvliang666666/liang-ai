import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/run_skill_tool.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可编程 ApiService mock：按请求序号返回脚本（与 M2/M4 测试同模式）
class ScriptedApiService implements ApiService {
  ScriptedApiService();

  int chatStreamCalls = 0;
  final List<List<Map<String, Object?>>?> lastMessagesPerCall = [];
  final List<List<Map<String, Object?>>?> lastToolsPerCall = [];
  final List<String?> lastEffortPerCall = [];

  /// 每次请求按序消费的脚本：每个元素是一次请求的事件序列
  final List<List<SseEvent>> scripts = [];

  @override
  Stream<SseEvent> chatStream({
    required ProviderProfile profile,
    required List<Map<String, Object?>> messages,
    required String model,
    required String effort,
    required CancelToken cancelToken,
    double temperature = 0.7,
    List<Map<String, Object?>>? tools,
  }) {
    final callIndex = chatStreamCalls;
    chatStreamCalls++;
    lastMessagesPerCall.add(messages);
    lastToolsPerCall.add(tools);
    lastEffortPerCall.add(effort);
    if (callIndex >= scripts.length) {
      return Stream.error(ApiException('脚本耗尽'));
    }
    return Stream.fromIterable(scripts[callIndex]);
  }

  @override
  void dispose() {}
}

/// 测试工具：返回固定文本
class StubTool extends ToolHandler {
  const StubTool(this.result, {this.name = 'stub'});
  final String result;
  final String name;

  @override
  String get description => '测试工具';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object'};
  @override
  Future<String> execute(Map<String, dynamic> arguments) async => result;
}

/// 可编程委派桥
class FakeDelegate implements RunSkillDelegate {
  FakeDelegate({Agent? skill, this.catalog = const [StubTool('目录工具结果')]})
      : _skill = skill;

  final Agent? _skill;
  final List<ToolHandler> catalog;
  CancelToken? cancelToken;

  /// 测试注入的脚本化 api（子 loop 复用宿主 api 的桥接点）
  ScriptedApiService? apiService;

  @override
  (ProviderProfile, String) currentTarget() =>
      (ProviderProfile.builtinCompany(), 'glm5.1');

  @override
  ApiService api() => apiService ??= ScriptedApiService();

  @override
  CancelToken? currentCancelToken() => cancelToken;

  @override
  Future<Agent?> skillById(String id) async => _skill;

  @override
  List<ToolHandler> toolCatalog() => catalog;
}

Agent skill({
  String id = 'translator',
  List<String>? toolNames,
}) =>
    Agent(
      id: id,
      name: '翻译官',
      prompt: '你是翻译官，只输出译文。',
      toolNames: toolNames,
    );

void main() {
  group('RunSkillTool 参数校验', () {
    test('skill_id 为空：抛 ArgumentError', () async {
      final tool = RunSkillTool(FakeDelegate(skill: skill()));
      await expectLater(
        tool.execute({'skill_id': '', 'task': '翻译'}),
        throwsArgumentError,
      );
    });

    test('task 为空：抛 ArgumentError', () async {
      final tool = RunSkillTool(FakeDelegate(skill: skill()));
      await expectLater(
        tool.execute({'skill_id': 'translator', 'task': ''}),
        throwsArgumentError,
      );
    });

    test('Skill 不存在：抛 ArgumentError（未知 Skill）', () async {
      final tool = RunSkillTool(FakeDelegate(skill: null));
      await expectLater(
        tool.execute({'skill_id': 'ghost', 'task': '翻译'}),
        throwsArgumentError,
      );
    });
  });

  group('子 loop 执行', () {
    test('单轮完成：返回最终文本，请求带 Skill prompt + 任务', () async {
      final api = ScriptedApiService();
      api.scripts.add([
        const SseDeltaContent('译文内容'),
        const SseDone(),
      ]);
      final delegate = FakeDelegate(skill: skill())..apiService = api;
      final tool = RunSkillTool(delegate);

      final result = await tool.execute(
          {'skill_id': 'translator', 'task': '翻译这句话'});

      expect(result, '译文内容');
      expect(api.chatStreamCalls, 1);
      // 独立历史：system = Skill prompt，user = 任务
      final msgs = api.lastMessagesPerCall[0]!;
      expect(msgs.length, 2);
      expect(msgs[0]['role'], 'system');
      expect(msgs[0]['content'], '你是翻译官，只输出译文。');
      expect(msgs[1]['role'], 'user');
      expect(msgs[1]['content'], '翻译这句话');
      // 子任务走 low 档
      expect(api.lastEffortPerCall[0], 'low');
    });

    test('工具轮：Skill 白名单过滤目录 + run_skill 永不注册（防递归）', () async {
      final api = ScriptedApiService();
      // 第一轮：请求调用 stub 工具；第二轮：直接回答
      api.scripts.add([
        const SseToolCallDelta(
            index: 0, id: 'call_1', name: 'stub', argumentsFragment: '{}'),
        const SseToolCallsFinished(),
      ]);
      api.scripts.add([
        const SseDeltaContent('工具结果已处理'),
        const SseDone(),
      ]);
      // 目录里有一个 run_skill 同名工具（模拟恶意/误配置）+ stub
      final delegate = FakeDelegate(
        skill: skill(toolNames: null), // null = 全部目录
        catalog: [
          const StubTool('目录工具结果'),
          const StubTool('不该出现', name: 'run_skill'),
        ],
      )..apiService = api;
      final tool = RunSkillTool(delegate);

      final result = await tool.execute(
          {'skill_id': 'translator', 'task': '用工具查一下'});

      expect(result, '工具结果已处理');
      expect(api.chatStreamCalls, 2);
      // 第一轮请求的 tools 数组不含 run_skill（防递归结构保证）
      final tools = api.lastToolsPerCall[0]!;
      final names = [
        for (final t in tools) (t['function'] as Map)['name'] as String,
      ];
      expect(names, contains('stub'));
      expect(names, isNot(contains('run_skill')));
      // 第二轮请求带 tool 结果消息
      final msgs2 = api.lastMessagesPerCall[1]!;
      final toolMsg = msgs2.firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['content'], '目录工具结果');
    });

    test('Skill 白名单 toolNames 非空：目录中未声明的工具不注册', () async {
      final api = ScriptedApiService();
      api.scripts.add([
        const SseDeltaContent('完成'),
        const SseDone(),
      ]);
      final delegate = FakeDelegate(
        skill: skill(toolNames: ['allowed_tool']),
        catalog: [
          const StubTool('结果', name: 'allowed_tool'),
          const StubTool('结果', name: 'forbidden_tool'),
        ],
      )..apiService = api;
      final tool = RunSkillTool(delegate);

      await tool.execute({'skill_id': 'translator', 'task': '任务'});

      final tools = api.lastToolsPerCall[0]!;
      final names = [
        for (final t in tools) (t['function'] as Map)['name'] as String,
      ];
      expect(names, ['allowed_tool']);
    });

    test('轮数上限 4：3 轮工具后第 4 轮注入强制收尾提示', () async {
      final api = ScriptedApiService();
      for (var i = 0; i < 3; i++) {
        api.scripts.add([
          SseToolCallDelta(
              index: 0, id: 'call_$i', name: 'stub', argumentsFragment: '{}'),
          const SseToolCallsFinished(),
        ]);
      }
      api.scripts.add([
        const SseDeltaContent('强制收尾'),
        const SseDone(),
      ]);
      final delegate = FakeDelegate(skill: skill())..apiService = api;
      final tool = RunSkillTool(delegate);

      final result = await tool.execute(
          {'skill_id': 'translator', 'task': '反复用工具'});

      expect(result, '强制收尾');
      expect(api.chatStreamCalls, 4);
      // 第 4 轮请求含强制收尾 system 提示
      final msgs4 = api.lastMessagesPerCall[3]!;
      expect(
        msgs4.any((m) =>
            m['role'] == 'system' &&
            (m['content'] as String).contains('轮数已达上限')),
        isTrue,
      );
    });

    test('主 loop 取消令牌已取消：子任务终止返回部分结果', () async {
      final api = ScriptedApiService();
      api.scripts.add([
        const SseDeltaContent('部分结果'),
        const SseDone(),
      ]);
      final delegate = FakeDelegate(skill: skill())..apiService = api;
      final token = CancelToken();
      token.cancel();
      delegate.cancelToken = token;
      final tool = RunSkillTool(delegate);

      final result = await tool.execute(
          {'skill_id': 'translator', 'task': '任务'});

      expect(result, '部分结果');
    });

    test('网络错误：抛 StateError（ToolRegistry 捕获转 isError 结果）', () async {
      final api = ScriptedApiService();
      api.scripts.add([
        const SseError('网关 500'),
      ]);
      final delegate = FakeDelegate(skill: skill())..apiService = api;
      final tool = RunSkillTool(delegate);

      await expectLater(
        tool.execute({'skill_id': 'translator', 'task': '任务'}),
        throwsStateError,
      );
    });

    test('空响应：抛 StateError（子任务返回空内容）', () async {
      final api = ScriptedApiService();
      api.scripts.add([const SseDone()]);
      final delegate = FakeDelegate(skill: skill())..apiService = api;
      final tool = RunSkillTool(delegate);

      await expectLater(
        tool.execute({'skill_id': 'translator', 'task': '任务'}),
        throwsStateError,
      );
    });
  });

  group('分片累积', () {
    test('多工具交错分片按 index 正确拼接', () async {
      final api = ScriptedApiService();
      api.scripts.add([
        const SseToolCallDelta(
            index: 0, id: 'call_a', name: 'stub', argumentsFragment: '{"a":'),
        const SseToolCallDelta(
            index: 1, id: 'call_b', name: 'stub', argumentsFragment: '{"b":'),
        const SseToolCallDelta(index: 0, argumentsFragment: '1}'),
        const SseToolCallDelta(index: 1, argumentsFragment: '2}'),
        const SseToolCallsFinished(),
      ]);
      api.scripts.add([
        const SseDeltaContent('完成'),
        const SseDone(),
      ]);
      final delegate = FakeDelegate(skill: skill())..apiService = api;
      final tool = RunSkillTool(delegate);

      final result = await tool.execute(
          {'skill_id': 'translator', 'task': '两个工具'});

      expect(result, '完成');
      // 两个工具都执行了（第二轮请求有两条 tool 消息）
      final msgs2 = api.lastMessagesPerCall[1]!;
      final toolMsgs = msgs2.where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs.length, 2);
    });
  });

  group('ToolRegistry 集成', () {
    test('run_skill 注册后可被 registry.execute 调用', () async {
      final api = ScriptedApiService();
      api.scripts.add([
        const SseDeltaContent('经 registry 执行'),
        const SseDone(),
      ]);
      final delegate = FakeDelegate(skill: skill())..apiService = api;
      final registry = ToolRegistry()
        ..register(RunSkillTool(delegate));

      final result = await registry.execute(const ToolCall(
        id: 'call_x',
        name: 'run_skill',
        argumentsJson: '{"skill_id": "translator", "task": "任务"}',
      ));

      expect(result.isError, isFalse);
      expect(result.content, '经 registry 执行');
    });

    test('registry.execute 捕获子任务异常转 isError', () async {
      final api = ScriptedApiService();
      api.scripts.add([const SseError('网关 500')]);
      final delegate = FakeDelegate(skill: skill())..apiService = api;
      final registry = ToolRegistry()
        ..register(RunSkillTool(delegate));

      final result = await registry.execute(const ToolCall(
        id: 'call_x',
        name: 'run_skill',
        argumentsJson: '{"skill_id": "translator", "task": "任务"}',
      ));

      expect(result.isError, isTrue);
      expect(result.content, contains('子任务请求失败'));
    });
  });
}
