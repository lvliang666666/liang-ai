import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../models/chat_message.dart';
import '../models/doc_chunk.dart';
import '../models/tool_call.dart';
import '../services/file_export_service.dart';
import '../services/output_contract.dart';
import '../services/settings_service.dart';
import '../utils/haptics.dart';
import 'app_bottom_sheet.dart';
import 'app_toast.dart';
import 'attachment_thumbnail.dart';
import 'citation_chips.dart';
import 'code_block_widget.dart';
import 'output_contract_card.dart';
import 'swipe_action.dart';
import 'thinking_block.dart';
import 'tool_call_block.dart';

/// 消息气泡：用户右侧蓝色，助手左侧含思考块 + 工具卡片 + Markdown
///
/// 「选择文字」为豆包式自然截取：长按菜单选「选择文字」后，正文在
/// 原气泡内包一层 [SelectionArea]——Markdown 渲染原样保留，长按即
/// 选中词、拖手柄扩选，与原生文本体验一致。选择态是开关式而非常驻：
/// SelectionArea 的拖拽选字会与横滑复制抢手势，选择期间横滑识别器
/// 整体退场（[SwipeActionContainer.enabled]）。
///
/// 选择工具条（v2.6.3 定制，contextMenuBuilder）：
/// - **复制**：只复制不清选区（覆盖 Android 默认的复制即清选），
///   支持连续挑多段批量复制；复制后 Toast 反馈
/// - **完成**：内联在工具条里（工具条锚定选区 = 跟手），点按退出
///   选择模式。工具条只放这两项——默认的分享/全选/系统文本处理
///   动作会触发 Android 原生工具条溢出机制，把排最后的完成挤进
///   ⋮ 溢出菜单（v2.6.2 真机「完成不出现」的根因）
/// - 顶部胶囊：仅无选中内容时显示的兜底退出入口（选中后隐藏，
///   避免与工具条双入口并存）
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.thinkingSeconds = 0,
    this.toolResults = const [],
    this.toolExecuting = false,
    this.highlight = false,
    this.interrupted = false,
    this.onResume,
    this.onTogglePin,
    this.onEdit,
    this.onQuote,
    this.onRegenerate,
    this.onSaveAsCard,
    this.onChooseDual,
    this.resolveChunk,
    this.outputContract,
  });

  final ChatMessage message;
  final bool isStreaming;
  final int thinkingSeconds;

  /// I10 断流续传：本条消息是否处于「连接中断」态（尾部显示
  /// 「连接中断 · 点击续传」胶囊，点击回调 [onResume]）
  final bool interrupted;

  /// 断流续传回调（null = 无续传能力，胶囊不显示）
  final VoidCallback? onResume;

  /// 本消息 tool_calls 对应的执行结果（UI 卡片展示）
  final List<ToolCallResult> toolResults;

  /// 工具是否正在执行（toolCalling 状态）
  final bool toolExecuting;

  /// I7 搜索定位：命中气泡临时高亮（外层描边 + 底色闪烁，2s 渐隐由
  /// 宿主 ChatMessageListState 控制）。Markdown 正文不做词级高亮——
  /// GptMarkdown 无法注入内联样式，气泡级高亮已足够定位
  final bool highlight;

  /// 切换钉住状态（F2：钉住消息所在轮永不压缩进前情摘要）。
  /// null = 无钉住能力（纯展示场景）
  final ValueChanged<bool>? onTogglePin;

  /// 编辑重发（I4：仅 user 消息，null = 无编辑能力）
  final VoidCallback? onEdit;

  /// 引用追问（I5：仅 assistant 消息，null = 无引用能力）
  final VoidCallback? onQuote;

  /// 重答（I3：仅 assistant 消息，null = 无重答能力）——删除该回答
  /// 及其后消息，复用原 user 消息重新生成
  final VoidCallback? onRegenerate;

  /// 沉淀为卡片（M5 对话炼金炉：user/assistant 消息均可，null = 无沉淀能力）
  final VoidCallback? onSaveAsCard;

  /// F6 同问双答「用这个继续」（仅待选择态的 assistant 消息，null =
  /// 无选择能力——姊妹气泡上的按钮不显示，普通消息不受影响）
  final VoidCallback? onChooseDual;

  /// F8 引用溯源：按 (docName, page) 查回 doc_chunks 原文块（null =
  /// 无检索能力，引用 chips 纯展示不可点）
  final Future<DocChunk?> Function(String docName, int page)? resolveChunk;

  /// F10 输出契约：当前会话 Agent 声明的输出契约（null = 未声明，
  /// 无卡片渲染）。assistant 非流式回复含合法 yaml 块时渲染专属卡片
  final OutputContract? outputContract;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  /// 豆包式选择文字模式（正文包 SelectionArea，Markdown 渲染不变）
  bool _selecting = false;

  /// 选择区状态：SelectionListener 桥（选中几何变化通知）
  final SelectionListenerNotifier _selectionNotifier =
      SelectionListenerNotifier();

  /// 当前选中的文本（onSelectionChanged 实时回传；复制按钮取用。
  /// SelectableRegionState 无公开 getSelectedContent，走回调是官方路）
  String? _selectedText;

  /// 是否有生效选区（顶部「完成」胶囊显隐依据：无选中才显示兜底）
  bool get _hasActiveSelection =>
      _selectedText != null && _selectedText!.isNotEmpty;

  @override
  void dispose() {
    _selectionNotifier.dispose();
    super.dispose();
  }

  /// 选择工具条：只放「复制」「完成」两项，锚定选区跟手。
  ///
  /// v2.6.3 修复「工具条内完成不出现」：Android 原生 TextSelectionToolbar
  /// 有溢出机制——按钮总宽超屏时放不下的收进 ⋮ 溢出菜单。默认队列是
  /// 复制/分享/全选 + 系统文本处理动作（国产 ROM 注入翻译等）+ 完成，
  /// 完成排最后 = 第一个被挤出去。精简为两项后任何屏幕都放得下；
  /// 分享/全选与横滑复制、长按菜单功能重复，砍掉无损失。
  /// 复制项覆盖默认行为——保留选区支持连续多段批量复制。
  Widget _buildSelectionToolbar(
      BuildContext context, SelectableRegionState selectableRegion) {
    final buttonItems = [
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: _copySelection,
      ),
      ContextMenuButtonItem(
        label: '完成',
        onPressed: _exitSelecting,
      ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegion.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  /// 复制当前选区（不清选区，可连续多段批量复制）
  Future<void> _copySelection() async {
    final text = _selectedText;
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    Haptics.medium();
    if (mounted) {
      showAppToast(context, '已复制，可继续选取其他片段');
    }
  }

  /// 退出选择模式（清选区状态 + 恢复横滑）
  void _exitSelecting() {
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selectedText = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 「快捷操作」开关（设置页）：开 = 横滑复制可用；关 = 无横滑动作
    final swipeEnabled =
        context.watch<SettingsService>().swipeActions;
    final message = widget.message;
    final isStreaming = widget.isStreaming;

    if (message.isUser) {
      final hasImages = message.attachments.any((a) => a.isImage);
      return Align(
        alignment: Alignment.centerRight,
        child: SwipeActionContainer(
          // 用户消息右滑复制（v2.5.0 定版方案，快捷操作开时生效）：
          // 手指向右滑、气泡向屏幕中间让位，动作区在左缘露出
          direction: SwipeDirection.leftToRight,
          icon: Icons.copy_outlined,
          label: '复制',
          color: colorScheme.primary,
          enabled:
              swipeEnabled && message.content.isNotEmpty && !isStreaming,
          onAction: () => _copyMessage(context, message),
          child: Container(
            margin: const EdgeInsets.only(left: 60, top: 4, bottom: 4),
            padding: EdgeInsets.fromLTRB(
                hasImages ? 6 : 14, hasImages ? 6 : 10, hasImages ? 6 : 14,
                hasImages ? 6 : 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.widthOf(context) * 0.78,
            ),
            decoration: BoxDecoration(
              color: colorScheme.primary,
              borderRadius: BorderRadius.circular(20),
              // I7 搜索定位高亮：主色描边 + 外发光圈（用户气泡本身是
              // 主色底，描边比换底色更醒目且不破坏对比度）
              border: widget.highlight
                  ? Border.all(
                      color: colorScheme.onPrimary, width: 2)
                  : null,
              boxShadow: widget.highlight
                  ? [
                      BoxShadow(
                        color: colorScheme.primary.withValues(alpha: 0.55),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            // 长按弹锚点菜单（I4：复制/编辑/钉住）。不用 SelectableText——
            // 其内部 TapAndHorizontalDragGestureRecognizer 会抢赢手势
            // 竞技场，横滑复制在文字上起手时永远无法触发
            child: GestureDetector(
              onLongPressStart: message.content.isNotEmpty
                  ? (details) {
                      Haptics.medium();
                      _showUserMessageActions(
                          context, message, details.globalPosition);
                    }
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 钉住标记（F2）：钉住消息所在轮永不压缩进前情摘要
                  if (message.pinned)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.push_pin,
                              size: 12, color: colorScheme.onPrimary),
                          const SizedBox(width: 3),
                          Text(
                            '已钉住',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onPrimary.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // 附件区：图片缩略图 / 文件卡片
                  if (message.hasAttachments)
                    _UserAttachments(message: message),
                  // 正文（有附件但无文字时不渲染空文本）
                  if (message.content.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                          top: message.hasAttachments ? 6 : 0,
                          left: hasImages ? 8 : 0,
                          right: hasImages ? 8 : 0),
                      child: Text(
                        message.content,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onPrimary,
                          height: 1.6,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 助手消息：DeepSeek 式视觉减重——浅灰底、大圆角、无小尾巴
    final thinkingStreaming = isStreaming && message.content.isEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: SwipeActionContainer(
        // 助手消息左滑复制（v2.5.0 定版方案，快捷操作开时生效）。
        // v2.5.3 方向锁保留：识别器只认领左滑，右滑弃权让位抽屉——
        // 气泡上右滑仍是"开会话列表"，与复制互不干扰。
        // 选择文字模式整体退场：拖拽选字与横滑不共存
        direction: SwipeDirection.rightToLeft,
        icon: Icons.copy_outlined,
        label: '复制',
        color: colorScheme.primary,
        enabled: swipeEnabled &&
            message.content.isNotEmpty &&
            !isStreaming &&
            !_selecting,
        onAction: () => _copyMessage(context, message),
        child: Container(
          margin: const EdgeInsets.only(right: 40, top: 4, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.widthOf(context) * 0.86,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            // I7 搜索定位高亮：主色底闪烁 + 描边（浅灰底气泡换主色底
            // 最醒目；2s 后宿主清除 highlight 恢复原样）
            color: widget.highlight
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
            border: widget.highlight
                ? Border.all(color: colorScheme.primary, width: 1.5)
                : null,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // 选择模式下长按交给 SelectionArea 挑字，不再弹菜单
            onLongPressStart: _selecting
                ? null
                : (details) {
                    if (message.content.isNotEmpty) {
                      Haptics.medium();
                      _showMessageActions(
                          context, message, details.globalPosition);
                    }
                  },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // F6 来源徽标：双答回答的出处（「公司 GLM · glm5.1」）。
                // null = 普通消息无徽标；流式中也显示（对照时知道哪条是谁）
                if (message.sourceLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified_outlined,
                            size: 12, color: colorScheme.primary),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            message.sourceLabel!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                // 钉住标记（F2）：钉住消息所在轮永不压缩进前情摘要
                if (message.pinned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.push_pin,
                            size: 12, color: colorScheme.primary),
                        const SizedBox(width: 3),
                        Text(
                          '已钉住',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                // 选择模式顶栏：「完成」兜底退出入口。仅无选中内容时
                // 显示——选中后工具条（跟手）成为主要退出路径，胶囊
                // 隐藏避免双入口；清除选区后胶囊复现兜底（v2.6.3 修复
                // 「完成按钮常驻气泡顶部」：原来 if (_selecting) 无条件
                // 显示，与工具条双入口并存）
                if (_selecting && !_hasActiveSelection)
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: _exitSelecting,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '完成',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_selecting && !_hasActiveSelection)
                  const SizedBox(height: 8),
                // 思考过程块
                if (message.reasoning.isNotEmpty || thinkingStreaming)
                  ThinkingBlock(
                    reasoning: message.reasoning,
                    streaming: thinkingStreaming,
                    seconds: widget.thinkingSeconds,
                  ),
                // 工具调用卡片（assistant 发起过调用时显示）
                if (message.toolCalls.isNotEmpty)
                  ToolCallBlock(
                    calls: message.toolCalls,
                    results: widget.toolResults,
                    executing: widget.toolExecuting,
                  ),
                // 正文：选择模式 = SelectionArea 包住 Markdown（渲染
                // 原样保留，长按选词/拖手柄/系统工具条复制）；常规 =
                // 裸 Markdown。GptMarkdown 的段落是 Text/RichText，
                // 会自动注册到 SelectionContainer，选择天然生效
                if (message.content.isNotEmpty)
                  _selecting
                      ? SelectionListener(
                          selectionNotifier: _selectionNotifier,
                          child: SelectionArea(
                            onSelectionChanged: (content) {
                              // 实时记录选中文本（复制按钮取用）。选中态
                              // 变化（含清除）都要 setState：顶部「完成」
                              // 胶囊按 _hasActiveSelection 显隐——无选中
                              // 时兜底显示，选中后隐藏（退出走跟手工具条）
                              final hadSelection = _hasActiveSelection;
                              _selectedText = content?.plainText;
                              if (mounted &&
                                  (hadSelection != _hasActiveSelection ||
                                      (_selectionNotifier.registered &&
                                          _selectionNotifier.selection
                                              .status !=
                                              SelectionStatus.none))) {
                                setState(() {});
                              }
                            },
                            // 定制工具条：复制保留选区（批量复制）+
                            // 「完成」内联跟手（锚定选区，非固定顶部）
                            contextMenuBuilder: _buildSelectionToolbar,
                            child: GptMarkdown(
                              message.content,
                              isStreaming: isStreaming,
                              // 打字机节奏：70 字/秒——长回答不拖沓，短回答仍有打字感
                              charactersPerSecond: 70,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(height: 1.6),
                              codeBuilder: (context, name, code, closed) =>
                                  CodeBlockWidget(code: code, language: name),
                            ),
                          ),
                        )
                      : GptMarkdown(
                          message.content,
                          isStreaming: isStreaming,
                          // 打字机节奏：70 字/秒——长回答不拖沓，短回答仍有打字感
                          charactersPerSecond: 70,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(height: 1.6),
                          codeBuilder: (context, name, code, closed) =>
                              CodeBlockWidget(code: code, language: name),
                        ),
                // F10 输出契约卡片：Agent 声明了 output 且回复含合法
                // yaml 块时渲染专属字段卡片（流式中不显示——yaml 块
                // 随打字机逐字出现会闪烁半截；解析失败静默无卡片，
                // markdown 正文照常，卡片是增强不是门槛）
                if (!isStreaming &&
                    message.role == 'assistant' &&
                    widget.outputContract != null)
                  Builder(builder: (context) {
                    final values = OutputContract.extract(
                        message.content, widget.outputContract!);
                    if (values == null) return const SizedBox.shrink();
                    return OutputContractCard(
                      contract: widget.outputContract!,
                      values: values,
                    );
                  }),
                // F8 引用来源 chips：回答含【文件名·第N页】标注时显示
                //（流式中不显示——标注随打字机逐字出现会闪烁）
                if (!isStreaming && message.role == 'assistant')
                  CitationChips(
                    content: message.content,
                    resolveChunk: widget.resolveChunk,
                  ),
                // 流式中正文还没来：显示光标动画占位
                if (isStreaming &&
                    message.content.isEmpty &&
                    message.reasoning.isEmpty)
                  const _TypingIndicator(),
                // E5：中断且无任何内容（App 被杀时的空占位）——不渲染
                // 空气泡正文，只显示「已中断」提示
                if (widget.interrupted &&
                    !isStreaming &&
                    message.content.isEmpty &&
                    message.reasoning.isEmpty &&
                    message.toolCalls.isEmpty)
                  const SizedBox(height: 2),
                // I10 断流续传胶囊：连接中断 · 点击续传
                //（onResume 为 null = 无续传能力，不显示）
                if (widget.interrupted &&
                    !isStreaming &&
                    widget.onResume != null)
                  _InterruptedBanner(onResume: widget.onResume),
                // I10 生成状态角标：token 数 + 耗时（非流式 assistant 消息）
                if (!isStreaming && !widget.interrupted)
                  _GenerationBadge(message: message),
                // F6 同问双答「用这个继续」：待选择态（dualOf 互指）时
                // 显示——点选本侧，姊妹回答删除、会话回到单线。流式中
                // 不显示（两侧都收尾后才进入待选择态）
                if (!isStreaming && message.dualOf != null && widget.onChooseDual != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _ChooseDualButton(onTap: widget.onChooseDual!),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 横滑复制的统一动作（与长按菜单复制同反馈：medium 震 + Toast）
  Future<void> _copyMessage(BuildContext context, ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.content));
    Haptics.medium();
    if (context.mounted) {
      showAppToast(context, '已复制');
    }
  }

  /// 用户消息长按菜单（I3）：底部 action sheet——复制 / 编辑重发 / 钉住
  Future<void> _showUserMessageActions(
      BuildContext context, ChatMessage message, Offset pressPosition) async {
    final canEdit = widget.onEdit != null && !widget.isStreaming;
    final canPin = widget.onTogglePin != null;
    final canCard = widget.onSaveAsCard != null;
    final action = await showAppBottomSheet<String>(
      context: context,
      builder: (context) => SheetScaffold(
        title: '消息操作',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _actionTile(context, Icons.copy_outlined, '复制', 'copy'),
            if (canEdit)
              _actionTile(context, Icons.edit_outlined, '编辑重发', 'edit'),
            if (canCard)
              _actionTile(
                  context, Icons.style_outlined, '沉淀为卡片', 'card'),
            if (canPin)
              _actionTile(
                context,
                message.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                message.pinned ? '取消钉住' : '钉住',
                'pin',
                iconColor: message.pinned
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;

    if (action == 'copy') {
      await _copyMessage(context, message);
      return;
    }
    if (action == 'edit') {
      widget.onEdit?.call();
      return;
    }
    if (action == 'card') {
      widget.onSaveAsCard?.call();
      return;
    }
    if (action == 'pin') {
      final target = !message.pinned;
      widget.onTogglePin?.call(target);
      if (context.mounted) {
        showAppToast(context, target ? '已钉住，所在轮不参与压缩' : '已取消钉住');
      }
    }
  }

  /// action sheet 单行操作项（I3 统一样式）
  Widget _actionTile(BuildContext context, IconData icon, String label,
      String value,
      {Color? iconColor}) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, size: 22, color: iconColor ?? theme.colorScheme.onSurface),
      title: Text(label, style: theme.textTheme.bodyLarge),
      onTap: () {
        Haptics.light();
        Navigator.pop(context, value);
      },
    );
  }

  /// 助手消息长按菜单（I3）：底部 action sheet——复制全文 / 选择文字 /
  /// 引用 / 重答 / 钉住 / 导出为文档
  Future<void> _showMessageActions(
      BuildContext context, ChatMessage message, Offset pressPosition) async {
    final canPin = widget.onTogglePin != null;
    final canQuote = widget.onQuote != null && !widget.isStreaming;
    final canRegen = widget.onRegenerate != null && !widget.isStreaming;
    final canCard = widget.onSaveAsCard != null;
    final action = await showAppBottomSheet<String>(
      context: context,
      builder: (context) => SheetScaffold(
        title: '消息操作',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _actionTile(context, Icons.copy_outlined, '复制全文', 'copy'),
            _actionTile(context, Icons.highlight_alt, '选择文字', 'select'),
            if (canQuote)
              _actionTile(
                  context, Icons.format_quote_outlined, '引用', 'quote'),
            if (canRegen)
              _actionTile(context, Icons.refresh_outlined, '重答', 'regen'),
            if (canCard)
              _actionTile(
                  context, Icons.style_outlined, '沉淀为卡片', 'card'),
            if (canPin)
              _actionTile(
                context,
                message.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                message.pinned ? '取消钉住' : '钉住',
                'pin',
                iconColor: message.pinned
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            _actionTile(context, Icons.ios_share, '导出并分享', 'export'),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;

    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.content));
      Haptics.medium(); // 复制完成反馈（三档词汇表：medium）
      if (context.mounted) {
        // 长按菜单的复制无按钮可切换状态 → 全局 Toast 兜底
        showAppToast(context, '已复制');
      }
      return;
    }

    if (action == 'select') {
      // 豆包式选择：正文包 SelectionArea（Markdown 渲染不变，不弹层）
      if (mounted) setState(() => _selecting = true);
      return;
    }

    if (action == 'quote') {
      widget.onQuote?.call();
      return;
    }

    if (action == 'regen') {
      widget.onRegenerate?.call();
      return;
    }

    if (action == 'card') {
      widget.onSaveAsCard?.call();
      return;
    }

    if (action == 'pin') {
      final target = !message.pinned;
      widget.onTogglePin?.call(target);
      if (context.mounted) {
        showAppToast(context, target ? '已钉住，所在轮不参与压缩' : '已取消钉住');
      }
      return;
    }

    if (action == 'export') {
      await _pickExportFormat(context, message);
    }
  }

  /// 选择导出格式并落盘
  Future<void> _pickExportFormat(
      BuildContext context, ChatMessage message) async {
    final format = await showModalBottomSheet<ExportFormat>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('选择分享格式',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Markdown（.md）'),
              subtitle: const Text('保留全部格式，适合再次编辑'),
              onTap: () {
                Haptics.selection();
                Navigator.pop(context, ExportFormat.markdown);
              },
            ),
            ListTile(
              leading: const Icon(Icons.html_outlined),
              title: const Text('HTML（.html）'),
              subtitle: const Text('带样式排版，浏览器/WPS 直接打开'),
              onTap: () {
                Haptics.selection();
                Navigator.pop(context, ExportFormat.html);
              },
            ),
            ListTile(
              leading: const Icon(Icons.text_snippet_outlined),
              title: const Text('纯文本（.txt）'),
              subtitle: const Text('去掉格式标记，任何地方可读'),
              onTap: () {
                Haptics.selection();
                Navigator.pop(context, ExportFormat.plainText);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || format == null) return;

    try {
      final fileNameBase =
          'LiangAI_${DateTime.now().toIso8601String().substring(0, 10)}';
      final result = await FileExportService.share(
        content: message.content,
        fileNameBase: fileNameBase,
        format: format,
      );
      if (!context.mounted) return;
      // 用户在分享面板点了取消：静默即可，不打扰
      if (result == null || result.status == ShareResultStatus.dismissed) {
        return;
      }
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, '导出失败：$e');
      }
    }
  }
}

/// 用户消息附件区：图片缩略图网格 + 豆包式文件卡片（可点开）
class _UserAttachments extends StatelessWidget {
  const _UserAttachments({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final images = message.attachments.where((a) => a.isImage).toList();
    final files = message.attachments.where((a) => a.isFile).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 图片缩略图（≤3 张，一行排开）
        if (images.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final img in images)
                GestureDetector(
                  onTap: () => _openImageViewer(context, images, img),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: AttachmentThumbnail(
                      base64: img.base64Data ?? '',
                      size: 96,
                    ),
                  ),
                ),
            ],
          ),
        // 豆包式文件卡片（点击打开原文件）
        for (final f in files)
          _FileCard(
            name: f.name,
            hasFile: f.hasFile,
            onTap: () => _openFile(context, f),
          ),
      ],
    );
  }

  void _openImageViewer(
      BuildContext context, List images, current) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => _ImageViewer(
          images: [for (final i in images) i.base64Data ?? ''],
          initialIndex: images.indexOf(current),
        ),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  /// 打开文件附件原文件（系统应用接管：PDF→阅读器等）
  Future<void> _openFile(BuildContext context, f) async {
    Haptics.light();
    if (!f.hasFile) {
      showAppToast(context, '旧版本消息未保存原文件，无法打开');
      return;
    }
    final result = await OpenFilex.open(f.filePath!);
    if (result.type != ResultType.done && context.mounted) {
      showAppToast(context, result.message);
    }
  }
}

/// 豆包式文件卡片：图标 + 文件名 + 类型标签，点击打开
class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.name,
    required this.hasFile,
    required this.onTap,
  });

  final String name;
  final bool hasFile;
  final VoidCallback onTap;

  String get _extLabel {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '文件';
    return name.substring(dot + 1).toUpperCase();
  }

  IconData get _icon {
    final ext = _extLabel.toLowerCase();
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (ext == 'md') return Icons.article_outlined;
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 230),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(_icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasFile ? '$_extLabel 文件 · 点击打开' : '$_extLabel 文件',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全屏图片查看器（黑底，点击关闭，多图可左右滑动）
class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.images, required this.initialIndex});

  final List<String> images;
  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        color: Colors.black87,
        alignment: Alignment.center,
        child: images.length == 1
            ? InteractiveViewer(
                child: Image.memory(base64Decode(images.first)),
              )
            : PageView.builder(
                controller: PageController(initialPage: initialIndex),
                itemCount: images.length,
                itemBuilder: (_, i) => InteractiveViewer(
                  child: Image.memory(base64Decode(images[i])),
                ),
              ),
      ),
    );
  }
}

/// I10 断流续传胶囊：「连接中断 · 点击续传」（错误色调，点击续传）
class _InterruptedBanner extends StatelessWidget {
  const _InterruptedBanner({this.onResume});

  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onResume,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: cs.errorContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, size: 14, color: cs.error),
              const SizedBox(width: 6),
              Text(
                '连接中断 · 点击续传',
                style: theme.textTheme.labelSmall?.copyWith(color: cs.error),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// I10 生成状态角标：token 数 + 耗时（气泡尾部小字，onSurfaceVariant）
///
/// 数据缺失（老消息无 token/耗时）时对应段省略；两段都缺则整行不渲染。
/// 流式中不显示（收尾后才有准确值）。
class _GenerationBadge extends StatelessWidget {
  const _GenerationBadge({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = <String>[
      if (message.promptTokens != null || message.completionTokens != null)
        '${_fmt(message.promptTokens ?? 0)} / ${_fmt(message.completionTokens ?? 0)} token',
      if (message.generationSeconds != null && message.generationSeconds! > 0)
        '${message.generationSeconds}s',
    ];
    if (segments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        segments.join(' · '),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  static String _fmt(int tokens) {
    if (tokens < 1000) return '$tokens';
    var s = (tokens / 1000).toStringAsFixed(1);
    if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
    return '${s}k';
  }
}

/// F6 同问双答「用这个继续」按钮：点选本侧回答继续会话
///
/// 主色描边胶囊（区别于普通按钮的填充态——选择是轻量动作，不该
/// 抢正文视觉权重）；点击后宿主删姊妹清标记，按钮随 dualOf 清空消失
class _ChooseDualButton extends StatelessWidget {
  const _ChooseDualButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.primary, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 14, color: cs.primary),
            const SizedBox(width: 5),
            Text(
              '用这个继续',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打字中指示器（三个跳动圆点）
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        Widget dot(int i) {
          final t = (_controller.value * 3 - i).clamp(0.0, 1.0);
          final wave = 1 - (2 * t - 1).abs();
          final scale = 0.6 + 0.4 * wave;
          // 透明度与缩放同相位：跳动高点最实，低点最虚（DeepSeek 质感）
          final opacity = 0.35 + 0.65 * wave;
          return Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          );
        }

        return Row(mainAxisSize: MainAxisSize.min, children: [
          dot(0),
          dot(1),
          dot(2),
        ]);
      },
    );
  }
}
