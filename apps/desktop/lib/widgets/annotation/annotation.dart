/// 透明批注 UI 组件库（《透明批注模式技术方案》§4-§9 的 Flutter 实现）。
///
/// 模块：
/// - [WbAnnotationState]：模式 / 笔迹 / 笔刷数据状态（`state/annotation_state.dart`）；
/// - [WbAnnotationController]：状态机与流程编排（进入退出 / 快捷键 / 保存）；
/// - [AnnotationLayer]：组合层（画布 + 工具栏 + 弹窗，挂到主界面 Stack）；
/// - [AnnotationOverlay]：覆盖层画布（本地绘制 / 擦除 / 激光笔渐隐）；
/// - [AnnotationToolbar]：右上角悬浮工具栏；
/// - [WbAnnotationExitDialog]：退出三选项弹窗。
library;

export '../../state/annotation_state.dart';
export 'annotation_controller.dart';
export 'annotation_exit_dialog.dart';
export 'annotation_layer.dart';
export 'annotation_overlay.dart';
export 'annotation_toolbar.dart';
