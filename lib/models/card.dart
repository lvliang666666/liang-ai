/// 卡片模型：用户从对话中「沉淀」下来的知识卡片（M5 对话炼金炉）
///
/// 与记忆池的区别：卡片由用户主动策展（长按消息 → 沉淀为卡片），
/// 可编辑、可搜索、不参与任何滚动淘汰——是用户的个人知识库条目。
/// 纯本地 SQLite 存储（cards 表，DB v18）。
class Card {
  final String id;

  /// 来源会话（溯源用；会话删除后卡片保留——卡片是独立知识条目）
  final String? sessionId;

  /// 来源消息 id（溯源用，可空：编辑后与原消息解耦）
  final String? sourceMessageId;

  /// 卡片标题（LLM 提炼或用户编辑，≤50 字）
  String title;

  /// 卡片正文（LLM 提炼或用户编辑）
  String content;

  /// 标签（LLM 提炼，≤3 个；逗号分隔存储，LIKE 检索）
  String? tags;

  final int createdAt;
  int updatedAt;

  Card({
    required this.id,
    this.sessionId,
    this.sourceMessageId,
    required this.title,
    required this.content,
    this.tags,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'source_message_id': sourceMessageId,
        'title': title,
        'content': content,
        'tags': tags,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Card.fromMap(Map<String, dynamic> map) => Card(
        id: map['id'] as String,
        sessionId: map['session_id'] as String?,
        sourceMessageId: map['source_message_id'] as String?,
        title: (map['title'] as String?) ?? '',
        content: (map['content'] as String?) ?? '',
        tags: map['tags'] as String?,
        createdAt: (map['created_at'] as int?) ?? 0,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );

  /// 标签列表（逗号分隔存储的解析视图）
  List<String> get tagList => (tags ?? '')
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  Card copyWith({
    String? title,
    String? content,
    String? tags,
    int? updatedAt,
  }) =>
      Card(
        id: id,
        sessionId: sessionId,
        sourceMessageId: sourceMessageId,
        title: title ?? this.title,
        content: content ?? this.content,
        tags: tags ?? this.tags,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
