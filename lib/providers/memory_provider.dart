import 'package:flutter/foundation.dart';

import '../models/memory.dart';
import '../services/memory_service.dart';

/// 记忆列表状态：加载 + CRUD 同步（记忆管理页用）
class MemoryProvider extends ChangeNotifier {
  MemoryProvider({required MemoryService service}) : _service = service;

  final MemoryService _service;
  List<Memory> _memories = [];
  bool _loaded = false;

  List<Memory> get memories => _memories;
  bool get loaded => _loaded;

  Future<void> load() async {
    _memories = await _service.getAll();
    _loaded = true;
    notifyListeners();
  }

  /// 手动添加一条记忆
  Future<Memory> add(String content, {String? tag}) async {
    final memory = await _service.save(content, tag: tag);
    await load(); // 重新排序（新条目时间戳最新）
    return memory;
  }

  Future<void> delete(String id) async {
    await _service.delete(id);
    _memories = _memories.where((m) => m.id != id).toList();
    notifyListeners();
  }

  /// 按关键词删除（模型 memory_forget 同款语义），返回删除条数
  Future<int> deleteByKeyword(String keyword) async {
    final deleted = await _service.deleteByKeyword(keyword);
    await load();
    return deleted;
  }

  Future<void> deleteAll() async {
    await _service.deleteAll();
    _memories = [];
    notifyListeners();
  }
}
