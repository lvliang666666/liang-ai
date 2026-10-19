import 'package:flutter/foundation.dart';

import '../models/provider_profile.dart';
import '../services/database_service.dart';

/// 供应商列表状态
class ProviderProvider extends ChangeNotifier {
  ProviderProvider({required DatabaseService database}) : _db = database;

  final DatabaseService _db;
  List<ProviderProfile> _profiles = [];
  bool _loaded = false;

  List<ProviderProfile> get profiles => _profiles;
  bool get loaded => _loaded;

  /// 默认供应商（列表第一个，内置优先排序由 DB 保证）
  ProviderProfile get defaultProfile =>
      _profiles.isEmpty ? ProviderProfile.builtinCompany() : _profiles.first;

  Future<void> load() async {
    _profiles = await _db.getAllProviders();
    _loaded = true;
    notifyListeners();
  }

  Future<void> create(ProviderProfile profile) async {
    await _db.insertProvider(profile);
    await load();
  }

  Future<void> update(ProviderProfile profile) async {
    await _db.updateProvider(profile);
    await load();
  }

  /// 删除供应商（引用它的会话由 DB 层解绑）
  Future<void> delete(String id) async {
    await _db.deleteProvider(id);
    await load();
  }

  /// 按 id 查找（找不到返回 null）
  ProviderProfile? byId(String? id) {
    if (id == null) return null;
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }
}
