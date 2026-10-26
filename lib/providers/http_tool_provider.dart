import 'package:flutter/foundation.dart';

import '../models/http_tool.dart';
import '../services/database_service.dart';

/// 自定义 HTTP 工具列表状态（T1）：加载 + CRUD 同步
class HttpToolProvider extends ChangeNotifier {
  HttpToolProvider({required DatabaseService database}) : _db = database;

  final DatabaseService _db;
  List<HttpTool> _tools = [];
  bool _loaded = false;

  List<HttpTool> get tools => _tools;

  /// 启用中的工具（进工具目录的子集）
  List<HttpTool> get enabledTools =>
      _tools.where((t) => t.enabled).toList();

  bool get loaded => _loaded;

  Future<void> load() async {
    _tools = await _db.getAllHttpTools();
    _loaded = true;
    notifyListeners();
  }

  Future<void> create(HttpTool tool) async {
    await _db.insertHttpTool(tool);
    await load();
  }

  Future<void> update(HttpTool tool) async {
    await _db.updateHttpTool(tool);
    await load();
  }

  Future<void> delete(String id) async {
    await _db.deleteHttpTool(id);
    await load();
  }
}
