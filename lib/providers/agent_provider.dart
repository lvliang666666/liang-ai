import 'package:flutter/foundation.dart';

import '../models/agent.dart';
import '../services/agent_parser.dart';
import '../services/agent_service.dart';

/// Agent 列表状态：加载 + CRUD 同步
class AgentProvider extends ChangeNotifier {
  AgentProvider({required AgentService service}) : _service = service;

  final AgentService _service;
  List<Agent> _agents = [];
  bool _loaded = false;

  List<Agent> get agents => _agents;
  bool get loaded => _loaded;

  /// 底层服务（T2 run_skill 委派桥：ChatProvider 按 id 查 Skill 用）
  AgentService get service => _service;

  /// 内置 Agent（列表前段）
  List<Agent> get builtins =>
      _agents.where((s) => s.isBuiltin).toList();

  /// 自定义 Agent
  List<Agent> get customs =>
      _agents.where((s) => !s.isBuiltin).toList();

  Future<void> load() async {
    await _service.seedBuiltinAgents(); // 幂等：以资产为准重写内置行
    _agents = await _service.getAll();
    _loaded = true;
    notifyListeners();
  }

  Agent? byId(String? id) {
    if (id == null) return null;
    for (final s in _agents) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<Agent> create({
    required String name,
    required String prompt,
    String icon = '🤖',
    String description = '',
    double? temperature,
    String? effort,
    List<String>? toolNames,
  }) async {
    final agent = await _service.create(
      name: name,
      prompt: prompt,
      icon: icon,
      description: description,
      temperature: temperature,
      effort: effort,
      toolNames: toolNames,
    );
    _agents = [..._agents, agent];
    notifyListeners();
    return agent;
  }

  Future<void> update(Agent agent) async {
    await _service.update(agent);
    _agents = [
      for (final s in _agents) if (s.id == agent.id) agent else s
    ];
    notifyListeners();
  }

  /// 内置 Agent 复制为自定义副本
  Future<Agent> duplicate(Agent builtin) async {
    final copy = await _service.duplicate(builtin);
    _agents = [..._agents, copy];
    notifyListeners();
    return copy;
  }

  /// T3 从分享码导入：解析文本 → 入库为自定义 Agent
  ///
  /// 解析失败抛异常由 UI 层提示；成功后刷新列表并返回新 Agent。
  Future<Agent> importFromShareCode(String raw) async {
    final agent = AgentParser.fromShareCode(
      DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      raw,
    );
    await _service.create(
      name: agent.name,
      prompt: agent.prompt,
      icon: agent.icon,
      description: agent.description,
      temperature: agent.temperature,
      effort: agent.effort,
      toolNames: agent.toolNames,
    );
    _agents = [..._agents, agent];
    notifyListeners();
    return agent;
  }

  Future<void> delete(String id) async {
    await _service.delete(id);
    _agents = _agents.where((s) => s.id != id).toList();
    notifyListeners();
  }
}
