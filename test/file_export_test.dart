import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ai_chat_app/services/file_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDir;

  setUpAll(() {
    testDir = Directory.systemTemp.createTempSync('export_test');
    // mock path_provider：固定目录（同名冲突测试需要同一目录）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => testDir.path,
    );
    // mock share_plus：单测环境无平台插件；空字符串 = dismissed（用户取消语义）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async => '',
    );
  });

  tearDownAll(() async {
    // Windows 上文件句柄释放有延迟，失败不阻塞测试
    try {
      await Future.delayed(const Duration(milliseconds: 200));
      testDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('FileExportService 纯逻辑', () {
    test('文件名安全化：非法字符替换为下划线', () {
      // 通过导出行为间接测试 _sanitize（私有方法）
      // 直接验证：导出时文件名含非法字符不抛异常
      expect(FileExportService.export(
        content: 'test',
        fileNameBase: 'a/b\\c:d*e?f"g<h>i|j',
        format: ExportFormat.plainText,
      ), completes);
    });

    test('导出 txt：内容为纯文本', () async {
      final path = await FileExportService.export(
        content: '# 标题\n\n**加粗** 和 `代码`',
        fileNameBase: 'test_export_txt',
        format: ExportFormat.plainText,
      );
      expect(path.endsWith('.txt'), isTrue);
      final content = await File(path).readAsString();
      expect(content, contains('标题'));
      expect(content, contains('加粗'));
      expect(content, isNot(contains('#')));
      expect(content, isNot(contains('**')));
      // 清理
      await File(path).delete();
    });

    test('导出 md：内容原样保留', () async {
      final md = '# 报告\n\n- 要点一\n- 要点二';
      final path = await FileExportService.export(
        content: md,
        fileNameBase: 'test_export_md',
        format: ExportFormat.markdown,
      );
      expect(path.endsWith('.md'), isTrue);
      final content = await File(path).readAsString();
      expect(content, md);
      await File(path).delete();
    });

    test('导出 html：包含完整 HTML 结构与正文', () async {
      final path = await FileExportService.export(
        content: '# 季度报告\n\n| 指标 | 值 |\n|---|---|\n| 营收 | 100万 |',
        fileNameBase: 'test_export_html',
        format: ExportFormat.html,
      );
      expect(path.endsWith('.html'), isTrue);
      final content = await File(path).readAsString();
      expect(content, contains('<!DOCTYPE html>'));
      expect(content, contains('<table>'));
      expect(content, contains('季度报告'));
      await File(path).delete();
    });

    test('同名文件自动加序号', () async {
      final p1 = await FileExportService.export(
        content: 'v1',
        fileNameBase: 'test_dup',
        format: ExportFormat.plainText,
      );
      final p2 = await FileExportService.export(
        content: 'v2',
        fileNameBase: 'test_dup',
        format: ExportFormat.plainText,
      );
      expect(p1, isNot(p2));
      expect(p2, contains('(1)'));
      expect(await File(p1).readAsString(), 'v1');
      expect(await File(p2).readAsString(), 'v2');
      await File(p1).delete();
      await File(p2).delete();
    });

    test('空文件名回退为 export', () async {
      final path = await FileExportService.export(
        content: 'x',
        fileNameBase: '   ',
        format: ExportFormat.plainText,
      );
      expect(path, contains('export'));
      await File(path).delete();
    });
  });

  group('FileExportService.share 分享导出', () {
    test('分享 txt：文件写入临时目录且内容为纯文本', () async {
      final result = await FileExportService.share(
        content: '# 标题\n**加粗**',
        fileNameBase: 'share_test_txt',
        format: ExportFormat.plainText,
      );
      // mock 返回空字符串 → dismissed（用户取消语义），不抛异常即通过
      expect(result, isNotNull);
      expect(result!.status, ShareResultStatus.dismissed);
      // 文件已落盘到临时目录
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/share_test_txt.txt');
      expect(file.existsSync(), isTrue);
      final content = await file.readAsString();
      expect(content, contains('标题'));
      expect(content, isNot(contains('#')));
      expect(content, isNot(contains('**')));
      await file.delete();
    });

    test('分享 md：内容原样保留', () async {
      final md = '# 报告\n\n- 要点一';
      await FileExportService.share(
        content: md,
        fileNameBase: 'share_test_md',
        format: ExportFormat.markdown,
      );
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/share_test_md.md');
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(), md);
      await file.delete();
    });

    test('分享 html：包含完整 HTML 结构', () async {
      await FileExportService.share(
        content: '# 季度报告',
        fileNameBase: 'share_test_html',
        format: ExportFormat.html,
      );
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/share_test_html.html');
      expect(file.existsSync(), isTrue);
      final content = await file.readAsString();
      expect(content, contains('<!DOCTYPE html>'));
      expect(content, contains('季度报告'));
      await file.delete();
    });

    test('分享文件名安全化：非法字符不抛异常', () async {
      await FileExportService.share(
        content: 'x',
        fileNameBase: 'a/b\\c:d*e?f"g<h>i|j',
        format: ExportFormat.plainText,
      );
      final tmpDir = await getTemporaryDirectory();
      final files = tmpDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('a_b_c_d_e_f_g_h_i_j'))
          .toList();
      expect(files, isNotEmpty);
      for (final f in files) {
        await f.delete();
      }
    });
  });
}
