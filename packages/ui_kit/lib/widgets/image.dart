import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../foundation/colors.dart';
import '../foundation/radius.dart';

/// 基础图片组件（跨平台：不依赖 dart:io，Web 兼容）。
///
/// 提供统一的加载占位与错误占位；本地文件请先读取为字节后用 [WbImage.memory]。
class WbImage extends StatelessWidget {
  /// 网络图片。
  const WbImage.network(
    String url, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.radius,
    this.backgroundColor,
  })  : _providerBuilder = _network,
        urlOrName = url,
        bytes = null;

  /// 内存图片（本地文件读取的字节）。
  const WbImage.memory(
    Uint8List data, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.radius,
    this.backgroundColor,
  })  : _providerBuilder = _memory,
        bytes = data,
        urlOrName = null;

  /// 资源图片。
  const WbImage.asset(
    String name, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.radius,
    this.backgroundColor,
  })  : _providerBuilder = _asset,
        urlOrName = name,
        bytes = null;

  /// 图片地址或资源名（按构造方式解释）。
  final String? urlOrName;

  /// 内存字节。
  final Uint8List? bytes;

  final double? width;
  final double? height;
  final BoxFit fit;

  /// 圆角半径；null 表示无圆角。
  final double? radius;
  final Color? backgroundColor;

  final ImageProvider Function(WbImage image) _providerBuilder;

  static ImageProvider _network(WbImage image) => NetworkImage(image.urlOrName!);

  static ImageProvider _memory(WbImage image) => MemoryImage(image.bytes!);

  static ImageProvider _asset(WbImage image) => AssetImage(image.urlOrName!);

  /// 占位/兜底底色。
  Color _placeholderColor(BuildContext context) =>
      backgroundColor ?? Theme.of(context).colorScheme.surfaceContainerHighest;

  Widget _placeholder(BuildContext context, {required bool isError}) {
    return Container(
      width: width,
      height: height,
      color: _placeholderColor(context),
      alignment: Alignment.center,
      child: Icon(
        isError ? Icons.broken_image_outlined : Icons.image_outlined,
        size: 20,
        color: WbColors.gray400,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget image = Image(
      image: _providerBuilder(this),
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) =>
          _placeholder(context, isError: true),
      frameBuilder: (
        BuildContext context,
        Widget child,
        int? frame,
        bool wasSynchronouslyLoaded,
      ) {
        if (wasSynchronouslyLoaded || frame != null) {
          return child;
        }
        return _placeholder(context, isError: false);
      },
    );
    if (radius != null && radius! > 0) {
      image = ClipRRect(borderRadius: WbRadius.circular(radius!), child: image);
    }
    return image;
  }
}
