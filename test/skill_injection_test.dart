import 'dart:async';

import 'package:ai_chat_app/models/agent.dart';
import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/skill_variables.dart';
import 'package:ai_chat_app/services/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 可编程 ApiService mock（同 doc_injection_test 模式，捕获 messages）
class MockApiService implements ApiService {
  MockApiService();

  final _controller = StreamController<SseEvent>.broadcast();
  int chatStreamCalls = 0;
  List<Map<String, Object?>>? lastMessages;

  void emit(SseEvent event) => _controller.add(event);

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
    chatStreamCalls++;
    lastMessages = messages;
    return _controller.stream;
  }

  @override
  void dispose() {}
}

/// F10 变量插槽注入测试：prompt 渲染进 payload
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late MockApiService api;
  late ChatProvider provider;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    api = MockApiService();
    final session = ChatSession(
        id: 's1', title: '新对话', createdAt: 1000, updatedAt: 1000);
    await db.insertSession(session);
    provider = ChatProvider(
      database: db,
      api: api,
      session: session,
      profile: ProviderProfile.builtinCompany(),
      model: 'glm5.1',
    );
  });

  tearDown(() async {
    provider.dispose();
    await db.close();
  });

  /// sendMessage 后等 loop 建立订阅再 emit（真实 DB IO 有事件循环跳转）
  Future<void> sendAndWait(String text) async {
    final sent = provider.sendMessage(text);
    await Future.delayed(Duration.zero);
    for (var i = 0; i < 100 && api.chatStreamCalls == 0; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    api.emit(const SseDeltaContent('回答'));
    api.emit(const SseDone());
    await sent;
    await Future.delayed(Duration.zero);
  }

  String? systemPrompt() {
    for (final m in api.lastMessages!) {
      if (m['role'] == 'system') return m['content'] as String;
    }
    return null;
  }

  group('变量渲染进 payload', () {
    test('自定义变量替换为填写值', () async {
      final agent = Agent(
          id: 'a1', name: '写手', prompt: '你是{{风格}}助手，主题{{topic}}');
      await provider.setAgent(agent, variables: {'风格': '严谨', 'topic': '物理'});
      await sendAndWait('你好');
      expect(systemPrompt(), '你是严谨助手，主题物理');
    });

    test('内置变量按发送时刻求值', () async {
      final agent = Agent(id: 'a1', name: 'x', prompt: '今天 {{date}}');
      await provider.setAgent(agent);
      await sendAndWait('你好');
      final p = systemPrompt()!;
      expect(p, startsWith('今天 '));
      expect(p, isNot(contains('{{')));
      // 日期格式 yyyy-MM-dd
      expect(RegExp(r'今天 \d{4}-\d{2}-\d{2}$').hasMatch(p), isTrue);
    });

    test('未填写变量替换为空串（不残留 {{x}}）', () async {
      final agent = Agent(id: 'a1', name: 'x', prompt: '你是{{风格}}助手');
      await provider.setAgent(agent);
      await sendAndWait('你好');
      final p = systemPrompt()!;
      expect(p, '你是助手');
      expect(p, isNot(contains('{{')));
    });

    test('无变量 prompt 原样注入（老 Skill 零影响）', () async {
      final agent = Agent(id: 'a1', name: 'x', prompt: '普通提示词');
      await provider.setAgent(agent);
      await sendAndWait('你好');
      expect(systemPrompt(), '普通提示词');
    });

    test('无 Agent：无 system prompt（行为不变）', () async {
      await sendAndWait('你好');
      expect(systemPrompt(), isNull);
    });
  });

  group('人格预设', () {
    test('setPersona 写入 persona 变量并渲染', () async {
      final agent = Agent(
        id: 'a1',
        name: '写手',
        prompt: '风格：{{persona}}',
        personas: const [SkillPersona('正式', '正式商务')],
      );
      await provider.setAgent(agent);
      provider.setPersona(agent.personas.first);
      expect(provider.activePersonaName, '正式');
      await sendAndWait('你好');
      expect(systemPrompt(), '风格：正式商务');
    });

    test('setPersona(null) 取消预设', () async {
      final agent = Agent(
        id: 'a1',
        name: '写手',
        prompt: '风格：{{persona}}',
        personas: const [SkillPersona('正式', '正式商务')],
      );
      await provider.setAgent(agent);
      provider.setPersona(agent.personas.first);
      provider.setPersona(null);
      expect(provider.activePersonaName, isNull);
      await sendAndWait('你好');
      expect(systemPrompt(), '风格：');
    });

    test('agentPersonas 透出与 agentVariables 回显', () async {
      final agent = Agent(
        id: 'a1',
        name: '写手',
        prompt: '风格 {{persona}} 主题 {{topic}}',
        personas: const [SkillPersona('正式', '正式商务')],
      );
      await provider.setAgent(agent, variables: {'topic': '物理'});
      expect(provider.agentPersonas, hasLength(1));
      expect(provider.agentHasVariables, isTrue);
      expect(provider.agentVariables['topic'], '物理');
      // setAgentVariables 更新（表单二次打开）
      provider.setAgentVariables({'topic': '化学'});
      expect(provider.agentVariables['topic'], '化学');
    });

    test('换 Agent 清空旧变量（旧值语义失效）', () async {
      final a1 = Agent(id: 'a1', name: 'x', prompt: 'A {{v}}');
      final a2 = Agent(id: 'a2', name: 'y', prompt: 'B {{v}}');
      await provider.setAgent(a1, variables: {'v': '旧值'});
      await provider.setAgent(a2);
      expect(provider.agentVariables, isEmpty);
      await sendAndWait('你好');
      expect(systemPrompt(), 'B ');
    });
  });
}
