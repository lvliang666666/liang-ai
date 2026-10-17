import 'package:flutter/services.dart' show rootBundle;

import '../models/agent.dart';
import 'agent_parser.dart';
import 'database_service.dart';

/// Agent 服务：内置资产种子入库 + CRUD 委托数据库
class AgentService {
  AgentService({required DatabaseService database}) : _db = database;

  final DatabaseService _db;

  /// 内置 Agent 资产清单（assets/agents/ 下的 .md 文件）
  static const builtinAssets = [
    'assets/agents/default.md',
    'assets/agents/architect.md',
    'assets/agents/copywriter.md',
    'assets/agents/tutor.md',
    'assets/agents/brainstorm.md',
    'assets/agents/translator.md',
  ];

  /// 首次启动：把内置 Agent 从 assets 解析入库（幂等）
  Future<void> seedBuiltinAgents() async {
    if (await _db.hasBuiltinAgents()) return;
    for (final asset in builtinAssets) {
      final raw = await rootBundle.loadString(asset);
      final id = asset.split('/').last.replaceAll('.md', '');
      await _db.insertAgent(AgentParser.parseToAgent(id, raw));
    }
  }

  Future<List<Agent>> getAll() => _db.getAllAgents();

  Future<Agent?> getById(String id) => _db.getAgent(id);

  /// 新建自定义 Agent
  Future<Agent> create({
    required String name,
    required String prompt,
    String icon = '🤖',
    String description = '',
    double? temperature,
    String? effort,
  }) async {
    final agent = Agent(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: name,
      icon: icon,
      description: description,
      prompt: prompt,
      temperature: temperature,
      effort: effort,
    );
    await _db.insertAgent(agent);
    return agent;
  }

  Future<void> update(Agent agent) => _db.updateAgent(agent);

  /// 内置 Agent 复制为自定义副本
  Future<Agent> duplicate(Agent builtin) async {
    final copy = builtin.copyAsCustom(
        DateTime.now().microsecondsSinceEpoch.toRadixString(36));
    await _db.insertAgent(copy);
    return copy;
  }

  /// 删除（内置 Agent 由 UI 层禁止调用此方法）
  Future<void> delete(String id) => _db.deleteAgent(id);
}
