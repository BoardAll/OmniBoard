/// 页面管理（桌面转发层）。
///
/// [PageManager] / [PageThumbnail] / [WbVisibilityIcon] /
/// [WbPageBackgroundEditResult] 的实现已下沉共享包 `whiteboard_canvas`
/// （`widgets/page_manager.dart`，与 Web 端同一实现）；本文件仅为兼容
/// 既有导入路径的转发面。
///
/// 桌面背景对话框见 `page_background_dialog.dart`
/// （经 `PageManager.onEditBackground` 注入）；缩略图背景图片经
/// `PageManager.previewImageProvider` 注入 `FileImage`。
library;

export 'package:whiteboard_canvas/widgets/page_manager.dart';
