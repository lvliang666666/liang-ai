import 'package:flutter/foundation.dart';

import '../models/chat_session.dart';
import '../services/database_service.dart';

/// 会话列表状态
class SessionsProvider extends ChangeNotifier {
  SessionsProvider({required DatabaseService database}) : _db = database;

  final DatabaseService _db;
  List<ChatSession> _sessions = [];
  bool _loaded = false;

  List<ChatSession> get sessions => _sessions;
  bool get loaded => _loaded;

  Future<void> loadSessions() async {
    _sessions = await _db.getAllSessions();
    _loaded = true;
    notifyListeners();
  }

  /// 创建新会话并返回
  ///
  /// [agentId] 选中的 Agent（null = 默认助手）；
  /// [providerId]/[model] 主页打开即聊时预选的供应商与模型（null = 用默认）。
  Future<ChatSession> createSession(
    String effort, {
    String? agentId,
    String? providerId,
    String? model,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = ChatSession(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      title: '新对话',
      createdAt: now,
      updatedAt: now,
      effort: effort,
      agentId: agentId,
      providerId: providerId,
      model: model,
    );
    await _db.insertSession(session);
    _sessions = [session, ..._sessions];
    notifyListeners();
    return session;
  }

  Future<void> renameSession(String id, String title) async {
    await _db.updateSessionTitle(id, title);
    _sessions = [
      for (final s in _sessions)
        if (s.id == id) s..title = title else s
    ];
    notifyListeners();
  }

  /// 设置会话置顶（I7）：落库 + 内存同步 + 重排（置顶组恒在前）
  Future<void> setSessionPinned(String id, bool pinned) async {
    await _db.setSessionPinned(id, pinned);
    _sessions = [
      for (final s in _sessions)
        if (s.id == id) s..pinned = pinned else s
    ]..sort(_sessionOrder);
    notifyListeners();
  }

  /// 会话排序：置顶在前，组内按更新时间倒序（与 DB 查询同规则）
  static int _sessionOrder(ChatSession a, ChatSession b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    return b.updatedAt.compareTo(a.updatedAt);
  }

  Future<void> deleteSession(String id) async {
    await _db.deleteSession(id);
    _sessions = _sessions.where((s) => s.id != id).toList();
    notifyListeners();
  }

  /// 刷新单个会话（聊天页返回后同步标题/时间）
  Future<void> refresh() => loadSessions();
}
