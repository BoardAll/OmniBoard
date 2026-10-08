/// 白板文件编解码（`.wbd`：UTF-8 JSON 信封）。
///
/// 实现已下沉共享包
/// `whiteboard_canvas/lib/services/board_file_codec.dart`（桌面 / Web
/// 两端共用同一 `.wbd` 格式，保证文件互通）；本文件仅转发导出，
/// 兼容既有 `services/board_file_codec.dart` 导入路径与符号引用。
library;

export 'package:whiteboard_canvas/services/board_file_codec.dart';
