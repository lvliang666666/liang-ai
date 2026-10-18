import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/agent.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../services/api_service.dart';
import '../services/database_service.dart';
import '../services/sse_parser.dart';

/// 聊天流式状态
enum ChatStatus { idle, thinking, answering, error }

/// 聊天页状态：消息列表 + 流式状态机
class ChatProvider extends ChangeNotifier {
  ChatProvider({
    required DatabaseService database,
    required ApiService api,
    required ChatSession session,
    required String model,
    Agent? agent,
  })  : _db = database,
        _api = api,
        _session = session,
        _model = model,
        _agent = agent;

  final DatabaseService _db;
  final ApiService _api;
  final ChatSession _session;
  final String _model;

  /// 当前会话绑定的 Agent（null = 默认助手，无 system prompt）
  Agent? _agent;

  List<ChatMessage> _messages = [];
  ChatStatus _status = ChatStatus.idle;
  String _errorMessage = '';

  /// 当前流式中的 assistant 消息（未落库，done 时落库）
  ChatMessage? _streamingMessage;

  CancelToken? _cancelToken;
  StreamSubscription<SseEvent>? _subscription;
  DateTime? _thinkingStart;

  // ===== Getters =====
  ChatSession get session => _session;
  Agent? get agent => _agent;
  List<ChatMessage> get messages => _messages;
  ChatStatus get status => _status;
  String get errorMessage => _errorMessage;
  bool get isStreaming => _status == ChatStatus.thinking || _status == ChatStatus.answering;
  ChatMessage? get streamingMessage => _streamingMessage;

  /// 页面渲染用的完整消息列表（含流式中消息）
  List<ChatMessage> get displayMessages {
    if (_streamingMessage == null) return _messages;
    return [..._messages, _streamingMessage!];
  }

  /// 加载历史消息
  Future<void> loadMessages() async {
    _messages = await _db.getMessages(_session.id);
    notifyListeners();
  }

  /// 发送消息
  Future<void> sendMessage(String text) async {
    final content = text.trim();
    if (content.isEmpty || isStreaming) return;

    _errorMessage = '';
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. 落库 user 消息
    final userMsg = ChatMessage(
      id: _genId(),
      sessionId: _session.id,
      role: 'user',
      content: content,
      createdAt: now,
    );
    await _db.insertMessage(userMsg);
    _messages = [..._messages, userMsg];

    // 首条消息自动生成会话标题
    if (_session.title.isEmpty || _session.title == '新对话') {
      _session.title = content.length > 20 ? content.substring(0, 20) : content;
      await _db.updateSessionTitle(_session.id, _session.title);
    }
    await _db.touchSession(_session.id);

    // 2. 创建流式 assistant 消息
    _streamingMessage = ChatMessage(
      id: _genId(),
      sessionId: _session.id,
      role: 'assistant',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _status = ChatStatus.thinking;
    _thinkingStart = DateTime.now();
    notifyListeners();

    // 3. 发起流式请求（Agent system prompt 插入消息头部）
    _cancelToken = CancelToken();
    final history = _buildApiMessages();

    _subscription = _api
        .chatStream(
      messages: history,
      model: _model,
      effort: _effectiveEffort,
      cancelToken: _cancelToken!,
      temperature: _effectiveTemperature,
    )
        .listen(
      (event) {
        switch (event) {
          case SseDeltaReasoning(:final text):
            _streamingMessage = _streamingMessage!..reasoning += text;
            if (_status == ChatStatus.thinking) notifyListeners();
          case SseDeltaContent(:final text):
            _streamingMessage = _streamingMessage!..content += text;
            _status = ChatStatus.answering;
            notifyListeners();
          case SseDone():
            _finishStreaming();
          case SseError(:final message):
            _failStreaming(message);
        }
      },
      onError: (Object e) {
        if (e is DioException && e.type == DioExceptionType.cancel) {
          _finishStreaming(); // 手动停止：保留已收内容
        } else if (e is ApiException) {
          _failStreaming(e.message);
        } else {
          _failStreaming('请求失败：$e');
        }
      },
      onDone: () {
        if (isStreaming) _finishStreaming();
      },
    );
  }

  /// 停止生成（保留已收内容）
  void stopGeneration() {
    _cancelToken?.cancel();
  }

  /// 正常结束：落库 assistant 消息
  void _finishStreaming() {
    final msg = _streamingMessage;
    if (msg != null) {
      _db.insertMessage(msg);
      _messages = [..._messages, msg];
    }
    _streamingMessage = null;
    _status = ChatStatus.idle;
    _subscription = null;
    _cancelToken = null;
    notifyListeners();
  }

  /// 出错：保留已收内容落库，显示错误
  void _failStreaming(String message) {
    final msg = _streamingMessage;
    if (msg != null && (msg.content.isNotEmpty || msg.reasoning.isNotEmpty)) {
      _db.insertMessage(msg);
      _messages = [..._messages, msg];
    }
    _streamingMessage = null;
    _status = ChatStatus.error;
    _errorMessage = message;
    _subscription = null;
    _cancelToken = null;
    notifyListeners();
  }

  /// 清除错误状态
  void clearError() {
    if (_status == ChatStatus.error) {
      _status = ChatStatus.idle;
      _errorMessage = '';
      notifyListeners();
    }
  }

  /// 切换推理档位
  Future<void> setEffort(String effort) async {
    if (_session.effort == effort) return;
    _session.effort = effort;
    await _db.updateSessionEffort(_session.id, effort);
    notifyListeners();
  }

  /// 切换会话绑定的 Agent（null = 默认助手）
  Future<void> setAgent(Agent? agent) async {
    if (_agent?.id == agent?.id) return;
    _agent = agent;
    await _db.updateSessionAgent(_session.id, agent?.id);
    notifyListeners();
  }

  /// 组装 API 请求消息：Agent system prompt 在头部 + 全部历史
  List<Map<String, Object?>> _buildApiMessages() {
    final prompt = _agent?.prompt;
    return [
      if (prompt != null && prompt.isNotEmpty)
        {'role': 'system', 'content': prompt},
      ..._messages.map((m) => m.toApiMessage()),
    ];
  }

  /// 生效的推理档位：Agent 预设优先于会话设置
  ///
  /// 会话 effort 是用户在聊天中可手动调整的值；Agent 预设只在
  /// 会话仍为初始默认值时生效，用户手动改过则以用户为准。
  String get _effectiveEffort {
    final agentEffort = _agent?.effort;
    if (agentEffort != null && _session.effort == 'max') {
      // 会话未手动调整过（保持默认 max），采用 Agent 预设
      return agentEffort;
    }
    return _session.effort;
  }

  /// 生效的温度：Agent 预设优先（会话级温度暂未开放手动调整）
  double get _effectiveTemperature => _agent?.temperature ?? 0.7;

  /// 思考用时（秒）
  int get thinkingSeconds {
    final start = _thinkingStart;
    if (start == null) return 0;
    return DateTime.now().difference(start).inSeconds;
  }

  String _genId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      (_messages.length.toString());

  @override
  void dispose() {
    _subscription?.cancel();
    _cancelToken?.cancel();
    super.dispose();
  }
}
