import 'package:flutter/foundation.dart';

import '../models/agent.dart';
import '../services/agent_service.dart';

/// Agent 列表状态：加载 + CRUD 同步
class AgentProvider extends ChangeNotifier {
  AgentProvider({required AgentService service}) : _service = service;

  final AgentService _service;
  List<Agent> _agents = [];
  bool _loaded = false;

  List<Agent> get agents => _agents;
  bool get loaded => _loaded;

  /// 内置 Agent（列表前段）
  List<Agent> get builtins =>
      _agents.where((a) => a.isBuiltin).toList();

  /// 自定义 Agent
  List<Agent> get customs =>
      _agents.where((a) => !a.isBuiltin).toList();

  Future<void> load() async {
    await _service.seedBuiltinAgents(); // 幂等：仅首次入库
    _agents = await _service.getAll();
    _loaded = true;
    notifyListeners();
  }

  Agent? byId(String? id) {
    if (id == null) return null;
    for (final a in _agents) {
      if (a.id == id) return a;
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
  }) async {
    final agent = await _service.create(
      name: name,
      prompt: prompt,
      icon: icon,
      description: description,
      temperature: temperature,
      effort: effort,
    );
    _agents = [..._agents, agent];
    notifyListeners();
    return agent;
  }

  Future<void> update(Agent agent) async {
    await _service.update(agent);
    _agents = [
      for (final a in _agents) if (a.id == agent.id) agent else a
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

  Future<void> delete(String id) async {
    await _service.delete(id);
    _agents = _agents.where((a) => a.id != id).toList();
    notifyListeners();
  }
}
