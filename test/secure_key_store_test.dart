import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/secure_key_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// 内存 fake bridge：记录调用参数，行为与 SecureKeyStore 语义一致
class FakeKeyBridge implements SecureKeyBridge {
  final Map<String, String> store_ = {};
  final List<String> removed = [];

  @override
  Future<String?> resolve(String providerId) async => store_[providerId];

  @override
  Future<void> store(String providerId, String apiKey) async {
    store_[providerId] = apiKey;
  }

  @override
  Future<void> remove(String providerId) async {
    removed.add(providerId);
    store_.remove(providerId);
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late FakeKeyBridge bridge;

  setUp(() async {
    final inMemory = await openTestDb();
    db = DatabaseService.instance;
    await db.initForTest(inMemory);
    bridge = FakeKeyBridge();
    DatabaseService.keyBridge = bridge;
  });

  tearDown(() async {
    DatabaseService.keyBridge = null; // 不污染其他测试文件
    await db.close();
  });

  group('E6 bridge 在场：DB 写空 + 读注水', () {
    test('insertProvider：Key 进 bridge，DB 存空串', () async {
      final profile =
          ProviderProfile.builtinCompany().copyWith(apiKey: 'sk-secret-123');
      await db.insertProvider(profile);

      expect(bridge.store_[ProviderProfile.builtinCompanyId], 'sk-secret-123');

      // 直接查 DB 原始行：api_key 必须是空串（明文不落库）
      final raw = await db.database;
      final rows = await raw.query('providers',
          where: 'id = ?', whereArgs: [ProviderProfile.builtinCompanyId]);
      expect(rows.first['api_key'], '');

      // 读回：从 bridge 注水，profile 拿到真实 Key
      final restored = await db.getProvider(ProviderProfile.builtinCompanyId);
      expect(restored!.apiKey, 'sk-secret-123');
    });

    test('updateProvider：新 Key 覆盖 bridge 旧值', () async {
      final profile = ProviderProfile.builtinCompany().copyWith(
        apiKey: 'sk-old',
      );
      await db.insertProvider(profile);

      await db.updateProvider(profile.copyWith(apiKey: 'sk-new'));
      expect(bridge.store_[ProviderProfile.builtinCompanyId], 'sk-new');

      final restored = await db.getProvider(ProviderProfile.builtinCompanyId);
      expect(restored!.apiKey, 'sk-new');
    });

    test('updateProvider：Key 为空不覆盖 bridge（能力升级等场景）', () async {
      final profile = ProviderProfile.builtinCompany().copyWith(
        apiKey: 'sk-keep',
      );
      await db.insertProvider(profile);

      // UI 传回的 profile 常不带 Key（编辑表单只改名字等）
      await db.updateProvider(profile.copyWith(apiKey: '', name: '改名'));
      expect(bridge.store_[ProviderProfile.builtinCompanyId], 'sk-keep');

      final restored = await db.getProvider(ProviderProfile.builtinCompanyId);
      expect(restored!.apiKey, 'sk-keep');
      expect(restored.name, '改名');
    });

    test('deleteProvider：bridge 里的 Key 同步清除', () async {
      final custom = ProviderProfile(
        id: 'custom1',
        name: '自定义',
        baseUrl: 'https://x/v1',
        apiKey: 'sk-custom',
      );
      await db.insertProvider(custom);
      await db.deleteProvider('custom1');

      expect(bridge.removed, ['custom1']);
      expect(bridge.store_.containsKey('custom1'), isFalse);
    });

    test('getAllProviders：全部注水', () async {
      await db.insertProvider(
          ProviderProfile.builtinCompany().copyWith(apiKey: 'sk-a'));
      await db.insertProvider(ProviderProfile(
        id: 'c1',
        name: 'C',
        baseUrl: 'https://c/v1',
        apiKey: 'sk-b',
      ));

      final all = await db.getAllProviders();
      final keys = {for (final p in all) p.id: p.apiKey};
      expect(keys[ProviderProfile.builtinCompanyId], 'sk-a');
      expect(keys['c1'], 'sk-b');
    });
  });

  group('E6 bridge 不在场：行为与 v2.3.7 一致', () {
    setUp(() {
      DatabaseService.keyBridge = null;
    });

    test('insertProvider：Key 照旧存 DB 明文', () async {
      final profile =
          ProviderProfile.builtinCompany().copyWith(apiKey: 'sk-legacy');
      await db.insertProvider(profile);

      final restored = await db.getProvider(ProviderProfile.builtinCompanyId);
      expect(restored!.apiKey, 'sk-legacy');
    });
  });

  group('E6 migrateKeysToBridge：明文 → 安全存储（幂等）', () {
    test('DB 明文迁入 bridge 并置空；读回注水不丢', () async {
      // 模拟 v2.3.7 老数据：bridge 注入前 Key 已在 DB
      DatabaseService.keyBridge = null;
      final profile =
          ProviderProfile.builtinCompany().copyWith(apiKey: 'sk-plain');
      await db.insertProvider(profile);

      // 注入 bridge 后跑迁移
      DatabaseService.keyBridge = bridge;
      final migrated = await db.migrateKeysToBridge();
      expect(migrated, 1);
      expect(bridge.store_[ProviderProfile.builtinCompanyId], 'sk-plain');

      // DB 已置空
      final raw = await db.database;
      final rows = await raw.query('providers');
      expect(rows.first['api_key'], '');

      // 读回注水：用户无感知
      final restored = await db.getProvider(ProviderProfile.builtinCompanyId);
      expect(restored!.apiKey, 'sk-plain');
    });

    test('幂等：跑两遍第二遍零迁移', () async {
      DatabaseService.keyBridge = null;
      await db.insertProvider(
          ProviderProfile.builtinCompany().copyWith(apiKey: 'sk-x'));
      DatabaseService.keyBridge = bridge;

      expect(await db.migrateKeysToBridge(), 1);
      expect(await db.migrateKeysToBridge(), 0);
    });

    test('无明文 Key：零迁移', () async {
      await db.insertProvider(ProviderProfile.builtinCompany());
      expect(await db.migrateKeysToBridge(), 0);
    });

    test('bridge 未注入：直接返回 0 不崩溃', () async {
      DatabaseService.keyBridge = null;
      await db.insertProvider(
          ProviderProfile.builtinCompany().copyWith(apiKey: 'sk-y'));
      expect(await db.migrateKeysToBridge(), 0);
      // Key 仍在 DB（旧行为）
      final restored = await db.getProvider(ProviderProfile.builtinCompanyId);
      expect(restored!.apiKey, 'sk-y');
    });
  });

  group('SecureKeyStore 单键 JSON map 语义', () {
    setUpAll(() {
      // FlutterSecureStorage 走 platform channel：binding + mock handler
      // （widget 测试环境无真插件，mock 一个内存 map 模拟平台侧存储）
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage');
      final platformStore = <String, String>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'write':
            final args = call.arguments as Map<Object?, Object?>;
            platformStore[args['key'] as String] = args['value'] as String;
            return null;
          case 'read':
            return platformStore[call.arguments['key'] as String];
          case 'delete':
            platformStore.remove(call.arguments['key'] as String);
            return null;
        }
        return null;
      });
    });

    test('store/resolve/remove 往返（内存 cache 路径）', () async {
      final store = SecureKeyStore.instance;
      await store.store('p1', 'sk-1');
      await store.store('p2', 'sk-2');

      expect(await store.resolve('p1'), 'sk-1');
      expect(await store.resolve('p2'), 'sk-2');
      expect(await store.resolve('nope'), isNull);

      await store.remove('p1');
      expect(await store.resolve('p1'), isNull);
      expect(await store.resolve('p2'), 'sk-2');
    });

    test('空串 Key resolve 返回 null', () async {
      final store = SecureKeyStore.instance;
      await store.store('p3', '');
      expect(await store.resolve('p3'), isNull);
    });
  });
}
