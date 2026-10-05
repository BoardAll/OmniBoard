/// 图层区（桌面转发层）。
///
/// [LayersPanel] / [WbLayerTypeVisual] / [wbLayerTypeVisual] /
/// [wbLayerDisplayName] / [resetDemoLayers] 的实现已下沉共享包
/// `whiteboard_canvas`（`widgets/layers_panel.dart`，与 Web 端同一实现）；
/// 本文件仅为兼容既有导入路径的转发面。
///
/// 引擎数据源经 provider 提供 [WbCanvasEngine]（桌面为 `WbFfiCanvasEngine`，
/// 包装 `WbFfiService`）；未提供时降级为演示缓存。
library;

export 'package:whiteboard_canvas/widgets/layers_panel.dart';
