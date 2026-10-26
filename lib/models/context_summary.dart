/// F2 分层上下文压缩：会话前情摘要
///
/// 会话 token 超水位线后，早期历史被压缩成四段式摘要（关键事实/用户偏好/
/// 已做结论/未决事项）存入 context_summaries 表；请求组装时以 system 消息
/// 注入摘要、只发送边界之后的原文。摘要是派生数据（可由原文重新生成），
/// 不进备份（E1），restore 时清空。
class ContextSummary {
  final String id;
  final String sessionId;

  /// 四段式摘要正文
  final String summary;

  /// 保留窗口首条消息 ID（边界锚点：此消息及之后的原文随请求发送）。
  /// 钉住轮不作为边界——它们单独记录在 [pinnedIds]，边界始终指向
  /// 保留窗口起点，否则钉住轮会把整个压缩区拖回原文区
  final String firstKeptId;

  /// 保留窗口首条消息的 created_at（ID 失效如消息被删时的时间兜底）
  final int firstKeptAt;

  /// 钉住轮内全部消息 ID（JSON 数组；这些消息在边界之前但原文保留，
  /// 请求组装时按此清单捞回）。空 = 无钉住轮
  final List<String> pinnedIds;

  final int createdAt;

  ContextSummary({
    required this.id,
    required this.sessionId,
    required this.summary,
    required this.firstKeptId,
    required this.firstKeptAt,
    this.pinnedIds = const [],
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'summary': summary,
        'first_kept_id': firstKeptId,
        'first_kept_at': firstKeptAt,
        'pinned_ids': pinnedIds,
        'created_at': createdAt,
      };

  factory ContextSummary.fromMap(Map<String, dynamic> map) => ContextSummary(
        id: map['id'] as String,
        sessionId: (map['session_id'] as String?) ?? '',
        summary: (map['summary'] as String?) ?? '',
        firstKeptId: (map['first_kept_id'] as String?) ?? '',
        firstKeptAt: (map['first_kept_at'] as int?) ?? 0,
        pinnedIds: (map['pinned_ids'] as List<Object?>?)
                ?.whereType<String>()
                .toList() ??
            const [],
        createdAt: (map['created_at'] as int?) ?? 0,
      );
}
