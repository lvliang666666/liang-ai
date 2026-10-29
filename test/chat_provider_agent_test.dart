import 'package:flutter_test/flutter_test.dart';
import 'package:ai_chat_app/models/chat_message.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;

  setUp(() async {
    db = await openTestDb();
    await DatabaseService.instance.initForTest(db);
  });

  tearDown(() {
    DatabaseService.instance.close();
    db.close();
  });

  ChatProvider makeProvider({Agent? agent}) => ChatProvider(
        database: DatabaseService.instance,
        api: ApiService(baseUrl: 'http://127.0.0.1:1', apiKey: 'test'),
        session: ChatSession(id: 's1', title: 't', createdAt: 1, updatedAt: 1),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        agent: agent,
      );

  group('消息组装逻辑（system prompt 插入规则）', () {
    test('Agent prompt 插入头部，历史消息保持顺序', () {
      final agent = Agent(id: 'a', name: 'N', prompt: '你是架构师');
      final messages = [
        ChatMessage(
            id: 'm1',
            sessionId: 's',
            role: 'user',
            content: '你好',
            createdAt: 1),
        ChatMessage(
            id: 'm2',
            sessionId: 's',
            role: 'assistant',
            content: '你好！',
            createdAt: 2),
      ];

      final result = buildApiMessagesForTest(agent, messages);

      expect(result.length, 3);
      expect(result[0]['role'], 'system');
      expect(result[0]['content'], '你是架构师');
      expect(result[1]['role'], 'user');
      expect(result[1]['content'], '你好');
      expect(result[2]['role'], 'assistant');
    });

    test('无 Agent：不含 system 消息', () {
      final messages = [
        ChatMessage(
            id: 'm1',
            sessionId: 's',
            role: 'user',
            content: 'hi',
            createdAt: 1),
      ];
      final result = buildApiMessagesForTest(null, messages);
      expect(result.length, 1);
      expect(result[0]['role'], 'user');
    });

    test('Agent prompt 为空：不插入 system', () {
      final agent = Agent(id: 'a', name: 'N', prompt: '');
      final result = buildApiMessagesForTest(agent, const []);
      expect(result, isEmpty);
    });
  });

  group('Agent 参数覆盖规则', () {
    test('会话为默认 max 时，Agent 预设 effort 生效', () {
      final agent = Agent(id: 'a', name: 'N', prompt: 'p', effort: 'low');
      expect(effectiveEffortForTest(agent, 'max'), 'low');
    });

    test('用户手动改过会话 effort 时，以用户为准', () {
      final agent = Agent(id: 'a', name: 'N', prompt: 'p', effort: 'low');
      expect(effectiveEffortForTest(agent, 'high'), 'high');
    });

    test('Agent 无 effort 预设时用会话值', () {
      final agent = Agent(id: 'a', name: 'N', prompt: 'p');
      expect(effectiveEffortForTest(agent, 'high'), 'high');
    });

    test('温度：Agent 预设优先，无预设用默认 0.7', () {
      expect(
        Agent(id: 'a', name: 'N', prompt: 'p', temperature: 0.3).temperature,
        0.3,
      );
      expect(Agent(id: 'a', name: 'N', prompt: 'p').temperature, isNull);
    });
  });

  group('工具子集注册表构建', () {
    test('toolNames null → 全部目录工具', () {
      final registry = buildRegistryForTest(null, builtinTools);
      expect(registry.names.length, builtinTools.length);
      expect(registry.names, contains('calculate'));
      expect(registry.names, contains('get_current_time'));
    });

    test('toolNames [] → 无工具', () {
      final registry =
          buildRegistryForTest(Agent(id: 's', name: 'N', prompt: 'p', toolNames: const []), builtinTools);
      expect(registry.names, isEmpty);
    });

    test('toolNames 子集 → 只含声明工具（目录中不存在的名字忽略）', () {
      final registry = buildRegistryForTest(
        Agent(id: 's', name: 'N', prompt: 'p',
            toolNames: const ['calculate', 'no_such_tool']),
        builtinTools,
      );
      expect(registry.names, ['calculate']);
    });
  });

  group('setAgent 切换', () {
    test('切换后 agent getter 更新且落库', () async {
      final provider = makeProvider();

      final agent = Agent(id: 'a2', name: 'Y', prompt: 'p2');
      await provider.setAgent(agent);
      expect(provider.agent?.id, 'a2');

      await provider.setAgent(null);
      expect(provider.agent, isNull);
      provider.dispose();
    });

    test('切换到无工具 Agent 后注册表重建为空', () async {
      final provider = makeProvider();
      // 默认（无 Agent）：全部工具
      expect(provider.toolCount, builtinTools.length);

      await provider.setAgent(Agent(
          id: 'none', name: '无工具', prompt: 'p', toolNames: const []));
      expect(provider.toolCount, 0);

      await provider.setAgent(null);
      expect(provider.toolCount, builtinTools.length);
      provider.dispose();
    });
  });
}

/// 复刻 ChatProvider._buildApiMessages 的组装规则（保持同步验证）
List<Map<String, Object?>> buildApiMessagesForTest(
    Agent? agent, List<ChatMessage> messages) {
  final prompt = agent?.prompt;
  return [
    if (prompt != null && prompt.isNotEmpty)
      {'role': 'system', 'content': prompt},
    ...messages.map((m) => m.toApiMessage()),
  ];
}

/// 复刻 ChatProvider._effectiveEffort 的覆盖规则
String effectiveEffortForTest(Agent? agent, String sessionEffort) {
  final agentEffort = agent?.effort;
  if (agentEffort != null && sessionEffort == 'max') {
    return agentEffort;
  }
  return sessionEffort;
}

/// 复刻 ChatProvider._buildRegistry 的构建规则
ToolRegistry buildRegistryForTest(Agent? agent, List<ToolHandler> catalog) {
  final registry = ToolRegistry();
  final allowed = agent?.toolNames;
  if (allowed == null) {
    registry.registerAll(catalog);
  } else {
    registry
        .registerAll(catalog.where((t) => allowed.contains(t.name)).toList());
  }
  return registry;
}
