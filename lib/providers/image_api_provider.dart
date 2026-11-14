import 'package:flutter/foundation.dart';

import '../models/image_api.dart';
import '../services/database_service.dart';

/// 生图 API 配置列表状态（Image Forge）：加载 + CRUD 同步
class ImageApiProvider extends ChangeNotifier {
  ImageApiProvider({required DatabaseService database}) : _db = database;

  final DatabaseService _db;
  List<ImageApi> _apis = [];
  bool _loaded = false;

  List<ImageApi> get apis => _apis;

  /// 启用中的配置（generate_image 工具可用的子集）
  List<ImageApi> get enabledApis => _apis.where((a) => a.enabled).toList();

  /// 缺省配置：第一个启用的（多 API 时模型不指定就用它）
  ImageApi? get defaultApi =>
      _apis.isEmpty ? null : _apis.firstWhere((a) => a.enabled);

  bool get loaded => _loaded;

  Future<void> load() async {
    _apis = await _db.getAllImageApis();
    _loaded = true;
    notifyListeners();
  }

  Future<void> create(ImageApi api) async {
    await _db.insertImageApi(api);
    await load();
  }

  Future<void> update(ImageApi api) async {
    await _db.updateImageApi(api);
    await load();
  }

  Future<void> delete(String id) async {
    await _db.deleteImageApi(id);
    await load();
  }
}
