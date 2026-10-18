import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pages/home_page.dart';
import 'providers/agent_provider.dart';
import 'providers/sessions_provider.dart';
import 'providers/theme_provider.dart';
import 'services/agent_service.dart';
import 'services/database_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsService(prefs);

  // 预热数据库
  await DatabaseService.instance.database;

  runApp(AiChatApp(settings: settings));
}

class AiChatApp extends StatelessWidget {
  const AiChatApp({super.key, required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SettingsService>.value(value: settings),
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
