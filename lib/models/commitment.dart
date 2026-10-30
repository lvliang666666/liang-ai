/// 承诺模型：从对话中提取的待办/承诺（P3 承诺跟进）
///
/// 与记忆池的区别：记忆是「用户是谁」的长期事实，承诺是「用户说要
/// 做什么」的时间性事项——有到期日、有状态流转（待跟进/已完成/已忽略），
/// 到期未完成时触发一次跟进提醒。
/// 纯本地 SQLite 存储（commitments 表，DB v21）。
class Commitment {
  /// 状态：待跟进（到期未处理）
  static const statusPending = 'pending';

  /// 状态：已完成（用户确认或会话中确认完成）
  static const statusDone = 'done';

  /// 状态：已忽略（用户明确不想被跟进）
  static const statusDismissed = 'dismissed';

  /// 合法状态集合（解析模型输出/备份导入时校验，非法值回退 pending）
  static const validStatuses = {statusPending, statusDone, statusDismissed};

  final String id;

  /// 来源会话（「继续聊」跳转用；会话删除后承诺保留——独立事项）
  final String? sessionId;

  /// 承诺内容（一句话，如「周五前把周报发给组长」）
  String content;

  /// 到期日（yyyy-MM-dd；null = 无明确期限，不参与到期扫描）
  String? dueDate;

  /// 状态流转（[statusPending]/[statusDone]/[statusDismissed]）
  String status;

  /// 跟进语（到期时生成的一句追问，弹 Sheet 时展示；null = 未生成）
  String? followUp;

  /// 跟进语生成日期（yyyy-MM-dd；同一天不重复生成——防打扰）
  String? followUpDate;

  final int createdAt;
  int updatedAt;

  Commitment({
    required this.id,
    this.sessionId,
    required this.content,
    this.dueDate,
    this.status = statusPending,
    this.followUp,
    this.followUpDate,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'content': content,
        'due_date': dueDate,
        'status': status,
        'follow_up': followUp,
        'follow_up_date': followUpDate,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Commitment.fromMap(Map<String, dynamic> map) => Commitment(
        id: map['id'] as String,
        sessionId: map['session_id'] as String?,
        content: (map['content'] as String?) ?? '',
        dueDate: map['due_date'] as String?,
        status: _parseStatus(map['status'] as String?),
        followUp: map['follow_up'] as String?,
        followUpDate: map['follow_up_date'] as String?,
        createdAt: (map['created_at'] as int?) ?? 0,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );

  /// 状态解析容错：非法/缺失值回退 pending（备份导入/手改文件防御）
  static String _parseStatus(String? raw) =>
      validStatuses.contains(raw) ? raw! : statusPending;

  /// 是否已了结（完成或忽略——都不再参与到期扫描）
  bool get isSettled => status != statusPending;

  /// 是否今天到期（[dueDate] 等于今天）
  bool isDueToday(String todayKey) => dueDate == todayKey;

  /// 是否已过期（[dueDate] 早于今天；无期限不算过期）
  bool isOverdue(String todayKey) =>
      dueDate != null && dueDate!.compareTo(todayKey) < 0;

  /// 是否需要跟进（待跟进 + 已过期或今天到期）
  bool needsFollowUp(String todayKey) =>
      status == statusPending &&
      (isOverdue(todayKey) || isDueToday(todayKey));

  Commitment copyWith({
    String? content,
    String? dueDate,
    String? status,
    String? followUp,
    String? followUpDate,
    int? updatedAt,
  }) =>
      Commitment(
        id: id,
        sessionId: sessionId,
        content: content ?? this.content,
        dueDate: dueDate ?? this.dueDate,
        status: status ?? this.status,
        followUp: followUp ?? this.followUp,
        followUpDate: followUpDate ?? this.followUpDate,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
