import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';

/// base64 图片缩略图：解码一次缓存 ImageProvider，流式重建时不闪烁
///
/// 用 CacheableImageProvider（key 稳定）+ 低分辨率解码（cacheWidth），
/// 避免每次 build 重新 base64Decode 导致的图片缓存失效与反复解码。
class AttachmentThumbnail extends StatelessWidget {
  const AttachmentThumbnail({
    super.key,
    required this.base64,
    this.size = 96,
    this.borderRadius = 8,
    this.fit = BoxFit.cover,
  });

  final String base64;
  final double size;
  final double borderRadius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: Image(
          image: _CachedBase64ImageProvider(base64, decodeSize: size.round()),
          fit: fit,
          // 解码期间与失败时都显示占位，不闪白
          frameBuilder: (context, child, frame, wasSync) =>
              frame == null ? _placeholder(context) : child,
          errorBuilder: (_, __, ___) => _placeholder(context, broken: true),
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context, {bool broken = false}) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        broken ? Icons.broken_image_outlined : Icons.image_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// base64 图片 Provider：以 base64 哈希为缓存 key，bytes 只解码一次
class _CachedBase64ImageProvider extends ImageProvider<_CachedBase64ImageProvider> {
  _CachedBase64ImageProvider(this.base64, {required this.decodeSize});

  final String base64;

  /// 缩略图解码目标尺寸（降采样省内存）
  final int decodeSize;

  @override
  Future<_CachedBase64ImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_CachedBase64ImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
      _CachedBase64ImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key),
      scale: 1.0,
    );
  }

  Future<ui.Codec> _loadAsync(_CachedBase64ImageProvider key) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(
        base64Decode(key.base64));
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    // 按显示尺寸降采样解码（缩略图不需要全分辨率）
    final target = key.decodeSize;
    final codec = await descriptor.instantiateCodec(
      targetWidth:
          descriptor.width > target ? target : descriptor.width,
      targetHeight:
          descriptor.height > target ? target : descriptor.height,
    );
    return codec;
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedBase64ImageProvider &&
      other.base64 == base64 &&
      other.decodeSize == decodeSize;

  @override
  int get hashCode => Object.hash(base64.hashCode, decodeSize);
}
