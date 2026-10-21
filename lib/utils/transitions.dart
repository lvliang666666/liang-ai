import 'package:flutter/material.dart';

/// 统一页面转场：轻推滑入 + 淡入（iOS 式，比默认材质转场更轻快）
///
/// 全 app 的整页 push（设置页/Skill 编辑器等二级页）统一走此转场；
/// 图片查看器等透明覆盖层有自己的 Fade 转场，不走这里。
PageRoute<T> slideUpRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, animation, second, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.03),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
