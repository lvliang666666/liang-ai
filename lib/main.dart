import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/provider_profile.dart';
import 'pages/home_page.dart';
import 'providers/http_tool_provider.dart';
import 'providers/memory_provider.dart';
import 'providers/provider_provider.dart';
import 'providers/sessions_provider.dart';
import 'providers/skill_provider.dart';
import 'providers/theme_provider.dart';
import 'services/database_service.dart';
import 'services/memory_service.dart';
import 'services/secure_key_store.dart';
import 'services/settings_service.dart';
import 'services/skill_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsService(prefs);

  // E6 API Key 加固：先注入安全存储桥，DB 打开后把明文 Key 迁进去。
  // 顺序保证「先写安全存储成功，再清 DB 明文」；迁移幂等，崩溃重跑收敛。
  final keyStore = SecureKeyStore.instance;
  try {
    await keyStore.init();
    DatabaseService.keyBridge = keyStore;
  } catch (_) {
    // 安全存储不可用（极少数 ROM）：回退旧行为，Key 继续存 DB 明文
  }

  // 预热数据库 + 种子内置供应商（幂等）
  // 迁移：老用户在旧版设置页填过的 Key/URL/模型自动带入内置 profile，
  // 升级后无需重新填写
  final db = DatabaseService.instance;
  await db.database;
  if (!await db.hasBuiltinProviders()) {
    final seed = ProviderProfile.builtinCompany();
    final legacyKey = settings.apiKey;
    final legacyModel = settings.model;
    await db.insertProvider(legacyKey.isEmpty
        ? seed
        : seed.copyWith(
            apiKey: legacyKey,
            defaultModel:
                legacyModel.isEmpty ? seed.defaultModel : legacyModel,
          ));
  } else {
    // 老版本种子的能力声明缺后加能力位（如 v1.6.0 toolCalls），幂等补写
    await db.upgradeBuiltinProviderCapabilities();
  }
  // v2.3.7 及之前版本的 DB 明文 Key → 安全存储（幂等；无明文时零操作）
  await db.migrateKeysToBridge();

  runApp(AiChatApp(settings: settings));
}

class AiChatApp extends StatelessWidget {
  const AiChatApp({super.key, required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // ChangeNotifierProvider：SettingsService 现在是 ChangeNotifier
        //（快捷操作开关等 setter 会 notifyListeners，watch 它的组件即时重建）
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider(
          create: (_) => SessionsProvider(database: DatabaseService.instance),
        ),
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(settings: settings),
        ),
        ChangeNotifierProvider(
          create: (_) => SkillProvider(
            service: SkillService(database: DatabaseService.instance),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => ProviderProvider(
            database: DatabaseService.instance,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => MemoryProvider(
            service: MemoryService(database: DatabaseService.instance),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => HttpToolProvider(
            database: DatabaseService.instance,
          ),
        ),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
          title: 'Liang AI',
          theme: themeProvider.theme(Brightness.light),
          darkTheme: themeProvider.theme(Brightness.dark),
          themeMode: ThemeMode.system,
          home: const HomePage(),
        ),
      ),
    );
  }
}
