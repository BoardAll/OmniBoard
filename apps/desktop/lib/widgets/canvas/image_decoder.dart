/// 桌面图片解码器：本地文件路径 → `ui.Image`。
///
/// `whiteboard_canvas` 共享包的 `WbCanvasImageCache` 平台中立（不依赖
/// 任何平台 IO），解码器由宿主注入：
/// - 桌面端注入本文件的 [wbDecodeImageFile]（`dart:io` 读字节 + 引擎
///   解码首帧）；
/// - Web 端由 apps/web 注入网络 / 内存字节解码实现。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 读取本地文件字节并以 Flutter 图像编解码器解码首帧。
Future<ui.Image> wbDecodeImageFile(String path) async {
  final Uint8List bytes = await File(path).readAsBytes();
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  final ui.FrameInfo frame = await codec.getNextFrame();
  return frame.image;
}
