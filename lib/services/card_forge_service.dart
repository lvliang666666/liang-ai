import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/card.dart';
import '../models/chat_message.dart';
import '../models/provider_profile.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'sse_parser.dart';

/// M5 对话炼金炉：把一条消息沉淀为知识卡片
///
/// 流程：消息文本 → 强约束 JSON 提炼 prompt（low 档低温）→ 收集流式
/// 输出 → 解析（剥 markdown 围栏 + 容错截取）→ 失败回退本地截断
///（首行/前 80 字为标题，全文为正文，无标签）——提炼是增强而非门槛，
/// 离线/网关异常时用户依然能一键存卡。
///
/// 卡片入库走 [DatabaseService.insertCard]（用户策展资产，无去重/
/// 淘汰——同一消息可多次沉淀，用户自行管理）。
class CardForgeService {
  CardForgeService({required ApiService api, required DatabaseService db})
      : _api = api,
        _db = db;

  final ApiService _api;
  final DatabaseService _db;

  /// 提炼请求推理档位（轻任务走 low，快且省 token）
  static const effort = 'low';

  /// 提炼请求温度（低温保证 JSON 输出稳定）
  static const temperature = 0.2;

  /// 标题长度上限（超出截断）
  static const maxTitleLength = 50;

  /// 正文长度上限（超出截断）
  static const maxContentLength = 2000;

  /// 标签个数上限
  static const maxTags = 3;

  /// 强约束提炼 system prompt：只输出 JSON
  static const _systemPrompt = '''
你是知识卡片提炼器。把用户给的一条对话消息提炼成一张知识卡片。

【提炼】消息中的核心知识点/结论/方法/事实，用完整通顺的中文表述。
【标题】20 字以内，概括卡片主题（如「报销发票要求」「Dart Stream 背压处理」）。
【正文】500 字以内，保留关键细节（数字/步骤/条件），不添加消息中没有的信息。
【标签】0~3 个，每个 2~6 字（如 财务/编程/健康），逗号分隔。
【输出】只输出 JSON，禁止输出任何其他文字：
{"title": "卡片标题", "content": "卡片正文", "tags": ["标签1", "标签2"]}''';

  /// 提炼失败后的回喂重试指令（只重试一次，防死循环）
  static const _retryPrompt = '''
上面的输出不是合法 JSON。重新输出：只输出 JSON（格式：
{"title": "卡片标题", "content": "卡片正文", "tags": ["标签1"]}），
禁止输出任何其他文字。''';

  /// 把一条消息沉淀为卡片并入库，返回入库的卡片
  ///
  /// 提炼请求走会话同款供应商与模型（low 档低温）；解析失败回喂重试
  /// 一次；两次都失败回退本地截断（离线/网关异常不阻塞存卡）。
  Future<Card> forge({
    required ChatMessage message,
    required ProviderProfile profile,
    required String model,
    String? sessionId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'card_${now}_'
        '${message.content.length.toString()}'
        '${_randomSuffix()}';

    // 空消息（纯附件等）直接本地回退，不发请求
    final text = message.content.trim();
    if (text.isEmpty) {
      return _persist(Card(
        id: id,
        sessionId: sessionId ?? message.sessionId,
        sourceMessageId: message.id,
        title: '无文字消息',
        content: '',
        createdAt: now,
        updatedAt: now,
      ));
    }

    final first = await _requestJson(profile, model, [
      {'role': 'system', 'content': _systemPrompt},
      {'role': 'user', 'content': text},
    ]);
    CardDraft? parsed = first == null ? null : parseCard(first);
    if (parsed == null && first != null) {
      // 解析失败：回喂重试一次（把坏输出喂回去要求纠正）
      final second = await _requestJson(profile, model, [
        {'role': 'system', 'content': _systemPrompt},
        {'role': 'user', 'content': text},
        {'role': 'assistant', 'content': first},
        {'role': 'user', 'content': _retryPrompt},
      ]);
      parsed = second == null ? null : parseCard(second);
    }

    final Card card;
    if (parsed != null) {
      card = Card(
        id: id,
        sessionId: sessionId ?? message.sessionId,
        sourceMessageId: message.id,
        title: parsed.title,
        content: parsed.content,
        tags: parsed.tags,
        createdAt: now,
        updatedAt: now,
      );
    } else {
      card = _fallbackCard(
        id: id,
        sessionId: sessionId ?? message.sessionId,
        sourceMessageId: message.id,
        text: text,
        now: now,
      );
    }
    return _persist(card);
  }

  Future<Card> _persist(Card card) async {
    await _db.insertCard(card);
    return card;
  }

  /// 本地回退卡片：首行/前 80 字为标题，全文为正文，无标签
  static Card _fallbackCard({
    required String id,
    required String sessionId,
    required String sourceMessageId,
    required String text,
    required int now,
  }) {
    final firstLine = text.split('\n').first.trim();
    final title = firstLine.isNotEmpty
        ? (firstLine.length > 80 ? firstLine.substring(0, 80) : firstLine)
        : (text.length > 80 ? text.substring(0, 80) : text);
    return Card(
      id: id,
      sessionId: sessionId,
      sourceMessageId: sourceMessageId,
      title: title,
      content: text,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 解析模型输出为卡片草稿（null = 无法解析）
  ///
  /// 容错：剥 markdown 围栏、截取首个 `{` 到最后一个 `}`（模型爱在
  /// JSON 外加说明文字）；title/content 截断到上限；tags 最多 3 个。
  static CardDraft? parseCard(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    // markdown 围栏：```json ... ``` / ``` ... ```
    if (text.startsWith('```')) {
      final nl = text.indexOf('\n');
      if (nl < 0) return null;
      text = text.substring(nl + 1);
      final fenceEnd = text.lastIndexOf('```');
      if (fenceEnd >= 0) text = text.substring(0, fenceEnd);
      text = text.trim();
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final title = decoded['title'];
    final content = decoded['content'];
    if (title is! String || content is! String) return null;
    if (title.trim().isEmpty || content.trim().isEmpty) return null;

    final rawTags = decoded['tags'];
    final tags = <String>[
      if (rawTags is List)
        for (final t in rawTags)
          if (t is String && t.trim().isNotEmpty) t.trim(),
    ].take(maxTags).toList();

    return CardDraft(
      title: _clamp(title.trim(), maxTitleLength),
      content: _clamp(content.trim(), maxContentLength),
      tags: tags.isEmpty ? null : tags.join(','),
    );
  }

  /// 按 rune 截断（中文安全，不切半个字符）
  static String _clamp(String text, int max) {
    final runes = text.runes.toList();
    if (runes.length <= max) return text;
    return String.fromCharCodes(runes.sublist(0, max));
  }

  /// 发起一次提炼请求并收集完整输出；失败（网络/服务端错误）返回 null
  Future<String?> _requestJson(
    ProviderProfile profile,
    String model,
    List<Map<String, Object?>> messages,
  ) async {
    final buffer = StringBuffer();
    try {
      await for (final event in _api.chatStream(
        profile: profile,
        messages: messages,
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
      return null; // 提炼失败静默回退，不阻塞存卡
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 随机后缀：同毫秒多次沉淀防 id 碰撞。
  /// 用 Random().nextInt（真随机）而非时钟位——Windows 时钟粒度
  /// ~15ms，连续两次调用 microsecondsSinceEpoch 可能同值，时钟位
  /// 后缀会整体相同 → id 撞车 → replace 覆盖丢卡（CI 实测复现）
  static String _randomSuffix() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random();
    return [for (var i = 0; i < 4; i++) chars[rng.nextInt(chars.length)]].join();
  }
}

/// 提炼出的卡片草稿（入库前中间态）
class CardDraft {
  const CardDraft({
    required this.title,
    required this.content,
    this.tags,
  });

  final String title;
  final String content;
  final String? tags;
}
