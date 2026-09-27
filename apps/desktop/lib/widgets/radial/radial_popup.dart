/// 临时圆盘弹出：长按画布场景的弹层封装（文档 5.3）。
///
/// 以任意屏幕位置为中心弹出展开态圆盘：
/// - 点击外部 / 选中工具 / 无操作超时后关闭；
/// - 选中的工具 id 通过返回的 Future 上交宿主；
/// - 画布"空白长按"触发点由画布侧（CanvasView / 编辑页）接线调用
///   [RadialPopup.show]，组件本身不劫持画布手势。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../radial_toolbar.dart';
import 'radial_models.dart';

/// 临时圆盘弹出入口。
abstract final class RadialPopup {
  /// 以 [globalPosition] 为中心弹出临时圆盘。
  ///
  /// - [autoDismiss]：无操作自动淡出时长（默认 3 秒；传 null 不自动关闭）；
  /// - [onToolSelected]：选中工具回调（与返回的 Future 二选一/兼用均可）；
  /// - 返回：圆盘关闭后完成，值为选中的工具 id（未选中为 null）。
  static Future<String?> show(
    BuildContext context, {
    required Offset globalPosition,
    Duration? autoDismiss = const Duration(seconds: 3),
    RadialSettings settings = const RadialSettings(),
    ValueChanged<String>? onToolSelected,
    ValueChanged<String>? onAction,
  }) {
    final OverlayState overlay = Overlay.of(context);
    final Completer<String?> completer = Completer<String?>();

    // 布局外框半宽：底盘 240 / 2 与子环外缘 180 取大者（360 / 2），
    // 保证圆盘圆心与弹出位置对齐、子环命中区完整。
    final double half = 180 * settings.size.scale;

    late final OverlayEntry entry;

    void close([String? toolId]) {
      if (completer.isCompleted) {
        return;
      }
      if (entry.mounted) {
        entry.remove();
      }
      completer.complete(toolId);
    }

    entry = OverlayEntry(
      builder: (BuildContext context) {
        return Stack(
          children: <Widget>[
            // 透明遮罩：点击外部关闭（弹出期间画布交互被临时接管）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => close(),
                onSecondaryTapUp: (TapUpDetails details) => close(),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: globalPosition.dx - half,
              top: globalPosition.dy - half,
              child: RadialToolbar(
                initialExpanded: true,
                autoDismiss: autoDismiss != null,
                autoDismissAfter: autoDismiss ?? const Duration(seconds: 3),
                initialSettings: settings,
                onDismissed: () => close(),
                onToolSelected: (String id) {
                  onToolSelected?.call(id);
                  close(id);
                },
                onAction: (String id) {
                  onAction?.call(id);
                  close(id);
                },
              ),
            ),
          ],
        );
      },
    );

    overlay.insert(entry);
    return completer.future;
  }
}
