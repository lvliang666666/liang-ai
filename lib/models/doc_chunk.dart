/// 文档分块（F8 长文工作台）：PDF 按页提取文本后切出的检索单元
///
/// 派生数据（可由原文件重新索引重建）：不进备份、会话删除级联清理。
/// 检索注入时以「【文件名·第N页】片段」形式进 system，回答引用标注
/// 同格式，UI 解析成来源 chip。
class DocChunk {
  const DocChunk({
    required this.id,
    required this.sessionId,
    required this.docName,
    this.sourcePath = '',
    required this.page,
    this.seq = 0,
    required this.content,
    required this.createdAt,
  });

  /// id 规则：doc_{毫秒时间戳}_{seq}（同文档同毫秒内 seq 唯一即不撞车）
  final String id;
  final String sessionId;

  /// 文档显示名（引用标注用，如「报销制度.pdf」）
  final String docName;

  /// 原文件沙箱路径（引用 Sheet「打开原文件」用；空 = 无原文件）
  final String sourcePath;

  /// 1 起始页码
  final int page;

  /// 同页内块序（0 起；超长页拆块时区分）
  final int seq;
  final String content;
  final int createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'session_id': sessionId,
        'doc_name': docName,
        'source_path': sourcePath,
        'page': page,
        'seq': seq,
        'content': content,
        'created_at': createdAt,
      };

  static DocChunk fromMap(Map<String, Object?> map) => DocChunk(
        id: map['id'] as String,
        sessionId: map['session_id'] as String,
        docName: map['doc_name'] as String,
        sourcePath: (map['source_path'] as String?) ?? '',
        page: (map['page'] as int?) ?? 1,
        seq: (map['seq'] as int?) ?? 0,
        content: map['content'] as String,
        createdAt: (map['created_at'] as int?) ?? 0,
      );

  /// 引用标注文本（注入与回答共用的格式契约）
  String get citation => '【$docName·第$page页】';
}
