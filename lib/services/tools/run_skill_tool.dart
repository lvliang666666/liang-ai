import 'dart:async';

import 'package:dio/dio.dart';

import '../../models/agent.dart';
import '../../models/tool_call.dart';
import '../../models/provider_profile.dart';
import '../api_service.dart';
import '../sse_parser.dart';
import '../tool_registry.dart';

/// T2 Skill 链式编排：主 agent 把任意 Skill 委派到隔离子 loop 跑完汇报
///
/// 「零服务端代价的多 agent 最小形态」——Skill 从静态模板升维成
/// 可被模型调度的能力包。子 loop 特性：
/// - **独立消息历史**：system = Skill prompt + 委派任务，不携带主会话
///   上下文（隔离 = 不污染主 loop 历史，也不被主历史干扰）
/// - **Skill 工具白名单**：只注册 Skill.toolNames 声明的工具（从主
///   loop 的目录中选取；null = 全部目录工具，与主 loop 同规则）
/// - **轮数上限 4**：子任务应短平快，超限注入系统提示强制收尾
/// - **防递归**：子 loop 工具目录**永不包含 run_skill**（深度限制 1，
///   结构上杜绝 Skill 调 Skill 的无限链）
/// - **不落库**：子 loop 全程内存态，只有最终汇报以 tool 结果消息
///   进入主会话（主会话历史保持一条主线）
///
/// 委派执行通过 [RunSkillDelegate] 注入（宿主 ChatProvider 实现）：
/// 工具类保持纯 Dart 可单测，profile/model/取消令牌等运行时状态
/// 由宿主在 execute 时点提供。
abstract class RunSkillDelegate {
  /// 当前生效的供应商与模型（子 loop 请求走主会话同款）
  (ProviderProfile, String) currentTarget();

  /// 主 loop 的 ApiService（子 loop 复用同一连接池；测试注入 mock）
  ApiService api();

  /// 当前取消令牌（主 loop 被用户停止时子 loop 同步终止）
  CancelToken? currentCancelToken();

  /// 按 id 取 Skill（不存在返回 null → 工具报「未知 Skill」）
  Future<Agent?> skillById(String id);

  /// 主 loop 的工具目录（子 loop 白名单的选取范围）
  List<ToolHandler> toolCatalog();
}

class RunSkillTool extends ToolHandler {
  const RunSkillTool(this._delegate);

  final RunSkillDelegate _delegate;

  @override
  String get name => 'run_skill';

  @override
  String get description =>
      '把一个 Skill（Agent 人格）作为子任务委派执行：子任务在独立上下文中'
      '运行（只看到该 Skill 的系统提示与你给的任务描述），跑完返回最终'
      '汇报。适合把专项工作（翻译/审稿/头脑风暴等）交给对应专家处理，'
      '或需要多视角时并行征询。skill_id 取 Skill 的 id，task 用一句话'
      '说清要它做什么（可带必要的背景材料）。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'skill_id': {
            'type': 'string',
            'description': '要委派的 Skill id（如 translator / architect）',
          },
          'task': {
            'type': 'string',
            'description': '委派给该 Skill 的任务描述（一句话，可带背景材料）',
          },
        },
        'required': ['skill_id', 'task'],
      };

  /// 子 loop 轮数上限（子任务短平快；主 loop 是 8）
  static const maxSubIterations = 4;

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final skillId = arguments['skill_id'];
    final task = arguments['task'];
    if (skillId is! String || skillId.trim().isEmpty) {
      throw ArgumentError('skill_id 不能为空');
    }
    if (task is! String || task.trim().isEmpty) {
      throw ArgumentError('task 不能为空');
    }

    final skill = await _delegate.skillById(skillId.trim());
    if (skill == null) {
      throw ArgumentError('未知 Skill：$skillId');
    }

    final (profile, model) = _delegate.currentTarget();
    final api = _delegate.api(); // 复用宿主连接池（测试注入 mock）
    final cancelToken = _delegate.currentCancelToken();
    final catalog = _delegate.toolCatalog();

    // 子 loop 工具白名单：Skill.toolNames 从主目录选取；
    // **永不注册 run_skill**（防递归，深度限制 1 的结构保证）
    final allowed = skill.toolNames;
    final selected = (allowed == null
            ? catalog
            : catalog.where((t) => allowed.contains(t.name)))
        .where((t) => t.name != name)
        .toList();
    final registry = ToolRegistry()..registerAll(selected);

    // 独立消息历史：Skill prompt 为 system，任务为 user
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': skill.prompt},
      {'role': 'user', 'content': task.trim()},
    ];

    // api 生命周期归宿主所有，这里不 dispose
    return _runSubLoop(api, profile, model, cancelToken, registry, messages);
  }

  /// 隔离子 loop：请求 → 工具轮 → … → 最终文本（全程内存态，不落库）
  Future<String> _runSubLoop(
    ApiService api,
    ProviderProfile profile,
    String model,
    CancelToken? cancelToken,
    ToolRegistry registry,
    List<Map<String, Object?>> messages,
  ) async {
    for (var iteration = 0; iteration < maxSubIterations; iteration++) {
      final forceSummary = iteration == maxSubIterations - 1;
      if (forceSummary) {
        messages.add(const {
          'role': 'system',
          'content': '子任务轮数已达上限，请立即基于已有信息给出最终汇报，'
              '不要再调用任何工具。',
        });
      }

      final buffer = StringBuffer();
      final calls = <ToolCall>[];
      final completer = Completer<void>();
      // 工具轮后服务端常尾随 [DONE]：与主 loop 同款防重收尾
      var toolRoundStarted = false;
      Object? streamError;

      final token = cancelToken ?? CancelToken();
      StreamSubscription<SseEvent>? sub;
      sub = api
          .chatStream(
        profile: profile,
        messages: messages,
        model: model,
        effort: 'low',
        cancelToken: token,
        temperature: 0.7,
        tools: registry.isNotEmpty ? registry.toOpenAiTools() : null,
      )
          .listen(
        (event) {
          switch (event) {
            case SseDeltaContent(:final text):
              buffer.write(text);
            case SseToolCallDelta():
              _accumulate(event, calls);
            case SseToolCallsFinished():
              toolRoundStarted = true;
              scheduleMicrotask(() {
                if (!completer.isCompleted) completer.complete();
              });
            case SseDone():
              if (toolRoundStarted) return;
              if (!completer.isCompleted) completer.complete();
            case SseInterrupted():
              if (toolRoundStarted) return;
              if (!completer.isCompleted) completer.complete();
            case SseError(:final message):
              if (toolRoundStarted) return;
              streamError = message;
              if (!completer.isCompleted) completer.complete();
            default:
              break;
          }
        },
        onError: (Object e) {
          streamError = e is ApiException ? e.message : '请求失败：$e';
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future;
      await sub.cancel();

      // 主 loop 已取消：子任务终止，交回部分结果
      if (token.isCancelled) {
        final partial = buffer.toString().trim();
        return partial.isEmpty ? '（子任务被用户停止）' : partial;
      }
      if (streamError != null) {
        throw StateError('子任务请求失败：$streamError');
      }

      // 无工具调用 = 子任务完成，返回最终汇报
      if (calls.isEmpty) {
        final text = buffer.toString().trim();
        if (text.isEmpty) throw StateError('子任务返回空内容');
        return text;
      }

      // 工具轮：assistant(tool_calls) + tool 结果追加进子历史，继续下一轮
      messages.add({
        'role': 'assistant',
        'content': buffer.toString(),
        'tool_calls': [
          for (final c in calls)
            {
              'id': c.id,
              'type': 'function',
              'function': {'name': c.name, 'arguments': c.argumentsJson},
            },
        ],
      });
      for (final c in calls) {
        final result = await registry.execute(c);
        messages.add({
          'role': 'tool',
          'tool_call_id': result.callId,
          'content': result.content,
        });
      }
    }
    // 理论不可达（forceSummary 已让模型收尾），兜底取最后缓冲
    throw StateError('子任务轮数耗尽仍未收尾');
  }

  /// 工具调用分片累积（与主 loop 同规则：首片 id/name，后续片增量）
  void _accumulate(SseToolCallDelta event, List<ToolCall> calls) {
    while (calls.length <= event.index) {
      calls.add(const ToolCall(id: '', name: ''));
    }
    final c = calls[event.index];
    calls[event.index] = ToolCall(
      id: event.id ?? c.id,
      name: event.name ?? c.name,
      argumentsJson: c.argumentsJson + (event.argumentsFragment ?? ''),
    );
  }
}
