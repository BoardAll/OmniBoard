import 'dart:ui';

/// 布局与几何工具（纯函数，无副作用）。
abstract final class WbLayoutUtils {
  // ---- 响应式断点（桌面窗口宽度）----
  static const double compactBreakpoint = 600;
  static const double mediumBreakpoint = 840;
  static const double expandedBreakpoint = 1200;

  /// 紧凑宽度（窄窗口，侧栏默认折叠）。
  static bool isCompact(double width) => width < compactBreakpoint;

  /// 中等宽度。
  static bool isMedium(double width) =>
      width >= compactBreakpoint && width < expandedBreakpoint;

  /// 宽屏（侧栏与 AI 面板可同时展开）。
  static bool isExpanded(double width) => width >= expandedBreakpoint;

  // ---- 白板缩放 ----
  /// 最小缩放。
  static const double minZoom = 0.1;

  /// 最大缩放。
  static const double maxZoom = 8.0;

  /// 将缩放值限制在 [minZoom] ~ [maxZoom]。
  static double clampZoom(double zoom) => zoom.clamp(minZoom, maxZoom);

  /// 吸附尺寸（对齐 C++ 布局域的默认吸附阈值）。
  static const double snapThreshold = 6.0;

  /// 将坐标吸附到网格（[gridSize] ≤ 0 时原样返回）。
  static Offset snapToGrid(Offset point, double gridSize) {
    if (gridSize <= 0) {
      return point;
    }
    return Offset(
      (point.dx / gridSize).round() * gridSize,
      (point.dy / gridSize).round() * gridSize,
    );
  }

  /// 保证矩形不小于最小尺寸（居中扩展）。
  static Rect ensureMinSize(Rect rect, Size minSize) {
    double width = rect.width;
    double height = rect.height;
    double left = rect.left;
    double top = rect.top;
    if (width < minSize.width) {
      left -= (minSize.width - width) / 2;
      width = minSize.width;
    }
    if (height < minSize.height) {
      top -= (minSize.height - height) / 2;
      height = minSize.height;
    }
    return Rect.fromLTWH(left, top, width, height);
  }

  /// 计算使 [content] 完整可见（fit）所需的平移偏移。
  ///
  /// [viewport] 为可视区域，[padding] 为四周留白。
  static Offset centerOffset(Size content, Size viewport, {double padding = 0}) {
    if (content.width >= viewport.width - padding * 2 &&
        content.height >= viewport.height - padding * 2) {
      return Offset.zero;
    }
    return Offset(
      (viewport.width - content.width) / 2,
      (viewport.height - content.height) / 2,
    );
  }

  /// 适合视口的缩放比例（fit 到 [viewport]，[padding] 四周留白）。
  static double fitZoom(Size content, Size viewport, {double padding = 0}) {
    if (content.width <= 0 || content.height <= 0) {
      return 1.0;
    }
    final double availableW = (viewport.width - padding * 2).clamp(1, double.infinity);
    final double availableH = (viewport.height - padding * 2).clamp(1, double.infinity);
    final double scale = (availableW / content.width) < (availableH / content.height)
        ? availableW / content.width
        : availableH / content.height;
    return clampZoom(scale);
  }
}
