/// 缩放控件：缩小 / 百分比（点击重置 100%）/ 放大 / 适应内容。
///
/// 位于画布右下区域（迷你地图下方），与 `WbCanvasController` 的视口
/// API 直接绑定；所有按钮在测试中按 key 引用（见 [WbZoomControls] 文档）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'canvas_controller.dart';
import 'canvas_tool_palette.dart';

/// 缩放控件。
///
/// key 约定：`wb-zoom-out` / `wb-zoom-reset`（百分比，点击重置）/
/// `wb-zoom-in` / `wb-zoom-fit`。
class WbZoomControls extends StatelessWidget {
  /// 创建控件。
  const WbZoomControls({super.key, required this.controller});

  /// 画布控制器。
  final WbCanvasController controller;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final int percent = (controller.scale * 100).round();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: wbCanvasPanelDecoration(colors),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              WbCanvasIconButton(
                key: const Key('wb-zoom-out'),
                icon: LinearIcons.zoomOut,
                tooltip: '缩小 (Ctrl+-)',
                onTap: () => controller.zoomBy(1 / 1.2),
              ),
              _PercentLabel(
                key: const Key('wb-zoom-reset'),
                percent: percent,
                onTap: () => controller.resetView(),
              ),
              WbCanvasIconButton(
                key: const Key('wb-zoom-in'),
                icon: LinearIcons.zoomIn,
                tooltip: '放大 (Ctrl+=)',
                onTap: () => controller.zoomBy(1.2),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Container(width: 1, height: 18, color: colors.border),
              ),
              WbCanvasIconButton(
                key: const Key('wb-zoom-fit'),
                icon: LinearIcons.fitScreen,
                tooltip: '适应内容 (Ctrl+1)',
                onTap: () => controller.fitToContent(),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 缩放百分比标签（点击重置为 100% 且平移归零）。
class _PercentLabel extends StatelessWidget {
  const _PercentLabel({super.key, required this.percent, required this.onTap});

  final int percent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: '重置视图 (Ctrl+0)',
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          hoverColor: colors.hover,
          child: SizedBox(
            width: 52,
            height: 32,
            child: Center(
              child: Text(
                '$percent%',
                style: TextStyle(fontSize: 12, color: colors.toolbarIcon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
