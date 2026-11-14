import 'dart:io';

import '../document_forge/document_forge_service.dart';
import '../document_forge/document_palette.dart';
import '../tool_registry.dart';

/// 文档生成工具（Document Forge）：模型按需产出可下载的文档文件
///
/// 统一单工具 + format 参数分发（省 schema；每格式一个工具的备选
/// 方案被否——注册表膨胀 5 倍，模型选择面变宽无收益）。
///
/// 输出目录与排版强调色由宿主注入（ChatProvider 构建注册表时给
/// 沙箱 documents/attachments + 当前主题色快照），工具保持纯 Dart
/// 可单测（测试注入临时目录即可）。
///
/// 返回文本带 [FILE:<path>] 标记：宿主 OrchToolResults 分支解析标记，
/// 构造 assistant 附件消息（复用 _FileCard 渲染 + OpenFilex 打开）。
/// 标记同时保留在 tool 结果文本里，模型能感知文件已生成。
class CreateDocumentTool extends ToolHandler {
  const CreateDocumentTool({this.outputDir, this.palette});

  /// 输出目录（null = 未注入，execute 时报错——测试可注入临时目录）
  final Directory? outputDir;

  /// 排版强调色（null = forge 内置商务蓝兜底）
  final DocumentPalette? palette;

  static const _formatsDesc =
      'pdf（PDF 文档）/ word（Word 文档）/ excel（Excel 表格）/ '
      'ppt（PPT 幻灯片）/ csv（CSV 表格）';

  @override
  String get name => 'create_document';

  @override
  String get description =>
      '生成文档文件并作为会话附件发给用户。支持格式：$_formatsDesc。'
      'title 为文档标题；content 为正文，每行一条（用 \\n 分隔）：'
      'pdf/word 按段落渲染；excel/csv 每行一条记录、竖线 | 分列'
      '（如 "姓名|年龄|城市"）；ppt 空行分页、页内首行是标题其余是要点。'
      'file_name 为文件名（不含扩展名，可省略则自动命名）。'
      '适合：用户要报告/表格/幻灯片/可打印文档等场景。';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'format': {
            'type': 'string',
            'enum': ['pdf', 'word', 'excel', 'ppt', 'csv'],
            'description': '文档格式：$_formatsDesc',
          },
          'title': {
            'type': 'string',
            'description': '文档标题（csv 忽略此参数）',
          },
          'content': {
            'type': 'string',
            'description':
                '正文内容，每行一条（\\n 分隔）。excel/csv 用竖线 | 分列；'
                'ppt 空行分页',
          },
          'file_name': {
            'type': 'string',
            'description': '文件名（不含扩展名；省略则按标题自动命名）',
          },
        },
        'required': ['format', 'title', 'content'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final format = arguments['format'];
    final title = arguments['title'];
    final content = arguments['content'];
    if (format is! String || !DocumentForgeService.formats.containsKey(format)) {
      throw ArgumentError(
          'format 必须是 ${DocumentForgeService.formats.keys.join('/')} 之一');
    }
    if (title is! String || title.trim().isEmpty) {
      throw ArgumentError('title 不能为空');
    }
    if (content is! String) {
      throw ArgumentError('content 不能为空');
    }
    final dir = outputDir;
    if (dir == null) {
      throw StateError('输出目录未注入（宿主配置缺失）');
    }

    final fileName = _sanitizeFileName(
      (arguments['file_name'] is String && (arguments['file_name'] as String).trim().isNotEmpty)
          ? arguments['file_name'] as String
          : title,
    );

    final file = await DocumentForgeService(outputDir: dir, palette: palette)
        .generate(
      format: format,
      title: title.trim(),
      lines: content.split('\n'),
      fileName: fileName,
    );

    return '文档已生成：${file.path}\n[FILE:${file.path}]';
  }

  /// 文件名净化：去路径分隔符与非法字符，限长 80（防模型给超长名）
  String _sanitizeFileName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final name = cleaned.isEmpty ? 'document' : cleaned;
    return name.length > 80 ? name.substring(0, 80) : name;
  }
}
