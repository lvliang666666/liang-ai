import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../models/chat_message.dart';
import '../../models/message_attachment.dart';
import '../../models/provider_profile.dart';
import '../../models/agent.dart' as agent_model;
import '../../pages/payload_lens_page.dart';
import '../../providers/chat_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/attachment_service.dart';
import '../../services/settings_service.dart';
import '../../utils/haptics.dart';
import '../../utils/transitions.dart';
import '../app_toast.dart';
import '../app_bottom_sheet.dart';
import '../attachment_thumbnail.dart';
import '../chat_input_bar.dart';
import '../chat_tags_bar.dart';
import '../token_usage_sheet.dart';
import 'slash_command_sheet.dart';

/// 主页底部输入区：tags 行（agent/model/effort）+ 输入框 + 附件 + 发送键
///
/// 双态共用：
/// - 空闲态（chat == null）：tags 显示预选值，发送 = 创建会话进入聊天态
/// - 聊天态（chat != null）：tags 显示会话绑定值，发送 = ChatProvider.sendMessage
///
/// 附件：聊天态直接入 ChatProvider 待发队列；空闲态暂存本组件，
/// 随首条消息经 onSendIdle 传入新会话。
class HomeInputBar extends StatefulWidget {
  const HomeInputBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.chat,
    required this.selectedAgent,
    required this.selectedModel,
    required this.selectedEffort,
    required this.onSendIdle,
    required this.onPickAgent,
    required this.onPickModel,
    required this.onPickEffort,
    this.onPickDual,
    this.editingMessage,
    this.onCancelEdit,
    this.quotedMessage,
    this.onCancelQuote,
    this.capsuleCollapsed,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 聊天态的 ChatProvider（null = 空闲态）
  final ChatProvider? chat;
  final agent_model.Agent? selectedAgent;
  final (ProviderProfile, String)? selectedModel;

  /// 空闲态预选推理档位（effort tag 空闲态也显示）
  final String selectedEffort;

  /// 空闲态发送（创建会话），附件随首条消息传入
  final void Function(String text,
      {String? agentId,
      (ProviderProfile, String)? modelPick,
      List<MessageAttachment> attachments}) onSendIdle;
  final VoidCallback onPickAgent;
  final VoidCallback onPickModel;
  final VoidCallback onPickEffort;

  /// F6 同问双答：双答 tag 点击（弹对侧供应商选择 sheet；null = 不显示）
  final VoidCallback? onPickDual;

  /// 编辑态（I4）：正在编辑的 user 消息（null = 非编辑态）。
  /// 编辑态下发送走编辑重发管线而非普通发送。
  final ChatMessage? editingMessage;

  /// 取消编辑（编辑态右上角 ×）
  final VoidCallback? onCancelEdit;

  /// 引用态（I5）：被引用的 assistant 消息（null = 无引用）。
  /// 引用随下一条消息发出后自动清除。
  final ChatMessage? quotedMessage;

  /// 取消引用（引用条右侧 ×）
  final VoidCallback? onCancelQuote;

  /// I9 胶囊行收纳信号（true = 收起 tags 行；null = 不收纳，常显）。
  /// 聊天态由 ChatMessageList 的滚动方向驱动，空闲态不传（无列表可滚）。
  final ValueListenable<bool>? capsuleCollapsed;

  @override
  State<HomeInputBar> createState() => _HomeInputBarState();
}

class _HomeInputBarState extends State<HomeInputBar> {
  final _picker = ImagePicker();

  /// 空闲态暂存的待发附件（聊天态附件直接进 ChatProvider）
  List<MessageAttachment> _idleAttachments = [];

  /// 文件附件沙箱目录异步初始化（就绪前选取的文件不保存原文件）
  AttachmentService _attachmentService = const AttachmentService();

  /// 空闲态草稿防抖保存（I6）：停顿 800ms 才落盘，避免每键一写 prefs
  Timer? _idleDraftDebounce;

  /// F9 剪贴板胶囊：检测到的剪贴板长文本（null = 无可提示内容）。
  /// 记录已提示过的文本——同一段内容只提示一次（复制→粘贴→再聚焦不重弹）
  String? _clipboardCandidate;
  String? _lastPromptedClipboard;

  /// 剪贴板胶囊触发阈值（字符数）：短文本用户自己粘贴更顺手
  static const int _clipboardThreshold = 200;

  @override
  void initState() {
    super.initState();
    _initAttachmentStorage();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _idleDraftDebounce?.cancel();
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  /// F9 剪贴板胶囊：聚焦时检测剪贴板长文本。
  /// 只在聚焦瞬间检测（不轮询不监听系统剪贴板事件——Android 无该 API），
  /// 输入框已有内容/流式中不提示（避免打扰正在进行的操作）
  Future<void> _onFocusChanged() async {
    if (!widget.focusNode.hasFocus) return;
    if (!mounted) return;
    // 开关关闭（设置页「剪贴板建议」）→ 不检测
    if (!context.read<SettingsService>().clipboardSuggestion) return;
    // 输入框已有内容 → 不打扰
    if (widget.controller.text.trim().isNotEmpty) return;
    if (widget.chat?.isStreaming ?? false) return;
    final text = await Clipboard.getData('text/plain')
        .then((d) => d?.text)
        .catchError((_) => null);
    if (!mounted || !widget.focusNode.hasFocus) return;
    if (text == null || text.trim().length < _clipboardThreshold) {
      setState(() => _clipboardCandidate = null);
      return;
    }
    // 同一段内容只提示一次
    if (text == _lastPromptedClipboard) {
      setState(() => _clipboardCandidate = null);
      return;
    }
    setState(() => _clipboardCandidate = text);
  }

  /// F9 剪贴板胶囊：点击「帮你总结？」→ 预填文本 + 关闭胶囊
  void _useClipboardText() {
    final text = _clipboardCandidate;
    if (text == null) return;
    Haptics.light();
    widget.controller.text = text;
    widget.controller.selection =
        TextSelection.collapsed(offset: text.length);
    setState(() {
      _lastPromptedClipboard = text;
      _clipboardCandidate = null;
    });
  }

  /// F9 剪贴板胶囊：关闭（本次不再提示该内容）
  void _dismissClipboard() {
    setState(() {
      _lastPromptedClipboard = _clipboardCandidate;
      _clipboardCandidate = null;
    });
  }

  /// 上一次输入是否以「/」开头（斜杠面板边沿触发用）
  bool _slashWasActive = false;

  /// 输入变化：空闲态防抖存草稿（聊天态草稿在切换/发送时机存，不逐键写）；
  /// 输入「/」唤起斜杠命令面板（I12）
  void _onInputChanged(String text) {
    setState(() {});
    if (widget.chat == null) {
      _idleDraftDebounce?.cancel();
      _idleDraftDebounce = Timer(const Duration(milliseconds: 800), () {
        context.read<SettingsService>().setIdleDraft(text.trim());
      });
    }
    // I12 斜杠命令：**边沿触发**——只在「无 / → 有 /」跳变时唤起面板。
    // 电平触发（startsWith 就弹）会导致删除时每删一个 / 都重弹一次
    // （用户验收反馈：删 / 不应弹，只有输入 / 才弹）。面板自带搜索框，
    // 输入框文本不参与过滤。
    final slashActive = text.startsWith('/');
    if (slashActive && !_slashWasActive) {
      _openSlashCommands();
    }
    _slashWasActive = slashActive;
  }

  /// I12 斜杠命令面板：快捷短语填入（Agent 切换走输入栏 tag，不进面板）
  Future<void> _openSlashCommands() async {
    final settings = context.read<SettingsService>();

    // 先收键盘，**等键盘完全收起后再弹面板**：面板的键盘适配层
    // （SheetKeyboardInset）会把面板顶到键盘上沿——若键盘还在收起
    // 动画中就弹面板，面板先顶在高处、随键盘回落一截，「弹出又回
    // 退」很丑（用户两轮验收反馈）。轮询 viewInsets 直到归零（32ms
    // 步进，600ms 上限防慢 IME 卡死）；无键盘在场时零等待直接弹。
    widget.focusNode.unfocus();
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      var waited = 0;
      while (mounted &&
          MediaQuery.viewInsetsOf(context).bottom > 0 &&
          waited < 600) {
        await Future.delayed(const Duration(milliseconds: 32));
        waited += 32;
      }
      if (!mounted) return;
      // 等待期间「/」可能已被删掉：放弃弹出并重置边沿状态
      //（否则下次输入 / 会被误判为「有 → 有」而不弹）
      if (!widget.controller.text.startsWith('/')) {
        _slashWasActive = false;
        return;
      }
    }

    final result = await showAppBottomSheet<String>(
      context: context,
      builder: (context) => SlashCommandSheet(
        settings: settings,
        onSelectPhrase: (p) => Navigator.pop(context, p),
        onDeletePhrase: (p) => settings.removeSlashPhrase(p),
      ),
    );
    if (!mounted) return;

    if (result is String) {
      // 选短语：替换输入框内容为短语（「/」前缀一并清掉）
      widget.controller
        ..clear()
        ..text = result;
      widget.controller.selection =
          TextSelection.collapsed(offset: result.length);
      _slashWasActive = false; // 短语无 / 前缀，重置边沿状态
      return;
    }
    // 点遮罩关闭：保留输入框原样（用户可能继续输入）。此时文本仍以
    // / 开头，_slashWasActive 保持 true——继续删 / 不会重弹（边沿
    // 触发语义：只有「无 → 有」跳变才弹）。
  }

  /// 文件附件沙箱目录（应用文档目录/attachments）
  Future<void> _initAttachmentStorage() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      if (mounted) {
        setState(() {
          _attachmentService = AttachmentService(
            storageDir: Directory(p.join(docs.path, 'attachments')),
          );
        });
      }
    } catch (_) {
      // 目录不可用时保持默认（不保存原文件，仅提取文本）
    }
  }

  /// 当前生效的待发附件（聊天态取 provider 队列，空闲态取本地暂存）
  List<MessageAttachment> get _pendingAttachments {
    final chat = widget.chat;
    if (chat != null) return chat.pendingAttachments;
    return _idleAttachments;
  }

  bool get _hasPendingAttachments => _pendingAttachments.isNotEmpty;

  /// 添加附件（图片 ≤3、文件 ≤3，超限返回 false）
  bool _addAttachment(MessageAttachment attachment) {
    final chat = widget.chat;
    if (chat != null) return chat.addAttachment(attachment);
    final images = _idleAttachments.where((a) => a.isImage).length;
    final files = _idleAttachments.where((a) => a.isFile).length;
    if (attachment.isImage && images >= 3) return false;
    if (attachment.isFile && files >= 3) return false;
    _idleAttachments = [..._idleAttachments, attachment];
    return true;
  }

  /// 移除待发附件
  void _removeAttachment(MessageAttachment attachment) {
    final chat = widget.chat;
    if (chat != null) {
      chat.removeAttachment(attachment);
      return;
    }
    setState(() {
      _idleAttachments = [
        for (final a in _idleAttachments)
          if (!identical(a, attachment)) a,
      ];
    });
  }

  /// 附件来源选择：拍照 / 相册 / 文件
  Future<void> _pickAttachment() async {
    Haptics.light();
    // 打开弹层前收起键盘，避免弹层关闭时焦点自动回到输入框
    FocusManager.instance.primaryFocus?.unfocus();
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('添加附件'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('相册（最多 3 张）'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('文件（txt / md / pdf，最多 3 个）'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    try {
      switch (action) {
        case 'camera':
          final xfile = await _picker.pickImage(
            source: ImageSource.camera,
            maxWidth: 1024,
            maxHeight: 1024,
            imageQuality: 85,
          );
          if (xfile == null) return;
          final bytes = await xfile.readAsBytes();
          _addOrWarn(
              _attachmentService.imageAttachment(xfile.name, bytes));
        case 'gallery':
          final xfile = await _picker.pickImage(
            source: ImageSource.gallery,
            maxWidth: 1024,
            maxHeight: 1024,
            imageQuality: 85,
          );
          if (xfile == null) return;
          final bytes = await xfile.readAsBytes();
          _addOrWarn(
              _attachmentService.imageAttachment(xfile.name, bytes));
        case 'file':
          final result = await _pickFileWithFallback();
          if (result == null) return;
          final (name, bytes) = result;
          _addOrWarn(await _attachmentService.fileAttachment(name, bytes));
      }
    } on AttachmentException catch (e) {
      if (mounted) {
        showAppToast(context, e.message);
      }
    } catch (_) {
      if (mounted) {
        showAppToast(context, '添加附件失败');
      }
    }
  }

  void _addOrWarn(MessageAttachment attachment) {
    final ok = _addAttachment(attachment);
    if (!ok && mounted) {
      Haptics.medium();
      showAppToast(context, '图片最多 3 张、文件最多 3 个');
      return;
    }
    // 空闲态附件存本地列表（聊天态由 provider notifyListeners 驱动重建），
    // 不 setState 的话预览条要等下次输入文字才渲染出来
    if (widget.chat == null && ok) {
      setState(() {});
    }
  }

  /// 文件选取：file_picker 13.x 静态 API（真机）；环境不支持时提示
  Future<(String, Uint8List)?> _pickFileWithFallback() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'md', 'pdf'],
      );
      if (result.isEmpty) return null;
      final f = result.single;
      final bytes = await f.readAsBytes();
      return (f.name, bytes);
    } on PlatformException {
      if (mounted) {
        showAppToast(context, '当前环境不支持文件选择');
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    // 聊天态订阅 ChatProvider：附件入队/移除、流式状态变化即时反映到输入栏
    // （单页架构下 ChatProvider 不在 Provider 树，只能 ListenableBuilder 订阅实例）
    if (chat != null) {
      return ListenableBuilder(
        listenable: chat,
        builder: (context, _) => _buildInput(context, chat),
      );
    }
    return _buildInput(context, null);
  }

  Widget _buildInput(BuildContext context, ChatProvider? chat) {
    final theme = Theme.of(context);
    final inChat = chat != null;
    final isStreaming = chat?.isStreaming ?? false;
    // 主题圆角：Minecraft（0）等硬边框风格下输入框不再套圆角胶囊外框
    final radius = context.watch<ThemeProvider>().cornerRadius;
    final rounded = radius > 0;

    // I4 编辑态 / I5 引用态
    final editing = widget.editingMessage;
    final quoted = widget.quotedMessage;

    // 附件按钮显隐：供应商支持视觉能力（空闲态无会话，默认显示）
    final showAttachmentButton = inChat ? chat.supportsVision : true;
    final pending = _pendingAttachments;

    // 豆包式右侧动作区：流式中显示停止键；有文字/待发附件/编辑态显示发送键
    //（覆盖 +）；否则只显示 +
    final hasText = widget.controller.text.trim().isNotEmpty;
    final showSend = isStreaming || hasText || pending.isNotEmpty || editing != null;
    final showPlus = !isStreaming && !hasText && showAttachmentButton;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // tags 行：独立于输入框（agent / model / effort）。
          // I9 收纳：聊天态随滚动方向收起/展开（AnimatedSize 平滑过渡，
          // 收起时高度归零 + 淡出）；空闲态无滚动列表，常显不收纳
          if (widget.capsuleCollapsed != null)
            ValueListenableBuilder<bool>(
              valueListenable: widget.capsuleCollapsed!,
              builder: (context, collapsed, _) => AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: collapsed
                    ? const SizedBox(width: double.infinity)
                    : _buildTagsRow(context, chat),
              ),
            )
          else
            _buildTagsRow(context, chat),
          const SizedBox(height: 6),
          // F9 剪贴板胶囊：聚焦 + 剪贴板有长文本时浮出（输入框上方）
          if (_clipboardCandidate != null)
            _ClipboardSuggestionBar(
              preview: _clipboardCandidate!,
              onUse: _useClipboardText,
              onDismiss: _dismissClipboard,
            ),
          // 浮起输入框：圆角主题（默认/DeepSeek）外层容器即唯一输入框（豆包式）；
          // 直角主题（Minecraft）无外框，内层填充为输入区域
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(rounded ? 28 : 0),
              border: rounded
                  ? Border.all(
                      color: theme.colorScheme.outlineVariant
                          .withValues(alpha: 0.5),
                      width: 0.5,
                    )
                  : null,
              boxShadow: rounded
                  ? [
                      BoxShadow(
                        color:
                            theme.colorScheme.shadow.withValues(alpha: 0.08),
                        blurRadius: 12,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // I4 编辑态条：正在编辑的原文预览 + 取消
                if (editing != null)
                  _EditQuoteBar(
                    icon: Icons.edit_outlined,
                    label: '正在编辑',
                    text: editing.content,
                    onClose: widget.onCancelEdit,
                  ),
                // I5 引用条：被引用原文缩略 + 取消
                if (quoted != null)
                  _EditQuoteBar(
                    icon: Icons.format_quote_outlined,
                    label: '引用',
                    text: quoted.content,
                    onClose: widget.onCancelQuote,
                  ),
                // 待发附件预览条
                if (pending.isNotEmpty)
                  HomeAttachmentPreview(
                    pending: pending,
                    onRemove: _removeAttachment,
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        // 默认一行，内容多时向上扩展，最多 5 行
                        maxLines: 5,
                        minLines: 1,
                        // 仅点击输入框才聚焦（不自动请求焦点，防状态切换乱弹键盘）
                        canRequestFocus: true,
                        textInputAction: TextInputAction.newline,
                        onChanged: _onInputChanged,
                        style:
                            theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                        // 豆包式：圆角主题（默认/DeepSeek）内层完全透明，
                        // 只保留外层容器作为唯一输入框，文字自然摆放；
                        // 直角主题（Minecraft）保留内层填充作为输入区域
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: rounded ? 4 : 14, vertical: 10),
                          filled: !rounded,
                          fillColor: theme
                              .colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          border: rounded
                              ? InputBorder.none
                              : OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(radius + 6),
                                  borderSide: BorderSide.none,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // 右侧动作区：+ 与 发送/停止
                    if (showPlus)
                      IconButton(
                        onPressed: _pickAttachment,
                        icon: Icon(Icons.add_circle_outline,
                            size: 28, color: theme.colorScheme.onSurfaceVariant),
                        tooltip: '添加附件',
                      ),
                    if (isStreaming)
                      IconButton.filled(
                        onPressed: () {
                          Haptics.medium();
                          chat!.stopGeneration();
                        },
                        style: IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.errorContainer,
                        ),
                        icon: Icon(Icons.stop_rounded,
                            color: theme.colorScheme.onErrorContainer),
                      )
                    else if (showSend)
                      ValueListenableBuilder(
                        valueListenable: widget.controller,
                        builder: (context, value, _) {
                          final canSend = value.text.trim().isNotEmpty ||
                              _hasPendingAttachments;
                          return IconButton.filled(
                            onPressed:
                                canSend ? () => _send(context) : null,
                            icon: const Icon(Icons.arrow_upward_rounded),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// tags 行内容（agent / model / effort / token 标签）。
  /// I9 收纳动画的展开态内容；空闲态直接渲染。
  Widget _buildTagsRow(BuildContext context, ChatProvider? chat) {
    final inChat = chat != null;
    final currentAgent = inChat ? chat.agent : widget.selectedAgent;
    final agentLabel = currentAgent != null ? currentAgent.name : '默认助手';
    final agentEmoji = currentAgent?.icon;
    final modelLabel =
        inChat ? chat.model : (widget.selectedModel?.$2 ?? '默认模型');
    final effortValue = inChat ? chat.session.effort : widget.selectedEffort;
    final effortLabel = effortLabels[effortValue]?.$1 ?? effortValue;
    return ChatTagsBar(tags: [
      ChatTag(
        emoji: agentEmoji,
        icon: agentEmoji == null ? Icons.smart_toy_outlined : null,
        label: agentLabel,
        onTap: widget.onPickAgent,
      ),
      ChatTag(
        icon: Icons.tune,
        label: modelLabel,
        onTap: widget.onPickModel,
      ),
      ChatTag(
        icon: Icons.bolt,
        label: effortLabel,
        onTap: widget.onPickEffort,
      ),
      // F3 Token 水位仪表盘：仅聊天态显示，label = 会话累计 token
      if (inChat)
        ChatTag(
          icon: Icons.data_usage,
          label: formatTokenCount(chat.totalTokens),
          onTap: () => _openTokenUsageSheet(context, chat),
        ),
      // F6 同问双答：仅聊天态显示。双答进行中显示「双答中…」并禁点；
      // 待选择态隐藏（选择走气泡上的「用这个继续」按钮）
      if (inChat && widget.onPickDual != null && !chat.isAwaitingDualChoice)
        ChatTag(
          icon: Icons.compare_arrows,
          label: chat.isDualRunning ? '双答中…' : '双答',
          onTap: chat.isDualRunning || chat.isStreaming
              ? () {}
              : widget.onPickDual!,
        ),
    ]);
  }

  void _send(BuildContext context) {
    final text = widget.controller.text.trim();
    final pending = _pendingAttachments;
    final editing = widget.editingMessage;
    final quoted = widget.quotedMessage;
    final chat = widget.chat;

    // I4 编辑态：发送 = 编辑重发（截断 + 重新生成），不走普通发送
    if (editing != null) {
      if (text.isEmpty) return;
      chat?.editAndResend(editing, text);
      context.read<SettingsService>().clearDraft(chat!.session.id);
      widget.controller.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }

    // I5 引用态：引用内容以「【引用】」块拼进消息正文（纯文本方案，
    // 模型自然读到上下文，零 API 改动）
    final composed = quoted != null
        ? '【引用】${quoted.content}\n\n$text'
        : text;
    if (composed.trim().isEmpty && pending.isEmpty) return;
    if (chat != null) {
      // 聊天态：附件已在 provider 队列，直接发；草稿随发送清除（I6）
      chat.sendMessage(composed);
      context.read<SettingsService>().clearDraft(chat.session.id);
    } else {
      // 空闲态：创建会话进入聊天态，附件随首条消息传入；空闲草稿清除（I6）
      final attachments = _idleAttachments;
      setState(() => _idleAttachments = []);
      context.read<SettingsService>().setIdleDraft('');
      widget.onSendIdle(
        composed,
        agentId: widget.selectedAgent?.id,
        modelPick: widget.selectedModel,
        attachments: attachments,
      );
    }
    widget.controller.clear();
    // 发送后收起键盘（微信式：发送即收起，不残留焦点）
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// F3 Token 用量详情 Sheet（tags 行 token 标签点击入口）
  Future<void> _openTokenUsageSheet(
      BuildContext context, ChatProvider chat) async {
    Haptics.light();
    FocusManager.instance.primaryFocus?.unfocus();
    await showTokenUsageSheet(
      context,
      chat,
      onOpenPayload: () {
        Navigator.pop(context);
        Navigator.push(
          context,
          slideUpRoute(PayloadLensPage(chat: chat)),
        );
      },
    );
  }
}

/// I4 编辑态 / I5 引用态条：图标 + 标签 + 原文缩略（单行省略）+ 关闭键
class _EditQuoteBar extends StatelessWidget {
  const _EditQuoteBar({
    required this.icon,
    required this.label,
    required this.text,
    this.onClose,
  });

  final IconData icon;
  final String label;
  final String text;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close,
                size: 16, color: colorScheme.onSurfaceVariant),
            tooltip: '取消',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// F9 剪贴板建议胶囊：聚焦时检测到剪贴板长文本 → 输入框上方浮出。
/// 「帮你总结？」点击预填全文；× 关闭（同段内容不再提示）
class _ClipboardSuggestionBar extends StatelessWidget {
  const _ClipboardSuggestionBar({
    required this.preview,
    required this.onUse,
    required this.onDismiss,
  });

  /// 剪贴板全文（预填用；UI 只显示首行缩略）
  final String preview;
  final VoidCallback onUse;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final firstLine =
        preview.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty,
            orElse: () => preview.trim());
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.content_paste_go,
              size: 14, color: colorScheme.onPrimaryContainer),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              firstLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: onUse,
            child: Text(
              '帮你总结？',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close,
                size: 16, color: colorScheme.onSurfaceVariant),
            tooltip: '关闭',
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// 主页待发附件预览条（横向滚动缩略图 + 文件卡片）
class HomeAttachmentPreview extends StatelessWidget {
  const HomeAttachmentPreview({super.key, required this.pending, required this.onRemove});

  final List<MessageAttachment> pending;
  final void Function(MessageAttachment) onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pending.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final att = pending[index];
          return Stack(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: colorScheme.outlineVariant, width: 0.5),
                ),
                child: att.isImage
                    ? AttachmentThumbnail(
                        base64: att.base64Data ?? '',
                        size: 72,
                        borderRadius: 10,
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.description_outlined,
                              size: 26, color: colorScheme.primary),
                          const SizedBox(height: 4),
                          Text(
                            att.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 9),
                          ),
                        ],
                      ),
              ),
              // 移除按钮
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () {
                    Haptics.light();
                    onRemove(att);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: colorScheme.outlineVariant, width: 0.5),
                    ),
                    child: Icon(Icons.close,
                        size: 14, color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
