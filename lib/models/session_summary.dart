/// M4 情景记忆层：会话摘要（标题 + 摘要 + 关键词）
///
/// 每个会话结束时由 [SessionSummaryService] 生成一条，存入
/// session_summaries 表（每会话一条，重写覆盖）。与记忆池（语义记忆）
/// 形成双层：记忆池存「用户是谁」，情景记忆存「聊过什么」——
/// 「上周我们讨论过 X 的结论」这类问题由 search_history 工具检索本表。
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.sessionId,
    required this.title,
    required this.summary,
    required this.keywords,
    required this.createdAt,
  });

  /// 派生 id：`ep_<sessionId>`——每会话一条，重写时同 id replace 覆盖
  static String idFor(String sessionId) => 'ep_$sessionId';

  factory SessionSummary.fromMap(Map<String, dynamic> map) => SessionSummary(
        id: map['id'] as String,
        sessionId: map['session_id'] as String,
        title: (map['title'] as String?) ?? '',
        summary: (map['summary'] as String?) ?? '',
        keywords: SessionSummary._decodeKeywords(map['keywords']),
        createdAt: (map['created_at'] as int?) ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'title': title,
        'summary': summary,
        'keywords': keywords.join(','),
        'created_at': createdAt,
      };

  /// keywords 列存逗号分隔文本（检索用 LIKE，无需 JSON 解析容错）
  static List<String> _decodeKeywords(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) {
      return [
        for (final k in raw.split(','))
          if (k.trim().isNotEmpty) k.trim(),
      ];
    }
    return const [];
  }

  final String id;
  final String sessionId;
  final String title;
  final String summary;
  final List<String> keywords;
  final int createdAt;
}
