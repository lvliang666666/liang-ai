import 'package:dio/dio.dart';

import '../models/chat_message.dart';
import '../models/memory.dart';
import '../models/provider_profile.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'fts_service.dart';
import 'memory_service.dart';
import 'sse_parser.dart';

/// F7 截图视觉记忆：分享进来的图片 → 视觉理解生成描述 → 可搜索可沉淀。
///
/// 三层产出（全部可选降级，视觉失败不阻塞聊天主链路）：
/// 1. **描述生成**：图片走多模态请求（low 档低温），模型输出图片内容
///    描述文本；失败返回 null（调用方 toast 提示，消息照常可发）
/// 2. **FTS 索引**：描述文本以「截图描述」消息形态入 FTS（复用
///    FtsService.indexMessage）——「上次那张讲报销流程的截图」可被
///    全文搜索找回
/// 3. **记忆沉淀**：用户点「沉淀进记忆」→ MemoryService.save（tag 标记
///    截图来源），进入跨会话记忆池参与注入
///
/// 服务无状态（每次调用独立请求），可注入 ApiService 供测试。
class ScreenshotMemoryService {
  ScreenshotMemoryService({
    required ApiService api,
    required DatabaseService db,
    MemoryService? memoryService,
    FtsService? ftsService,
  })  : _api = api,
        _db = db,
        _memory = memoryService ?? MemoryService(database: db),
        _fts = ftsService ?? FtsService(db);

  final ApiService _api;
  final DatabaseService _db;
  final MemoryService _memory;
  final FtsService _fts;

  /// 描述请求推理档位（轻任务走 low，快且省 token）
  static const effort = 'low';

  /// 描述请求温度（低温保证描述稳定）
  static const temperature = 0.2;

  /// 描述长度上限（超出截断，rune 安全）
  static const maxDescriptionLength = 800;

  /// 视觉理解 system prompt：描述图片内容，供后续搜索与记忆
  static const _systemPrompt = '''
你是图片内容描述器。用户给你一张图片（可能是截图、照片、文档等），
输出一段中文描述，让没看过图的人能明白图里有什么、讲了什么。

要求：
- 先一句话概括图片类型与主题（如「一张报销流程说明截图」「一张聊天记录截图」）
- 再列出关键信息：文字内容要点、数字、日期、人名、界面元素等
- 图片是文档/表格时保留关键条目原文；是聊天记录时概括双方说了什么
- 只描述图片中实际存在的内容，绝不编造看不清或不存在的信息
- 看不清的部分明确说「无法辨认」
- 输出纯文本描述，200 字以内，不要任何前缀（如「好的，描述如下」）''';

  /// 生成图片描述（视觉理解）。
  ///
  /// [imageBase64] 图片 base64（不带 data: 前缀）；[hint] 用户附言
  /// （如分享时的上下文），拼进请求帮助理解。
  /// 返回描述文本；网络/服务端失败返回 null（不抛异常）。
  Future<String?> describe({
    required String imageBase64,
    required ProviderProfile profile,
    required String model,
    String? hint,
  }) async {
    final userContent = [
      {
        'type': 'text',
        'text': hint == null || hint.trim().isEmpty
            ? '请描述这张图片的内容'
            : '请描述这张图片的内容。补充说明：$hint',
      },
      {
        'type': 'image_url',
        'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'},
      },
    ];
    final buffer = StringBuffer();
    try {
      await for (final event in _api.chatStream(
        profile: profile,
        messages: [
          {'role': 'system', 'content': _systemPrompt},
          {'role': 'user', 'content': userContent},
        ],
        model: model,
        effort: effort,
        cancelToken: CancelToken(),
        temperature: temperature,
      )) {
        switch (event) {
          case SseDeltaContent(:final text):
            buffer.write(text);
          case SseError():
            return null;
          default:
            break;
        }
      }
    } catch (_) {
      return null; // 视觉失败静默，不阻塞聊天
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) return null;
    return _clamp(text);
  }

  /// 把描述文本写入 FTS 索引（以「截图描述」虚拟消息形态）。
  ///
  /// 描述与分享图片的会话绑定（sessionId 可空——空闲态分享时先无会话，
  /// 描述仍可入索引，会话删除级联时按 id 清理）。
  /// 返回索引用的消息 id（沉淀记忆/删除时定位）。
  Future<String> indexDescription({
    required String description,
    String? sessionId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'shot_${now}_${description.length}';
    // 描述文本直接进 messages 表（role=assistant，content=描述），
    // 复用消息的 FTS 索引与搜索链路——不新加表，零迁移
    await _db.insertMessage(ChatMessage(
      id: id,
      sessionId: sessionId ?? '',
      role: 'assistant',
      content: '【截图描述】$description',
      createdAt: now,
    ));
    await _fts.indexMessage(ChatMessage(
      id: id,
      sessionId: sessionId ?? '',
      role: 'assistant',
      content: '【截图描述】$description',
      createdAt: now,
    ));
    return id;
  }

  /// 把描述沉淀进记忆池（tag 标记截图来源）。
  /// 返回落库的记忆。
  Future<Memory> saveToMemory(String description) {
    return _memory.save(
      description,
      tag: Memory.screenshotTag,
      sourceAgent: '截图记忆',
    );
  }

  /// 按 rune 截断（中文安全，不切半个字符）
  static String _clamp(String text, [int max = maxDescriptionLength]) {
    final runes = text.runes.toList();
    if (runes.length <= max) return text;
    return String.fromCharCodes(runes.sublist(0, max));
  }
}
