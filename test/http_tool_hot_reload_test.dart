import 'package:ai_chat_app/models/chat_session.dart';
import 'package:ai_chat_app/models/http_tool.dart';
import 'package:ai_chat_app/models/provider_profile.dart';
import 'package:ai_chat_app/providers/chat_provider.dart';
import 'package:ai_chat_app/providers/http_tool_provider.dart';
import 'package:ai_chat_app/services/api_service.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:ai_chat_app/services/tools/http_tool_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

HttpTool tool({
  String id = 't1',
  String name = 'query_weather',
  String urlTemplate = 'https://api.example.com/old',
  bool enabled = true,
}) =>
    HttpTool(
      id: id,
      name: name,
      description: '查询天气',
      urlTemplate: urlTemplate,
      method: 'GET',
      headersJson: '',
      bodyTemplate: '',
      parametersJson: '',
      responsePath: '',
      maxResponseChars: 4000,
      enabled: enabled,
      createdAt: 1000,
      updatedAt: 1000,
    );

/// v2.32.1 回归锁：HTTP 工具编辑/删除/开关后活跃会话立即用新配置。
///
/// 用户报的 bug：编辑 URL 模板保存后，Agent 调用仍发往旧 URL——根因
/// 是会话注册表持有 HttpToolHandler 快照（构造时捕获 tool 对象），
/// 之前只有审批回调热更新目录，HttpToolProvider CRUD 无人监听。
///
/// 修复 = HomePage 挂 HttpToolProvider 监听 → 变化即重读 enabledTools
/// 重建目录（refreshToolCatalog）。本文件验证三层语义：
/// ① provider CRUD 后 notifyListeners 确实发出（监听源可用）
/// ② 重读目录 + refreshToolCatalog 后注册表拿到新配置（修复生效）
/// ③ 禁用/删除后工具从注册表消失（同族问题一并治好）
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('HTTP 工具热更新（v2.32.1 编辑旧配置回归锁）', () {
    late DatabaseService db;
    late HttpToolProvider httpProvider;

    setUp(() async {
      final inMemory = await openTestDb();
      db = DatabaseService.instance;
      await db.initForTest(inMemory);
      httpProvider = HttpToolProvider(database: db);
    });

    tearDown(() async {
      httpProvider.dispose();
      await db.close();
    });

    /// 复刻 home_page 的目录组装 + 监听回调（_refreshChatToolCatalog）
    ChatProvider makeChat(List<HttpTool> seed) {
      final chat = ChatProvider(
        database: db,
        api: ApiService(baseUrl: 'http://127.0.0.1:1', apiKey: 'test'),
        session:
            ChatSession(id: 's1', title: 't', createdAt: 1, updatedAt: 1),
        profile: ProviderProfile.builtinCompany(),
        model: 'glm5.1',
        toolCatalog: [
          ...builtinTools,
          for (final t in seed.where((t) => t.enabled)) HttpToolHandler(t),
        ],
      );
      // 复刻 HomePage._setupHttpToolsSub：provider 变化 → 重读目录热更新
      httpProvider.addListener(() {
        chat.refreshToolCatalog([
          ...builtinTools,
          for (final t in httpProvider.enabledTools) HttpToolHandler(t),
        ]);
      });
      return chat;
    }

    int customCount(ChatProvider chat) =>
        chat.toolCount - builtinTools.length;

    test('编辑 URL 后注册表拿到新配置（主 bug 回归锁）', () async {
      await httpProvider.create(tool(urlTemplate: 'https://old.example.com'));
      final chat = makeChat(httpProvider.tools);
      expect(customCount(chat), 1);

      // 编辑：同 id 改 URL（复刻编辑页 _save → provider.update）
      final edited =
          httpProvider.tools.single.copyWith(urlTemplate: 'https://new.example.com');
      await httpProvider.update(edited);

      // 监听回调已重建目录：注册表里的 handler 应持有新 URL
      final registry = chat.toolRegistryForTest;
      final handler =
          registry!.handlerByName('query_weather') as HttpToolHandler;
      expect(handler.tool.urlTemplate, 'https://new.example.com');
      chat.dispose();
    });

    test('禁用工具后从注册表消失（开关切换同族回归锁）', () async {
      await httpProvider.create(tool());
      final chat = makeChat(httpProvider.tools);
      expect(customCount(chat), 1);

      await httpProvider
          .update(httpProvider.tools.single.copyWith(enabled: false));

      expect(customCount(chat), 0);
      chat.dispose();
    });

    test('删除工具后从注册表消失', () async {
      await httpProvider.create(tool(id: 'a', name: 'tool_a'));
      await httpProvider.create(tool(id: 'b', name: 'tool_b'));
      final chat = makeChat(httpProvider.tools);
      expect(customCount(chat), 2);

      await httpProvider.delete('a');

      expect(customCount(chat), 1);
      chat.dispose();
    });

    test('provider CRUD 确实 notifyListeners（监听源可用性）', () async {
      var notified = 0;
      httpProvider.addListener(() => notified++);
      await httpProvider.create(tool());
      await httpProvider.update(httpProvider.tools.single);
      await httpProvider.delete(httpProvider.tools.single.id);
      expect(notified, 3);
    });
  });
}
