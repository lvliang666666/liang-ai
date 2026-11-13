import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/provider_profile.dart';
import 'pages/home_page.dart';
import 'providers/http_tool_provider.dart';
import 'providers/memory_provider.dart';
import 'providers/pending_tool_provider.dart';
import 'providers/provider_provider.dart';
import 'providers/sessions_provider.dart';
import 'providers/agent_provider.dart';
import 'providers/theme_provider.dart';
import 'services/database_service.dart';
import 'services/diagnostic_log.dart';
import 'services/memory_service.dart';
import 'services/secure_key_store.dart';
import 'services/settings_service.dart';
import 'services/agent_service.dart';
import 'theme/app_theme_registry.dart';
import 'theme/markdown_style_sheet.dart';
import 'widgets/app_error_widget.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 全局构建异常兜底（灰屏治理批次·需求二③）：build 阶段抛异常渲染
  // 可读错误页（图标+摘要+重试/返回），禁止出现纯灰屏。越早挂越好
  installGlobalErrorWidget();

  // E4 诊断日志：崩溃钩子 + 落盘目录（越早挂越好，启动期崩溃也有据可查）
  installDiagnosticHooks();
  unawaited(DiagnosticLog.init());

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

  // F1 FTS 检索底座：存量消息补索引（幂等——索引表空才重建，
  // 老库升级后首次启动跑一次，之后零操作）
  await db.rebuildFtsIndexIfEmpty();

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
          create: (_) => AgentProvider(
            service: AgentService(database: DatabaseService.instance),
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
        // 自我迭代批次：待审批工具（依赖 HttpToolProvider——审批通过
        // 时通知其重载；ProxyProvider 不可用（HttpToolProvider 非
        // ChangeNotifier 依赖注入形态），直接引用上方实例）
        ChangeNotifierProvider(
          create: (context) => PendingToolProvider(
            database: DatabaseService.instance,
            httpTools: context.read<HttpToolProvider>(),
          ),
        ),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
          title: 'Liang AI',
          // 打磨批次 V：中文本地化——文本选择菜单（全选/复制/粘贴）等
          // 系统 label 渲染中文，与全中文 UI 一致（此前默认英文）
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          locale: const Locale('zh', 'CN'),
          theme: themeProvider.theme(Brightness.light),
          darkTheme: themeProvider.theme(Brightness.dark),
          themeMode: ThemeMode.system,
          // Markdown 渲染令牌注入（2026-11-05 对比度批次）：builder 包
          // GptMarkdownTheme（InheritedWidget 路径，绕开 ThemeExtension
          // F-bounded 泛型的 copyWith 类型问题），全 app GptMarkdown
          // 自动继承——标题/表格/行内代码等颜色从主题令牌派生
          builder: (context, child) {
            final scheme = Theme.of(context).colorScheme;
            // 全局错误页重试：监听 generation 自增，换 key 强制重建
            // 整棵子树（ErrorWidget 场景下原子树已废，重建是唯一恢复
            // 路径）。ValueListenableBuilder 只在重试时重建，零常开销
            return ValueListenableBuilder<int>(
              valueListenable: kErrorPageRetryGeneration,
              builder: (context, generation, _) => GptMarkdownTheme(
                key: ValueKey('app-tree-$generation'),
                gptThemeData: markdownThemeData(
                  scheme,
                  tokens: AppThemeRegistry.markdownTokensOf(
                    themeProvider.current,
                  ),
                ),
                child: child!,
              ),
            );
          },
          home: const HomePage(),
        ),
      ),
    );
  }
}
