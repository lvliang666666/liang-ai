import 'package:ai_chat_app/providers/memory_provider.dart';
import 'package:ai_chat_app/services/database_service.dart';
import 'package:ai_chat_app/services/memory_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_db.dart';

/// dispose 测试哨兵：标记 provider 已手动 dispose，tearDown 跳过
class _DisposedSentinel extends MemoryProvider {
  _DisposedSentinel()
      : super(service: MemoryService(database: DatabaseService.instance));
}

/// MemoryProvider 订阅 MemoryService.changeSignal 自动刷新测试
///
/// 用真实 ffi 内存库（纯异步逻辑，无 widget，fake async 不构成障碍）：
/// 模拟「AI 工具用另一个 MemoryService 实例写库」→ provider 自动重载。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late MemoryProvider provider;

  setUp(() async {
    db = DatabaseService.instance;
    final inMemory = await openTestDb();
    await db.initForTest(inMemory);
    provider = MemoryProvider(
      service: MemoryService(database: db),
    );
  });

  tearDown(() async {
    // dispose 测试用哨兵替换，避免二次 dispose 抛异常
    if (provider is! _DisposedSentinel) {
      provider.dispose();
    }
    await db.close();
  });

  /// 轮询等待 provider 列表满足条件（信号是异步消费的）
  Future<void> waitUntil(bool Function() cond) async {
    for (var i = 0; i < 100 && !cond(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('changeSignal 自动刷新', () {
    test('另一实例 save 后 provider 列表自动出现新记忆', () async {
      await provider.load();
      expect(provider.memories, isEmpty);

      // 模拟 AI 工具：独立 service 实例写库（工具层每次自建实例）
      final toolService = MemoryService(database: db);
      await toolService.save('用户喜欢简洁回答', tag: '偏好');

      await waitUntil(
          () => provider.memories.any((m) => m.content == '用户喜欢简洁回答'));
      expect(provider.memories.length, 1);
    });

    test('另一实例 deleteByKeyword 后 provider 列表自动移除', () async {
      final toolService = MemoryService(database: db);
      await toolService.save('会被忘掉的记忆');
      await provider.load();
      expect(provider.memories.length, 1);

      await toolService.deleteByKeyword('忘掉');
      await waitUntil(() => provider.memories.isEmpty);
      expect(provider.memories, isEmpty);
    });

    test('另一实例 deleteAll 后 provider 列表自动清空', () async {
      final toolService = MemoryService(database: db);
      await toolService.save('a');
      await toolService.save('b');
      await provider.load();
      expect(provider.memories.length, 2);

      await toolService.deleteAll();
      await waitUntil(() => provider.memories.isEmpty);
      expect(provider.memories, isEmpty);
    });

    test('未加载过（loaded=false）不响应信号，保持首帧加载语义', () async {
      final toolService = MemoryService(database: db);
      await toolService.save('提前写入');
      // 不调 provider.load()，给信号消费机会
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(provider.loaded, isFalse);
      expect(provider.memories, isEmpty);
    });

    test('dispose 后不再响应信号（不抛异常）', () async {
      await provider.load();
      final toolService = MemoryService(database: db);
      provider.dispose();
      // 已 dispose，tearDown 不再重复 dispose
      provider = _DisposedSentinel();
      // dispose 后信号触发不应抛（listener 已移除）
      await toolService.save('dispose 后写入');
      expect(MemoryService.changeSignal.value, greaterThan(0));
    });
  });
}
