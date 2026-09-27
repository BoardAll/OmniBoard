/// 透明批注组合层：覆盖层画布 + 右上角工具栏 + 退出弹窗。
///
/// 挂载方式（由集成方在主界面 Stack 顶层使用）：
/// ```dart
/// Stack(children: <Widget>[
///   board,
///   AnnotationLayer(controller: annotationController),
/// ])
/// ```
/// 未进入透明批注模式时渲染 [SizedBox.shrink]，不拦截任何事件。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'annotation_controller.dart';
import 'annotation_exit_dialog.dart';
import 'annotation_overlay.dart';
import 'annotation_toolbar.dart';

/// 透明批注组合层（把画布 / 工具栏 / 弹窗按 §9.1 布局组合）。
class AnnotationLayer extends StatelessWidget {
  const AnnotationLayer({super.key, required this.controller});

  /// 批注控制器（组合层只负责布局与转发，不持有额外状态）。
  final WbAnnotationController controller;

  /// 工具栏距右边 / 顶边的距离（文档 §9.1：24px）。
  static const double edgeInset = 24;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        if (!controller.isActive) {
          return const SizedBox.shrink();
        }
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 画布在下层：批注态捕获指针，穿透态由内部 IgnorePointer 放行。
            Positioned.fill(child: AnnotationOverlay(controller: controller)),
            // 工具栏在上层且固定右上角（§9.1 / §9.3：工具栏始终可点击）。
            Positioned(
              top: edgeInset,
              right: edgeInset,
              child: AnnotationToolbar(controller: controller),
            ),
            // 退出弹窗（§5.4）位于最顶层，遮挡工具栏与画布。
            if (controller.exitDialogVisible)
              Positioned.fill(
                child: WbAnnotationExitDialog(
                  strokeCount: controller.state.strokeCount,
                  saving: controller.isSaving,
                  errorText: controller.lastError,
                  onChoice: (WbAnnotationExitChoice choice) =>
                      unawaited(controller.chooseExit(choice)),
                ),
              ),
          ],
        );
      },
    );
  }
}
