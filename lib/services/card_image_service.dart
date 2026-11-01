import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/card.dart' as card_model;

/// 卡片图片分享服务（打磨批次 W2）：把卡片渲染成 PNG 分享出去
///
/// 用户反馈：点开卡片后能直接把这张卡片以图片形式分享。实现走
/// Flutter 自带离屏渲染（零新插件）：
/// 1. 详情页把用户看到的卡片本体包在 RepaintBoundary（GlobalKey）
/// 2. 分享时 findRenderObject 取 RenderRepaintBoundary → toImage(3x)
/// 3. PNG 字节写临时文件 → SharePlus 系统分享面板（QQ/微信收图）
///
/// 所见即所得：截的就是用户正在看的那张卡片，无需离屏挂载。
/// 返回值：true=已调起分享 / null=用户取消 / false=渲染或写盘失败。
class CardImageService {
  /// 分享图片文件名前缀（临时目录，分享后由系统处理）
  static const fileNameBase = 'liang_ai_card';

  /// 截图像素密度（3x：真机分享出去的图清晰不糊）
  static const pixelRatio = 3.0;

  /// 从已挂载的 RepaintBoundary 渲染 PNG 字节（失败返回 null）
  ///
  /// [boundaryKey] 必须挂在组件树上已布局绘制的 RepaintBoundary
  /// （GlobalKey.currentContext → findRenderObject）。
  static Future<Uint8List?> renderFromBoundary(GlobalKey boundaryKey) async {
    try {
      final renderObject = boundaryKey.currentContext?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) return null;
      final image = await renderObject.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// 渲染 + 写临时文件 + 调起系统分享
  static Future<bool?> shareCardImage(
    GlobalKey boundaryKey,
    card_model.Card card,
  ) async {
    final bytes = await renderFromBoundary(boundaryKey);
    if (bytes == null || bytes.isEmpty) return false;
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$fileNameBase.png';
      await File(path).writeAsBytes(bytes, flush: true);
      final result = await SharePlus.instance.share(ShareParams(
        files: [XFile(path, mimeType: 'image/png')],
        fileNameOverrides: ['$fileNameBase.png'],
        text: card.title,
      ));
      return result.status == ShareResultStatus.success ? true : null;
    } catch (_) {
      return false;
    }
  }
}
