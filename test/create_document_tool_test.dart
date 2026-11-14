import 'dart:io';

import 'package:ai_chat_app/models/tool_call.dart';
import 'package:ai_chat_app/services/tool_registry.dart';
import 'package:ai_chat_app/services/tools/builtin_tools.dart';
import 'package:ai_chat_app/services/tools/create_document_tool.dart';
import 'package:ai_chat_app/services/tools/manage_http_tool_tool.dart';
import 'package:flutter_test/flutter_test.dart';

/// CreateDocumentTool 单测：参数校验 / 五格式分发 / 文件名净化 /
/// [FILE:] 标记输出 / 注册表与防漂移清单同步
void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('create_doc_tool_test');
  });

  tearDown(() {
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  CreateDocumentTool tool() => CreateDocumentTool(outputDir: tmpDir);

  group('参数校验', () {
    test('非法 format 抛 ArgumentError', () {
      expect(
        () => tool().execute(
            {'format': 'doc', 'title': 't', 'content': 'x'}),
        throwsArgumentError,
      );
    });

    test('空 title 抛 ArgumentError', () {
      expect(
        () => tool().execute(
            {'format': 'pdf', 'title': '  ', 'content': 'x'}),
        throwsArgumentError,
      );
    });

    test('缺 content 抛 ArgumentError', () {
      expect(
        () => tool().execute({'format': 'pdf', 'title': 't'}),
        throwsArgumentError,
      );
    });

    test('未注入输出目录抛 StateError', () {
      expect(
        () => const CreateDocumentTool()
            .execute({'format': 'pdf', 'title': 't', 'content': 'x'}),
        throwsStateError,
      );
    });
  });

  group('执行与标记输出', () {
    test('生成文件并返回 [FILE:<path>] 标记', () async {
      final out = await tool().execute({
        'format': 'pdf',
        'title': '季度报告',
        'content': '第一段\n第二段',
        'file_name': 'q3',
      });
      expect(out, contains('[FILE:'));
      final path =
          RegExp(r'\[FILE:([^\]]+)\]').firstMatch(out)!.group(1)!;
      final f = File(path);
      expect(f.existsSync(), isTrue);
      expect(f.path.endsWith('q3.pdf'), isTrue);
    });

    test('省略 file_name 时按标题命名', () async {
      final out = await tool().execute({
        'format': 'csv',
        'title': '数据表',
        'content': 'a,b',
      });
      final path =
          RegExp(r'\[FILE:([^\]]+)\]').firstMatch(out)!.group(1)!;
      expect(File(path).path.endsWith('数据表.csv'), isTrue);
    });

    test('文件名净化：非法字符替换为下划线', () async {
      final out = await tool().execute({
        'format': 'word',
        'title': 't',
        'content': 'x',
        'file_name': r'a/b\c:d*e?f"g<h>i|j',
      });
      final path =
          RegExp(r'\[FILE:([^\]]+)\]').firstMatch(out)!.group(1)!;
      expect(path, isNot(contains('/b')));
      expect(File(path).existsSync(), isTrue);
    });

    test('超长文件名截断到 80 字符', () async {
      final out = await tool().execute({
        'format': 'pdf',
        'title': 't',
        'content': 'x',
        'file_name': '长' * 200,
      });
      final path =
          RegExp(r'\[FILE:([^\]]+)\]').firstMatch(out)!.group(1)!;
      final base = path.split(Platform.pathSeparator).last;
      expect(base.length, lessThanOrEqualTo(80 + '.pdf'.length));
    });
  });

  group('注册与防漂移', () {
    test('builtinTools 含 create_document 且 schema 合法', () {
      final handler = builtinTools.firstWhere((t) => t.name == 'create_document');
      expect(handler, isA<CreateDocumentTool>());
      final schema = handler.parametersSchema;
      expect(schema['type'], 'object');
      final props = schema['properties'] as Map<String, dynamic>;
      expect(props.keys, containsAll(['format', 'title', 'content']));
      expect(schema['required'], contains('format'));
    });

    test('builtinToolNames 清单与 builtinTools 同步（防漂移）', () {
      final registryNames = builtinTools.map((t) => t.name).toSet();
      final listNames = builtinToolNames.toSet();
      expect(listNames, equals(registryNames),
          reason: 'manage_http_tool_tool.dart 的 builtinToolNames 清单'
              '与 builtin_tools.dart 实际工具集漂移——新工具注册时两处都要加');
    });

    test('注册表执行：未知工具报错、已知工具走通', () async {
      final registry = ToolRegistry()..registerAll(builtinTools);
      final result = await registry.execute(
        const ToolCall(id: 'c1', name: 'create_document', argumentsJson: ''),
      );
      // 空 arguments JSON → parseToolArguments 得空 Map → 参数校验报错
      //（但不是「未知工具」错误——说明路由到了正确 handler）
      expect(result.isError, isTrue);
      expect(result.content, isNot(contains('未知工具')));
    });
  });
}
