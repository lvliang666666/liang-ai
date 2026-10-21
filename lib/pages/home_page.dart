import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/chat_session.dart';
import '../models/message_attachment.dart';
import '../models/provider_profile.dart';
import '../models/skill.dart' as skill_model;
import '../providers/chat_provider.dart';
import '../providers/provider_provider.dart';
import '../providers/sessions_provider.dart';
import '../providers/skill_provider.dart';
import '../providers/theme_provider.dart';
import '../services/api_service.dart';
import '../services/attachment_service.dart';
import '../services/database_service.dart';
import '../services/memory_service.dart';
import '../services/settings_service.dart';
import '../utils/haptics.dart';
import '../utils/transitions.dart';
import '../widgets/attachment_thumbnail.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/chat_tags_bar.dart';
import '../widgets/message_appear.dart';
import '../widgets/message_bubble.dart';
import '../widgets/pressable.dart';
import 'settings_page.dart';

/// 首页：DeepSeek 风格单页架构——主页即聊天页
///
/// 两种状态：
/// - 空闲态：问候语 + tags 行 + 输入框（发送时才创建会话）
/// - 聊天态：header 显示会话标题 + 消息列表 + 同一套输入区（tags 随会话）
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _chatScrollController = ScrollController();
  int _lastDisplayCount = 0;

  /// 抽屉批量管理模式开关（长按菜单「批量管理」触发）
  final ValueNotifier<bool> _drawerBatchMode = ValueNotifier(false);

  // 聊天态：当前会话的 ChatProvider（null = 空闲态）
  ChatProvider? _chat;

  // 空闲态的预选状态（tags 行展示与切换）
  skill_model.Skill? _selectedSkill; // null = 默认助手
  (ProviderProfile, String)? _selectedModel; // null = 用默认供应商默认模型

  // 空闲态预选推理档位（effort tag 空闲态也显示）
  String _selectedEffort = 'max';

  @override
  void initState() {
    super.initState();
    context.read<SessionsProvider>().loadSessions();
    // 启动即加载 Skill 列表：否则 tags 行的 Skill 图标在首次懒加载前显示兜底 emoji
    context.read<SkillProvider>().load();
    // 聚焦根治：键盘收起（ViewInsets 归零）时自动退出聚焦。
    // 场景：用户点输入框聚焦 → 点 tag 弹层（键盘收起）→ 弹层关闭后
    // FocusScope 会把焦点还给输入框并重新弹键盘——监听键盘收起主动
    // unfocus，保证「键盘收起 = 退出聚焦」，弹层关闭不再回弹。
    WidgetsBinding.instance.addObserver(_KeyboardDismissObserver(this));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_KeyboardDismissObserver(this));
    _inputController.dispose();
    _inputFocusNode.dispose();
    _chatScrollController.dispose();
    _drawerBatchMode.dispose();
    _chat?.dispose();
    _chat = null;
    super.dispose();
  }

  /// 导航前收起键盘，避免返回主页时自动弹键盘
  void _unfocus() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 按时段问候语
  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5) return '夜深了';
    if (hour < 11) return '早上好';
    if (hour < 13) return '中午好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  // ===== 滚动跟随（与原聊天页同逻辑） =====
  void _maybeAutoScroll(int newCount) {
    if (!_chatScrollController.hasClients) return;
    if (newCount != _lastDisplayCount) {
      final isNewMessage = newCount > _lastDisplayCount;
      _lastDisplayCount = newCount;
      if (isNewMessage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_chatScrollController.hasClients) {
            _chatScrollController.jumpTo(0);
          }
        });
      }
    } else if (_chatScrollController.offset <= 0.5) {
      _chatScrollController.jumpTo(0);
    }
  }

  /// 打开即聊：发送首条消息时才创建会话，主页原地进入聊天态
  Future<void> _startChat(String text,
      {String? skillId,
      (ProviderProfile, String)? modelPick,
      List<MessageAttachment> attachments = const []}) async {
    Haptics.light();
    _unfocus();

    final settings = context.read<SettingsService>();
    // 记录最近使用（LRU），供下次选择页展示
    if (skillId != null) {
      await settings.touchRecentSkill(skillId);
      if (!mounted) return;
    }
    final sessions = context.read<SessionsProvider>();
    final session = await sessions.createSession(
      _selectedEffort, // 空闲态预选档位随会话创建
      skillId: skillId,
      providerId: modelPick?.$1.id,
      model: modelPick?.$2,
    );
    if (!mounted) return;

    // 主页原地进入聊天态并自动发送首条消息（附件随首条消息发出）
    await _enterChat(session,
        initialMessage: text, initialAttachments: attachments);
  }

  /// 进入聊天态：构建 ChatProvider 并加载消息
  Future<void> _enterChat(ChatSession session,
      {String? initialMessage,
      List<MessageAttachment> initialAttachments = const []}) async {
    // 已有聊天态先释放（切换会话）：先置空再 dispose
    final old = _chat;
    _chat = null;
    old?.dispose();

    final db = DatabaseService.instance;
    final s = await db.getSession(session.id);
    final profiles = await db.getAllProviders();
    if (!mounted) return;
    if (s == null || profiles.isEmpty) return;

    ProviderProfile profile;
    if (s.providerId != null) {
      profile = profiles.firstWhere(
        (p) => p.id == s.providerId,
        orElse: () => profiles.first,
      );
    } else {
      profile = profiles.first;
    }

    final skill = context.read<SkillProvider>().byId(s.skillId);
    final chat = ChatProvider(
      database: db,
      api: ApiService(baseUrl: profile.baseUrl, apiKey: profile.apiKey),
      session: s,
      profile: profile,
      model: s.model?.isNotEmpty == true ? s.model! : profile.defaultModel,
      skill: skill,
      memory: MemoryService(database: db),
    )..loadMessages();
    setState(() {
      _chat = chat;
      _lastDisplayCount = 0;
    });

    // 自动发送首条消息（等首帧完成）；附件先入队再发送
    final initial = initialMessage ?? '';
    if (initial.isNotEmpty || initialAttachments.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final att in initialAttachments) {
          chat.addAttachment(att);
        }
        chat.sendMessage(initial);
      });
    }
  }

  /// 新增对话：预设弹窗（预选 skill/model）→ 仅点「开始新对话」才退出当前聊天态
  ///
  /// 两态统一：都直接弹预设弹窗（聊天态初始值取当前会话配置，新对话从
  /// 当前设置延续）；点遮罩关闭/取消 = 回到点新建之前的状态，
  /// 不退出聊天、不改预选。
  Future<void> _newChat() async {
    Haptics.light();
    _unfocus();

    // 预设交互页：预选本次新对话的 skill / model（力度不加，走 tags 预选）
    final skillsProvider = context.read<SkillProvider>();
    if (!skillsProvider.loaded) await skillsProvider.load();
    if (!mounted) return;
    final providersProvider = context.read<ProviderProvider>();
    if (!providersProvider.loaded) await providersProvider.load();
    if (!mounted) return;

    final chat = _chat;
    final preset = await showModalBottomSheet<(skill_model.Skill?, (ProviderProfile, String)?)>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _NewChatPresetSheet(
        skills: skillsProvider,
        providers: providersProvider,
        recentIds: context.read<SettingsService>().recentSkillIds,
        initialSkill: chat?.skill ?? _selectedSkill,
        initialModel: chat != null ? (chat.profile, chat.model) : _selectedModel,
      ),
    );
    // 点遮罩关闭/取消：什么都不做，保持点新建之前的状态
    if (preset == null || !mounted) return;

    // 仅确认「开始新对话」才应用预选并退出当前聊天态
    final (skill, model) = preset;
    setState(() {
      _selectedSkill = skill?.id == '__default__' ? null : skill;
      _selectedModel = model;
    });
    if (_selectedSkill != null) {
      await context.read<SettingsService>().touchRecentSkill(_selectedSkill!.id);
      if (!mounted) return;
    }

    final current = _chat;
    if (current != null) {
      if (current.isStreaming) current.stopGeneration();
      // 先置空再 dispose：避免 dispose 后 provider 仍被 UI 引用
      setState(() {
        _chat = null;
        _lastDisplayCount = 0;
      });
      current.dispose();
    }
    context.read<SessionsProvider>().refresh();
  }

  /// 抽屉点历史会话：主页切换到该会话（聊天态）
  Future<void> _openChat(String id) async {
    Haptics.light();
    _unfocus();
    final sessions = context.read<SessionsProvider>();
    final session = sessions.sessions.where((s) => s.id == id).firstOrNull;
    if (session == null) return;
    await _enterChat(session);
  }

  /// 删除当前聊天态的会话（header 删除按钮）：退出聊天态
  Future<void> _deleteCurrentChat() async {
    final chat = _chat;
    if (chat == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: const Text('删除后聊天记录无法恢复，确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, true);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (chat.isStreaming) chat.stopGeneration();
    await context.read<SessionsProvider>().deleteSession(chat.session.id);
    if (!mounted) return;
    setState(() => _chat = null);
    chat.dispose();
  }


  Future<void> _renameSession(BuildContext context, String id, String current) async {
    final controller = TextEditingController(text: current);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(hintText: '会话名称'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, controller.text.trim());
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newTitle != null && newTitle.isNotEmpty && newTitle != current) {
      if (context.mounted) {
        context.read<SessionsProvider>().renameSession(id, newTitle);
      }
    }
  }

  Future<void> _deleteSession(BuildContext context, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: const Text('删除后聊天记录无法恢复，确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, true);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      context.read<SessionsProvider>().deleteSession(id);
    }
  }

  /// 长按会话卡片：锚点菜单栏（重命名/删除/批量管理）
  ///
  /// [pressPosition] = 长按点的全局坐标，菜单锚定在该处弹出（微信/桌面右键菜单风格）
  Future<void> _showSessionActions(
      BuildContext context, String id, String title, Offset pressPosition) async {
    Haptics.medium();
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final box = overlay.size;
    // 菜单估算尺寸：3 项（44 高）+ divider ≈ 145 高，宽约 160
    const menuWidth = 160.0;
    const menuHeight = 145.0;
    // 锚定长按点，超出屏幕右/下边界时向内收
    var left = pressPosition.dx;
    var top = pressPosition.dy;
    if (left + menuWidth > box.width) left = box.width - menuWidth - 8;
    if (top + menuHeight > box.height) top = box.height - menuHeight - 8;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        left, top, box.width - left - menuWidth, box.height - top - menuHeight,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        const PopupMenuItem(
          value: 'rename',
          height: 44,
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 20),
              SizedBox(width: 12),
              Text('重命名'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          height: 44,
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 20),
              SizedBox(width: 12),
              Text('删除'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'batch',
          height: 44,
          child: Row(
            children: [
              Icon(Icons.checklist, size: 20),
              SizedBox(width: 12),
              Text('批量管理'),
            ],
          ),
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    if (action == 'rename') {
      _renameSession(context, id, title);
    } else if (action == 'delete') {
      _deleteSession(context, id);
    } else if (action == 'batch') {
      _openBatchMode();
    }
  }

  /// 抽屉进入批量管理模式（多选删除）
  void _openBatchMode() {
    _scaffoldKey.currentState?.openDrawer();
    // 抽屉内部状态切换到多选：通过 drawerKey 通知
    _drawerBatchMode.value = true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = context.watch<SessionsProvider>();
    final skillsProvider = context.watch<SkillProvider>();

    final allSessions = sessions.sessions;

    return Scaffold(
      key: _scaffoldKey,
      // 侧滑抽屉：完整会话列表（DeepSeek 式）
      drawer: _SessionDrawer(
        sessions: allSessions,
        skillsProvider: skillsProvider,
        loaded: sessions.loaded,
        batchMode: _drawerBatchMode,
        onDeleteSelected: (ids) async {
          for (final id in ids) {
            // 当前聊天态会话被删时退出聊天态
            if (_chat?.session.id == id) {
              final chat = _chat!;
              setState(() => _chat = null);
              chat.dispose();
            }
            await context.read<SessionsProvider>().deleteSession(id);
          }
        },
        onOpenChat: (id) {
          Navigator.pop(context); // 先关抽屉
          _openChat(id);
        },
        onOpenSettings: () {
          Navigator.pop(context);
          Haptics.light();
          _unfocus();
          Navigator.push(context, slideUpRoute(const SettingsPage()));
        },
        onShowActions: (ctx, id, title, pos) =>
            _showSessionActions(ctx, id, title, pos),
      ),
      // 圆形新对话按钮已移除：主页即聊天入口，历史对话走抽屉
      body: !sessions.loaded
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  // ===== header：抽屉入口 + 会话标题（聊天态）+ 新增对话 =====
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.menu),
                          tooltip: '会话列表',
                          onPressed: () {
                            Haptics.light();
                            _scaffoldKey.currentState?.openDrawer();
                          },
                        ),
                        // 聊天态：header 显示会话标题
                        Expanded(
                          child: _chat != null
                              ? Text(
                                  _chat!.session.title,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium,
                                )
                              : const SizedBox(),
                        ),
                        // 右上角：新增对话（聊天态确认后退出回空闲态）
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: '新对话',
                          onPressed: _newChat,
                        ),
                      ],
                    ),
                  ),
                  // ===== 主体：空闲态问候语 / 聊天态消息列表 =====
                  Expanded(
                    child: _chat == null
                        ? Center(
                            child: Text(
                              '${_greeting()}，\n想聊点什么？',
                              textAlign: TextAlign.center,
                              style:
                                  theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                          )
                        : _ChatArea(
                            key: ValueKey(_chat!.session.id),
                            chat: _chat!,
                            scrollController: _chatScrollController,
                            onCountChanged: _maybeAutoScroll,
                            onDelete: _deleteCurrentChat,
                          ),
                  ),
                  // ===== 底部：tags 行 + 输入框（空闲态/聊天态共用） =====
                  _HomeInputBar(
                    controller: _inputController,
                    focusNode: _inputFocusNode,
                    chat: _chat,
                    selectedSkill: _selectedSkill,
                    selectedModel: _selectedModel,
                    selectedEffort: _selectedEffort,
                    onSendIdle: _startChat,
                    onPickSkill: _pickSkillForHome,
                    onPickModel: _pickModelForHome,
                    onPickEffort: _pickEffortForHome,
                  ),
                ],
              ),
            ),
    );
  }

  /// effort tag：空闲态改预选档位 / 聊天态改当前会话档位
  Future<void> _pickEffortForHome() async {
    final chat = _chat;
    final current = chat?.session.effort ?? _selectedEffort;
    final selected = await showEffortPicker(context, current);
    if (selected == null || selected == current) return;
    if (chat != null) {
      await chat.setEffort(selected);
    } else {
      setState(() => _selectedEffort = selected);
    }
  }

  /// 主页 agent tag：空闲态改预选 / 聊天态改当前会话 Skill
  Future<void> _pickSkillForHome() async {
    Haptics.light();
    final skills = context.read<SkillProvider>();
    if (!skills.loaded) await skills.load();
    if (!mounted) return;

    // 聊天态：当前会话的 Skill 为选中项
    final chat = _chat;
    final currentId = chat != null ? chat.skill?.id : _selectedSkill?.id;

    final result = await showModalBottomSheet<skill_model.Skill?>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SkillPickerSheet(
        skills: skills,
        recentIds: context.read<SettingsService>().recentSkillIds,
        includeDefault: true,
        selectedId: currentId,
        onSelected: (s) => Navigator.pop(context, s),
      ),
    );
    if (result == null || !mounted) return; // 点遮罩关闭不改动
    // 哨兵 Skill（id='__default__'）= 默认助手 = null
    final picked = result.id == '__default__' ? null : result;
    if (chat != null) {
      await chat.setSkill(picked);
      if (mounted) context.read<SessionsProvider>().refresh();
    } else {
      setState(() => _selectedSkill = picked);
    }
  }

  /// 主页 model tag：空闲态改预选 / 聊天态切当前会话供应商
  Future<void> _pickModelForHome() async {
    Haptics.light();
    final providersProvider = context.read<ProviderProvider>();
    if (!providersProvider.loaded) await providersProvider.load();
    if (!mounted) return;

    final chat = _chat;

    final selected = await showModalBottomSheet<(ProviderProfile, String)>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child:
                  Text('切换模型', style: Theme.of(context).textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in providersProvider.profiles) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                      child: Text(
                        p.name,
                        style:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                ),
                      ),
                    ),
                    if (p.defaultModel.isNotEmpty)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.model_training, size: 20),
                        title: Text(p.defaultModel),
                        trailing: currentModelLabel == p.defaultModel &&
                                (chat?.profile.id ?? _selectedModel?.$1.id) ==
                                    p.id
                            ? Icon(Icons.check_circle,
                                color:
                                    Theme.of(context).colorScheme.primary)
                            : null,
                        onTap: () =>
                            Navigator.pop(context, (p, p.defaultModel)),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (chat != null) {
      final ok = await chat.switchProvider(selected.$1, selected.$2);
      if (mounted && !ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('生成进行中，无法切换模型'),
              duration: Duration(seconds: 2)),
        );
      }
    } else {
      setState(() => _selectedModel = selected);
    }
  }

  /// 当前模型显示名（空闲态预选 / 聊天态会话模型）
  String get currentModelLabel =>
      _chat?.model ?? _selectedModel?.$2 ?? '默认模型';
}

/// 主页底部输入区：tags 行（agent/model/effort）+ 输入框 + 附件 + 发送键
///
/// 双态共用：
/// - 空闲态（chat == null）：tags 显示预选值，发送 = 创建会话进入聊天态
/// - 聊天态（chat != null）：tags 显示会话绑定值，发送 = ChatProvider.sendMessage
///
/// 附件：聊天态直接入 ChatProvider 待发队列；空闲态暂存本组件，
/// 随首条消息经 onSendIdle 传入新会话。
class _HomeInputBar extends StatefulWidget {
  const _HomeInputBar({
    required this.controller,
    required this.focusNode,
    required this.chat,
    required this.selectedSkill,
    required this.selectedModel,
    required this.selectedEffort,
    required this.onSendIdle,
    required this.onPickSkill,
    required this.onPickModel,
    required this.onPickEffort,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 聊天态的 ChatProvider（null = 空闲态）
  final ChatProvider? chat;
  final skill_model.Skill? selectedSkill;
  final (ProviderProfile, String)? selectedModel;

  /// 空闲态预选推理档位（effort tag 空闲态也显示）
  final String selectedEffort;

  /// 空闲态发送（创建会话），附件随首条消息传入
  final void Function(String text,
      {String? skillId,
      (ProviderProfile, String)? modelPick,
      List<MessageAttachment> attachments}) onSendIdle;
  final VoidCallback onPickSkill;
  final VoidCallback onPickModel;
  final VoidCallback onPickEffort;

  @override
  State<_HomeInputBar> createState() => _HomeInputBarState();
}

class _HomeInputBarState extends State<_HomeInputBar> {
  final _picker = ImagePicker();

  /// 空闲态暂存的待发附件（聊天态附件直接进 ChatProvider）
  List<MessageAttachment> _idleAttachments = [];

  /// 文件附件沙箱目录异步初始化（就绪前选取的文件不保存原文件）
  AttachmentService _attachmentService = const AttachmentService();

  @override
  void initState() {
    super.initState();
    _initAttachmentStorage();
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(e.message), duration: const Duration(seconds: 2)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('添加附件失败'), duration: Duration(seconds: 2)),
        );
      }
    }
  }

  void _addOrWarn(MessageAttachment attachment) {
    final ok = _addAttachment(attachment);
    if (!ok && mounted) {
      Haptics.medium();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('图片最多 3 张、文件最多 3 个'),
          duration: Duration(seconds: 2),
        ),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('当前环境不支持文件选择'),
              duration: Duration(seconds: 2)),
        );
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

    // 附件按钮显隐：供应商支持视觉能力（空闲态无会话，默认显示）
    final showAttachmentButton = inChat ? chat.supportsVision : true;
    final pending = _pendingAttachments;

    // 豆包式右侧动作区：流式中显示停止键；有文字/待发附件显示发送键（覆盖 +）；
    // 否则只显示 +
    final hasText = widget.controller.text.trim().isNotEmpty;
    final showSend = isStreaming || hasText || pending.isNotEmpty;
    final showPlus = !isStreaming && !hasText && showAttachmentButton;

    // tags 配置：聊天态取会话绑定值，空闲态取预选值
    final currentSkill = inChat ? chat.skill : widget.selectedSkill;
    // label 只放名字（icon 由 tag 的 emoji/icon 字段单独渲染，避免重复）
    final skillLabel = currentSkill != null ? currentSkill.name : '默认助手';
    // agent tag 图标：具体 agent 用其 emoji，默认助手用内置 icon
    final skillEmoji = currentSkill?.icon;
    final modelLabel =
        inChat ? chat.model : (widget.selectedModel?.$2 ?? '默认模型');
    // 推理档位：聊天态取会话值，空闲态取预选值（两态都显示）
    final effortValue = inChat ? chat.session.effort : widget.selectedEffort;
    final effortLabel = effortLabels[effortValue]?.$1 ?? effortValue;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // tags 行：独立于输入框（agent / model / effort）
          ChatTagsBar(tags: [
            ChatTag(
              emoji: skillEmoji,
              icon: skillEmoji == null ? Icons.smart_toy_outlined : null,
              label: skillLabel,
              onTap: widget.onPickSkill,
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
          ]),
          const SizedBox(height: 6),
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
                // 待发附件预览条
                if (pending.isNotEmpty)
                  _HomeAttachmentPreview(
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
                        onChanged: (_) => setState(() {}),
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

  void _send(BuildContext context) {
    final text = widget.controller.text.trim();
    final pending = _pendingAttachments;
    if (text.isEmpty && pending.isEmpty) return;
    final chat = widget.chat;
    if (chat != null) {
      // 聊天态：附件已在 provider 队列，直接发
      chat.sendMessage(text);
    } else {
      // 空闲态：创建会话进入聊天态，附件随首条消息传入
      final attachments = _idleAttachments;
      setState(() => _idleAttachments = []);
      widget.onSendIdle(
        text,
        skillId: widget.selectedSkill?.id,
        modelPick: widget.selectedModel,
        attachments: attachments,
      );
    }
    widget.controller.clear();
    // 发送后收起键盘（微信式：发送即收起，不残留焦点）
    FocusManager.instance.primaryFocus?.unfocus();
  }
}

/// 主页待发附件预览条（横向滚动缩略图 + 文件卡片）
class _HomeAttachmentPreview extends StatelessWidget {
  const _HomeAttachmentPreview({required this.pending, required this.onRemove});

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

/// 主页内嵌聊天区：消息列表（reverse 底部锚定）+ 错误提示
class _ChatArea extends StatelessWidget {
  const _ChatArea({
    super.key,
    required this.chat,
    required this.scrollController,
    required this.onCountChanged,
    required this.onDelete,
  });

  final ChatProvider chat;
  final ScrollController scrollController;
  final void Function(int newCount) onCountChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 订阅 ChatProvider 重建（流式/状态变化）。
    // 单页架构下 ChatProvider 不在 Provider 树中，必须用 ListenableBuilder。
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        onCountChanged(chat.displayMessages.length);
        return _buildList(context, theme);
      },
    );
  }

  Widget _buildList(BuildContext context, ThemeData theme) {
    return Column(
      children: [
        // 错误提示条
        if (chat.status == ChatStatus.error)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline,
                    size: 18, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chat.errorMessage,
                    style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                InkWell(
                  onTap: () {
                    Haptics.light();
                    chat.clearError();
                  },
                  child: Icon(Icons.close,
                      size: 16, color: theme.colorScheme.onErrorContainer),
                ),
              ],
            ),
          ),
        // 消息列表（reverse：底部锚定，内容置顶显示）
        Expanded(
          child: chat.displayMessages.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: scrollController,
                  reverse: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: chat.displayMessages.length,
                  itemBuilder: (context, index) {
                    final msg = chat.displayMessages[
                        chat.displayMessages.length - 1 - index];
                    if (msg.isToolResult) return const SizedBox.shrink();
                    final isLast = index == 0;
                    // 微信式时间戳：首条必显，之后与上一条间隔 >5 分钟才显示
                    final showTime = _shouldShowTime(index);
                    return Column(
                      children: [
                        if (showTime)
                          _MessageTimeLabel(timestamp: msg.createdAt),
                        MessageAppear(
                          key: ValueKey(msg.id),
                          child: MessageBubble(
                            message: msg,
                            isStreaming: isLast && chat.isStreaming,
                            thinkingSeconds: chat.thinkingSeconds,
                            toolResults: msg.id == chat.lastToolCallMessageId
                                ? chat.toolResults
                                : const [],
                            toolExecuting:
                                msg.id == chat.lastToolCallMessageId &&
                                    chat.status == ChatStatus.toolCalling,
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 是否在该消息上方显示时间标签（微信规则：首条必显 + 间隔超 5 分钟）
  bool _shouldShowTime(int index) {
    final msgs = chat.displayMessages;
    if (index >= msgs.length) return false;
    final msg = msgs[msgs.length - 1 - index];
    if (msg.isToolResult) return false;
    // 首条消息必显
    if (index == msgs.length - 1) return true;
    // 找上一条非 tool 结果消息比较间隔
    for (var i = index + 1; i < msgs.length; i++) {
      final prev = msgs[msgs.length - 1 - i];
      if (prev.isToolResult) continue;
      return msg.createdAt - prev.createdAt > 5 * 60 * 1000;
    }
    return true;
  }
}

/// 微信式消息时间标签：居中灰色小字
class _MessageTimeLabel extends StatelessWidget {
  const _MessageTimeLabel({required this.timestamp});

  final int timestamp;

  /// 微信样式时间文本：今天显示时分，昨天显示「昨天 时分」，更早显示日期
  String get _label {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final hm = '$hh:$mm';
    final diffDays = today.difference(msgDay).inDays;
    if (diffDays == 0) return hm;
    if (diffDays == 1) return '昨天 $hm';
    if (dt.year == now.year) {
      return '${dt.month}月${dt.day}日 $hm';
    }
    return '${dt.year}年${dt.month}月${dt.day}日 $hm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        _label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 侧滑抽屉：完整会话列表按时间分组（今天 / 7 天内 / 更早）+ 搜索 + 批量管理
class _SessionDrawer extends StatefulWidget {
  const _SessionDrawer({
    required this.sessions,
    required this.skillsProvider,
    required this.loaded,
    required this.batchMode,
    required this.onDeleteSelected,
    required this.onOpenChat,
    required this.onOpenSettings,
    required this.onShowActions,
  });

  final List<ChatSession> sessions;
  final SkillProvider skillsProvider;
  final bool loaded;

  /// 批量管理模式开关（主页长按菜单触发进入）
  final ValueNotifier<bool> batchMode;

  /// 批量删除选中的会话
  final Future<void> Function(List<String> ids) onDeleteSelected;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onOpenSettings;
  final void Function(
      BuildContext, String, String, Offset pressPosition) onShowActions;

  @override
  State<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<_SessionDrawer>
    with SingleTickerProviderStateMixin {
  bool _searching = false;
  String _query = '';
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  /// 抽屉内容入场动画：整体淡入 + 轻微右滑（每次打开抽屉重播）
  late final AnimationController _appearController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _appear = CurvedAnimation(
    parent: _appearController,
    curve: Curves.easeOutCubic,
  );

  // 批量管理模式状态
  bool _batchMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    // 抽屉内容随 DrawerController 打开动画交错入场
    _appearController.forward();
    // 主页长按菜单「批量管理」→ 进入多选模式
    widget.batchMode.addListener(_onBatchModeChanged);
  }

  @override
  void didUpdateWidget(covariant _SessionDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.batchMode != widget.batchMode) {
      oldWidget.batchMode.removeListener(_onBatchModeChanged);
      widget.batchMode.addListener(_onBatchModeChanged);
    }
  }

  void _onBatchModeChanged() {
    if (!mounted) return;
    setState(() {
      _batchMode = widget.batchMode.value;
      if (_batchMode) {
        _searching = false; // 批量模式与搜索互斥
        _selectedIds.clear();
      }
    });
  }

  @override
  void dispose() {
    widget.batchMode.removeListener(_onBatchModeChanged);
    _appearController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 退出批量模式
  void _exitBatchMode() {
    setState(() {
      _batchMode = false;
      _selectedIds.clear();
    });
    widget.batchMode.value = false;
  }

  /// 批量删除确认 + 执行
  Future<void> _confirmBatchDelete() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定删除选中的 ${_selectedIds.length} 个会话吗？删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.light();
              Navigator.pop(context, true);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onDeleteSelected(_selectedIds.toList());
    if (!mounted) return;
    _exitBatchMode();
  }

  /// 过滤后的会话（搜索时按标题匹配）
  List<ChatSession> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.sessions;
    return widget.sessions
        .where((s) => s.title.toLowerCase().contains(q))
        .toList();
  }

  /// 按时间分组：今天 / 7 天内 / 更早
  Map<String, List<ChatSession>> get _grouped {
    final now = DateTime.now();
    final startOfToday =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final sevenDaysAgo = startOfToday - 7 * 24 * 3600 * 1000;
    final groups = <String, List<ChatSession>>{
      '今天': [],
      '7 天内': [],
      '更早': [],
    };
    for (final s in _filtered) {
      if (s.updatedAt >= startOfToday) {
        groups['今天']!.add(s);
      } else if (s.updatedAt >= sevenDaysAgo) {
        groups['7 天内']!.add(s);
      } else {
        groups['更早']!.add(s);
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = widget.sessions;
    final filteredEmpty = _filtered.isEmpty;
    final allFilteredIds = _filtered.map((s) => s.id).toSet();
    final allSelected =
        allFilteredIds.isNotEmpty && allFilteredIds.every(_selectedIds.contains);
    return Drawer(
      child: SafeArea(
        child: FadeTransition(
          opacity: _appear,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.02, 0),
              end: Offset.zero,
            ).animate(_appear),
            child: Column(
          children: [
            // 抽屉头部：批量模式操作栏 / 常规 Logo + 搜索 + 设置
            if (_batchMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '退出批量管理',
                      onPressed: () {
                        Haptics.light();
                        _exitBatchMode();
                      },
                    ),
                    Expanded(
                      child: Text(
                        '已选 ${_selectedIds.length} 项',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    // 全选/取消全选
                    IconButton(
                      icon: Icon(
                        allSelected
                            ? Icons.deselect
                            : Icons.select_all,
                        size: 22,
                      ),
                      tooltip: allSelected ? '取消全选' : '全选',
                      onPressed: () {
                        Haptics.light();
                        setState(() {
                          if (allSelected) {
                            _selectedIds.removeAll(allFilteredIds);
                          } else {
                            _selectedIds.addAll(allFilteredIds);
                          }
                        });
                      },
                    ),
                    // 批量删除
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 22,
                        color: _selectedIds.isEmpty
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                      tooltip: '删除选中',
                      onPressed:
                          _selectedIds.isEmpty ? null : _confirmBatchDelete,
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Row(
                  children: [
                    Text('Liang AI',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    // 搜索历史对话
                    IconButton(
                      icon: Icon(
                        _searching ? Icons.search_off : Icons.search,
                        size: 22,
                      ),
                      tooltip: _searching ? '关闭搜索' : '搜索会话',
                      onPressed: () {
                        Haptics.light();
                        setState(() {
                          _searching = !_searching;
                          if (!_searching) {
                            _query = '';
                            _searchController.clear();
                            _searchFocusNode.unfocus();
                          }
                        });
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined, size: 22),
                      tooltip: '设置',
                      onPressed: widget.onOpenSettings,
                    ),
                  ],
                ),
              ),
            // 搜索框（点放大镜展开）
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索会话标题',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              setState(() {
                                _query = '';
                                _searchController.clear();
                              });
                            },
                          ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
            const Divider(height: 1),
            // 会话列表（按时间分组，搜索时按匹配过滤；批量模式多选）
            Expanded(
              child: !widget.loaded
                  ? const Center(child: CircularProgressIndicator())
                  : sessions.isEmpty
                      ? Center(
                          child: Text('暂无会话',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color:
                                      theme.colorScheme.onSurfaceVariant)),
                        )
                      : filteredEmpty
                          ? Center(
                              child: Text(
                                  _batchMode ? '没有可管理的会话' : '没有找到「$_query」',
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant)),
                            )
                          : ListView(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              children: [
                                for (final entry in _grouped.entries)
                                  if (entry.value.isNotEmpty) ...[
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 12, 16, 4),
                                      child: Text(entry.key,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                  color: theme.colorScheme
                                                      .onSurfaceVariant)),
                                    ),
                                    for (final s in entry.value)
                                      // GestureDetector 包 ListTile：
                                      // ListTile 无 onLongPressStart，
                                      // 外包一层拿长按点全局坐标（锚点菜单用）
                                      PressableScale(
                                        child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onLongPressStart: _batchMode
                                            ? null
                                            : (details) => widget.onShowActions(
                                                context,
                                                s.id,
                                                s.title,
                                                details.globalPosition),
                                        child: ListTile(
                                          dense: true,
                                          leading: _batchMode
                                              ? Icon(
                                                  _selectedIds.contains(s.id)
                                                      ? Icons.check_circle
                                                      : Icons
                                                          .radio_button_unchecked,
                                                  size: 22,
                                                  color: _selectedIds
                                                          .contains(s.id)
                                                      ? theme
                                                          .colorScheme.primary
                                                      : theme.colorScheme
                                                          .onSurfaceVariant,
                                                )
                                              : Text(
                                                  widget.skillsProvider
                                                          .byId(s.skillId)
                                                          ?.icon ??
                                                      '💬',
                                                  style: const TextStyle(
                                                      fontSize: 18),
                                                ),
                                          title: Text(
                                            s.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                          onTap: () {
                                            if (_batchMode) {
                                              Haptics.selection();
                                              setState(() {
                                                if (_selectedIds
                                                    .contains(s.id)) {
                                                  _selectedIds.remove(s.id);
                                                } else {
                                                  _selectedIds.add(s.id);
                                                }
                                              });
                                            } else {
                                              widget.onOpenChat(s.id);
                                            }
                                          },
                                        ),
                                        ),
                                      ),
                                  ],
                              ],
                            ),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Skill 选择弹窗内容：搜索 + 最近使用 + 全部折叠
///
/// [includeDefault] = true 时（主页 agent tag 用）顶部多一个「默认助手」选项，
/// 返回哨兵 Skill（id='__default__'，isBuiltin=true）；回调改为传 Skill 对象。
class _SkillPickerSheet extends StatefulWidget {
  const _SkillPickerSheet({
    required this.skills,
    required this.recentIds,
    required this.onSelected,
    this.includeDefault = false,
    this.selectedId,
  });

  final SkillProvider skills;

  /// 最近使用的 skillId（index 0 = 最近）
  final List<String> recentIds;
  final ValueChanged<skill_model.Skill?> onSelected;

  /// 主页 agent tag 模式：顶部显示「默认助手」选项
  final bool includeDefault;

  /// 当前选中的 skillId（主页 agent tag 回显用）
  final String? selectedId;

  @override
  State<_SkillPickerSheet> createState() => _SkillPickerSheetState();
}

/// 「默认助手」哨兵 Skill（includeDefault 模式下选中返回它）
skill_model.Skill get _defaultAssistantSkill => skill_model.Skill(
      id: '__default__',
      name: '默认助手',
      prompt: '',
      isBuiltin: true,
    );

class _SkillPickerSheetState extends State<_SkillPickerSheet> {
  String _query = '';
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = widget.skills.skills;

    // 搜索过滤
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? all
        : all
            .where((a) =>
                a.name.toLowerCase().contains(q) ||
                a.description.toLowerCase().contains(q))
            .toList();

    // 最近使用：按 LRU 顺序取存在的 Skill；无历史时随机取 3 个
    final recent = <skill_model.Skill>[];
    if (widget.recentIds.isEmpty) {
      recent.addAll(all);
      recent.shuffle();
      if (recent.length > 3) recent.length = 3;
    } else {
      for (final id in widget.recentIds) {
        final a = widget.skills.byId(id);
        if (a != null) recent.add(a);
      }
    }
    final recentIdsInFiltered = recent.map((a) => a.id).toSet();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('选择 Skill 开始新对话',
                style: theme.textTheme.titleMedium),
          ),
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索 Skill',
                prefixIcon: const Icon(Icons.search, size: 20),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                // ===== 默认助手（主页 agent tag 模式） =====
                if (widget.includeDefault)
                  ListTile(
                    leading: const Text('🤖',
                        style: TextStyle(fontSize: 24)),
                    title: const Text('默认助手'),
                    subtitle: const Text('无人格提示词，全部工具可用'),
                    trailing: widget.selectedId == null
                        ? Icon(Icons.check_circle,
                            color: theme.colorScheme.primary)
                        : null,
                    onTap: () {
                      Haptics.selection();
                      widget.onSelected(_defaultAssistantSkill);
                    },
                  ),
                // ===== 最近使用（搜索时隐藏） =====
                if (q.isEmpty && recent.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text('最近使用',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  Row(
                    children: [
                      for (final a in recent)
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              Haptics.selection();
                              widget.onSelected(a);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8),
                              child: Column(
                                children: [
                                  Text(a.icon,
                                      style: const TextStyle(
                                          fontSize: 28)),
                                  const SizedBox(height: 4),
                                  Text(
                                    a.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // 不足 3 个时占位对齐
                      for (var i = recent.length; i < 3; i++)
                        const Expanded(child: SizedBox()),
                    ],
                  ),
                  const Divider(height: 16),
                ],
                // ===== 全部 Skill =====
                if (q.isEmpty)
                  ListTile(
                    leading: Icon(
                      _showAll
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text('全部 Skill（${all.length}）',
                        style: theme.textTheme.titleSmall),
                    onTap: () {
                      Haptics.light();
                      setState(() => _showAll = !_showAll);
                    },
                  ),
                // 搜索时直接展示全部结果；未搜索时按折叠状态
                if (q.isNotEmpty || _showAll)
                  ...filtered.map((a) => ListTile(
                        leading: Text(a.icon,
                            style: const TextStyle(fontSize: 24)),
                        title: Text(a.name),
                        subtitle: a.description.isEmpty
                            ? null
                            : Text(
                                a.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        // 当前选中 / 最近使用过的标记
                        trailing: widget.selectedId == a.id
                            ? Icon(Icons.check_circle,
                                color: theme.colorScheme.primary)
                            : (q.isEmpty &&
                                    recentIdsInFiltered.contains(a.id)
                                ? Icon(Icons.circle,
                                    size: 8,
                                    color: theme.colorScheme.primary)
                                : null),
                        onTap: () {
                          Haptics.selection();
                          widget.onSelected(a);
                        },
                      )),
                if (q.isNotEmpty && filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text('没有找到「$_query」',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color:
                                  theme.colorScheme.onSurfaceVariant)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 新对话预设弹窗：预选本次对话的 Skill 与模型（力度走 tags 预选，不在此设置）
///
/// 确认返回 (Skill?, (ProviderProfile, String)?)——Skill 为哨兵
/// （id='__default__'）表示默认助手；点遮罩关闭返回 null（不改动预选）。
class _NewChatPresetSheet extends StatefulWidget {
  const _NewChatPresetSheet({
    required this.skills,
    required this.providers,
    required this.recentIds,
    required this.initialSkill,
    required this.initialModel,
  });

  final SkillProvider skills;
  final ProviderProvider providers;
  final List<String> recentIds;
  final skill_model.Skill? initialSkill;
  final (ProviderProfile, String)? initialModel;

  @override
  State<_NewChatPresetSheet> createState() => _NewChatPresetSheetState();
}

class _NewChatPresetSheetState extends State<_NewChatPresetSheet> {
  // 非空：初始为哨兵（默认助手），选择器只返回非空 Skill
  late skill_model.Skill _skill = widget.initialSkill ?? _defaultAssistantSkill;
  late (ProviderProfile, String)? _model = widget.initialModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skillLabel = _skill.id == '__default__' ? '默认助手' : _skill.name;
    final modelLabel = _model?.$2 ?? '默认模型';

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('新对话', style: theme.textTheme.titleMedium),
          ),
          // Skill 预选
          ListTile(
            leading: Text(_skill.icon, style: const TextStyle(fontSize: 24)),
            title: const Text('助手'),
            subtitle: Text(skillLabel),
            trailing: const Icon(Icons.keyboard_arrow_down),
            onTap: () async {
              Haptics.light();
              final picked = await showModalBottomSheet<skill_model.Skill?>(
                context: context,
                isScrollControlled: true,
                shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (context) => _SkillPickerSheet(
                  skills: widget.skills,
                  recentIds: widget.recentIds,
                  includeDefault: true,
                  selectedId: _skill.id == '__default__' ? null : _skill.id,
                  onSelected: (s) => Navigator.pop(context, s),
                ),
              );
              if (picked != null) {
                setState(() => _skill = picked);
              }
            },
          ),
          // Model 预选
          ListTile(
            leading: const Icon(Icons.tune, size: 24),
            title: const Text('模型'),
            subtitle: Text(modelLabel),
            trailing: const Icon(Icons.keyboard_arrow_down),
            onTap: () async {
              Haptics.light();
              final picked =
                  await showModalBottomSheet<(ProviderProfile, String)>(
                context: context,
                isScrollControlled: true,
                shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (context) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('选择模型',
                            style: theme.textTheme.titleMedium),
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final p in widget.providers.profiles) ...[
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 8, 16, 2),
                                child: Text(
                                  p.name,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                              if (p.defaultModel.isNotEmpty)
                                ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.model_training,
                                      size: 20),
                                  title: Text(p.defaultModel),
                                  trailing: _model?.$2 == p.defaultModel &&
                                          _model?.$1.id == p.id
                                      ? Icon(Icons.check_circle,
                                          color: theme.colorScheme.primary)
                                      : null,
                                  onTap: () => Navigator.pop(
                                      context, (p, p.defaultModel)),
                                ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              );
              if (picked != null) {
                setState(() => _model = picked);
              }
            },
          ),
          // 确认按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Haptics.medium();
                  Navigator.pop(context, (_skill, _model));
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('开始新对话'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 键盘收起观察者：ViewInsets.bottom 归零（键盘收起）时退出输入框聚焦
///
/// 聚焦规则（用户明确）：
/// - 点击输入框 → 聚焦弹键盘，输入中保持聚焦（持续输入）
/// - 键盘收起（点弹层/点空白/系统返回）→ 自动退出聚焦，
///   弹层关闭后 FocusScope 不再把焦点还给输入框（不再回弹键盘）
class _KeyboardDismissObserver extends WidgetsBindingObserver {
  _KeyboardDismissObserver(this._state);

  final _HomePageState _state;
  double _lastBottomInset = 0;

  @override
  void didChangeMetrics() {
    final inset = _state._inputFocusNode.context == null
        ? 0.0
        : (View.of(_state._inputFocusNode.context!).viewInsets.bottom);
    // 键盘从弹出变为收起：退出聚焦
    if (_lastBottomInset > 0 && inset == 0) {
      _state._inputFocusNode.unfocus();
    }
    _lastBottomInset = inset;
  }
}
