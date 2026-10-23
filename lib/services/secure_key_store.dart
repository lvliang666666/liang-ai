import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// E6 API Key 加固：Key 与 DB 分离的安全存储桥
///
/// DB 的 providers.api_key 列只存空串；真实 Key 存系统安全存储
/// （Android Keystore 加密的 EncryptedSharedPreferences / iOS Keychain）。
/// [DatabaseService] 通过 [SecureKeyBridge] 抽象访问，测试注入 fake 实现。
abstract class SecureKeyBridge {
  /// 取供应商 Key（无记录返回 null）
  Future<String?> resolve(String providerId);

  /// 存供应商 Key
  Future<void> store(String providerId, String apiKey);

  /// 删供应商 Key（供应商被删除时调用）
  Future<void> remove(String providerId);
}

/// SecureKeyBridge 生产实现：flutter_secure_storage 单键 JSON map
///
/// 存储结构：key = 'provider_keys'，value = {"<providerId>": "<apiKey>"}。
/// 内存 cache 兜底读取性能（每次聊天请求都要 resolve）。
class SecureKeyStore implements SecureKeyBridge {
  SecureKeyStore._();

  static const _storageKey = 'provider_keys';
  static final SecureKeyStore _instance = SecureKeyStore._();

  /// 初始化完成的单例（main 启动时调用 [init]）
  static SecureKeyStore get instance => _instance;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  Map<String, String>? _cache;

  /// 启动时加载安全存储中的 Key map 到内存
  Future<void> init() async {
    final raw = await _storage.read(key: _storageKey);
    _cache = _decode(raw);
  }

  Map<String, String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded.map((k, v) => MapEntry(k, v is String ? v : ''));
      }
    } catch (_) {}
    return {}; // 脏数据容错：当无 Key 处理（用户重填即可）
  }

  Map<String, String> get _keys => _cache ?? {};

  @override
  Future<String?> resolve(String providerId) async {
    final v = _keys[providerId];
    return (v == null || v.isEmpty) ? null : v;
  }

  @override
  Future<void> store(String providerId, String apiKey) async {
    final next = {..._keys, providerId: apiKey};
    _cache = next;
    await _storage.write(key: _storageKey, value: jsonEncode(next));
  }

  @override
  Future<void> remove(String providerId) async {
    if (!_keys.containsKey(providerId)) return;
    final next = {..._keys}..remove(providerId);
    _cache = next;
    await _storage.write(key: _storageKey, value: jsonEncode(next));
  }
}
