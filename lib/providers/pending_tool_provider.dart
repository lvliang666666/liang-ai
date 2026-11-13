import 'package:flutter/foundation.dart';

import '../models/http_tool.dart';
import '../models/pending_tool.dart';
import '../services/database_service.dart';
import 'http_tool_provider.dart';

/// 待审批工具状态（自我迭代批次）：加载 + 审批流转（通过/拒绝）
///
/// 审批通过 = pending 行转正（落 http_tools + 删 pending）+ 通知
/// [HttpToolProvider] 重载——设置页 Tools tab 与聊天审批卡片共用本
/// provider，状态单一事实来源。
class PendingToolProvider extends ChangeNotifier {
  PendingToolProvider({
    required DatabaseService database,
    required HttpToolProvider httpTools,
  })  : _db = database,
        _httpTools = httpTools;

  final DatabaseService _db;
  final HttpToolProvider _httpTools;

  List<PendingTool> _tools = [];
  bool _loaded = false;

  List<PendingTool> get tools => _tools;
  bool get loaded => _loaded;

  /// 指定会话的待审批子集（聊天审批卡片渲染用）
  List<PendingTool> forSession(String sessionId) =>
      _tools.where((t) => t.sessionId == sessionId).toList();

  Future<void> load() async {
    _tools = await _db.getAllPendingTools();
    _loaded = true;
    notifyListeners();
  }

  /// 审批通过：pending → http_tools 落库 + 删 pending + HTTP 列表刷新
  ///
  /// 返回转正后的 HttpTool（宿主据此做会话内即时生效接线）。
  /// 工具名落库前二次校验（模型可能在提交后、审批前与人工新建撞名）。
  Future<HttpTool> approve(PendingTool tool) async {
    final httpTool = tool.toHttpTool();
    await _db.insertHttpTool(httpTool);
    await _db.deletePendingTool(tool.id);
    await _httpTools.load();
    await load();
    return httpTool;
  }

  /// 拒绝：删 pending（工具定义丢弃，模型可修改重提）
  Future<void> reject(PendingTool tool) async {
    await _db.deletePendingTool(tool.id);
    await load();
  }
}
