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

  /// 按会话缓存的过滤结果（v2.32.1 性能修复）：气泡 build 每帧调
  /// forSession，无缓存时每次 where().toList() 分配新 List——流式
  /// 期间全列表逐帧重建 × 每气泡一次 = GC 压力风暴。缓存随 _tools
  /// 变化（load/approve/reject）失效。
  final Map<String, List<PendingTool>> _sessionCache = {};

  List<PendingTool> get tools => _tools;
  bool get loaded => _loaded;

  /// 指定会话的待审批子集（聊天审批卡片渲染用，带缓存）
  List<PendingTool> forSession(String sessionId) =>
      _sessionCache.putIfAbsent(
          sessionId, () => _tools.where((t) => t.sessionId == sessionId).toList());

  /// 缓存失效（_tools 变化时调用）
  void _invalidateSessionCache() => _sessionCache.clear();

  Future<void> load() async {
    _tools = await _db.getAllPendingTools();
    _loaded = true;
    _invalidateSessionCache();
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

  @override
  void dispose() {
    _sessionCache.clear();
    super.dispose();
  }
}
