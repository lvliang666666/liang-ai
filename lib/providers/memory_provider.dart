import 'package:flutter/foundation.dart';

import '../models/memory.dart';
import '../services/memory_service.dart';

/// 记忆列表状态：加载 + CRUD 同步（记忆管理页用）
///
/// 订阅 [MemoryService.changeSignal]：AI 工具（memory_save/forget）或
/// 其他入口写库后自动重载列表，记忆管理页无需重启即见最新数据。
class MemoryProvider extends ChangeNotifier {
  MemoryProvider({required MemoryService service})
      : _service = service {
    MemoryService.changeSignal.addListener(_onServiceChange);
  }

  final MemoryService _service;
  List<Memory> _memories = [];
  bool _loaded = false;
  bool _reloading = false;

  List<Memory> get memories => _memories;
  bool get loaded => _loaded;

  @override
  void dispose() {
    MemoryService.changeSignal.removeListener(_onServiceChange);
    super.dispose();
  }

  /// 服务层写库信号 → 重载列表（未加载过则跳过，保持首帧加载语义）
  Future<void> _onServiceChange() async {
    if (!_loaded || _reloading) return;
    _reloading = true;
    try {
      await load();
    } finally {
      _reloading = false;
    }
  }

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
