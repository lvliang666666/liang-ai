import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 全局构建异常兜底页（全局返回导航与灰屏治理批次·需求二③）
///
/// Flutter 默认 ErrorWidget.builder 在 release 下渲染纯灰底（debug 下
/// 红黄错误屏）——build 阶段抛异常（空安全/越界/布局约束）时整屏不可
/// 用且无任何可读信息。本兜底把异常渲染为可读错误页：
/// - 错误图标 + 「页面出错了」标题 + 异常摘要（debug 显示堆栈首行）
/// - 「重试」按钮：重建整棵子树（换 key 强制全新 Element 树）
/// - 「返回」按钮：Navigator.maybePop 回上一页（根页面时按钮隐藏）
///
/// 注册时机：main() 里 runApp 前设置一次，全 app 生效。
/// 注意：ErrorWidget.builder 只兜 build 阶段同步异常；异步异常走
/// FlutterError.onError / PlatformDispatcher.onError（诊断日志已挂）。

/// 全局错误页重建 key 流转（重试时自增，强制子树重建）
ValueNotifier<int> kErrorPageRetryGeneration = ValueNotifier(0);

/// 注册全局 ErrorWidget.builder（main 调用一次）
void installGlobalErrorWidget() {
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final exception = details.exception;
    final stackLine = details.stack == null
        ? ''
        : details.stack!.toString().split('\n').take(3).join('\n');
    return GlobalErrorPage(
      summary: exception.toString(),
      stackHead: kDebugMode ? stackLine : '',
    );
  };
}

/// 全局错误页：错误图标 + 摘要 + 重试/返回
///
/// 公开类（widget 测试直接 pump 验证渲染结构——flutter_test 禁止测试
/// 修改 ErrorWidget.builder，只能绕道测组件本体）
class GlobalErrorPage extends StatelessWidget {
  const GlobalErrorPage({
    super.key,
    required this.summary,
    this.stackHead = '',
  });

  /// 异常摘要（可读化：截断到 300 字防超长堆栈撑爆布局）
  final String summary;

  /// 堆栈首 3 行（仅 debug 显示，release 不暴露内部路径）
  final String stackHead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 56, color: cs.error),
                const SizedBox(height: 16),
                Text('页面出错了', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  summary.length > 300
                      ? '${summary.substring(0, 300)}…'
                      : summary,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                if (stackHead.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      stackHead,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                // 重试：自增 generation → MaterialApp builder 侧监听换 key
                // 重建整棵子树（ErrorWidget 场景下原子树已废，重建是
                // 唯一恢复路径）
                FilledButton.icon(
                  onPressed: () => kErrorPageRetryGeneration.value++,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                // 返回：仅当路由栈可 pop（二级页出错）时显示
                if (Navigator.canPop(context)) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回上一页'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
