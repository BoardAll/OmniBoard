/// Markdown 预览渲染 widget（编辑器 / 阅读器 / 任意宿主复用）。
///
/// 高度按内容自适应（外层可套 `SingleChildScrollView` 滚动）；
/// 渲染走 [WbMarkdownRenderCache]（同 source/宽度/主题零重复 Parse）；
/// 点击 Mermaid 图块弹出 [WbMermaidViewer] 放大查看。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../canvas/canvas_model.dart';
import 'markdown_layout.dart';
import 'markdown_painter.dart';
import 'markdown_theme.dart';
import 'mermaid_viewer.dart';

/// Markdown 预览渲染。
class WbMarkdownView extends StatelessWidget {
  /// 创建预览。
  const WbMarkdownView({
    super.key,
    required this.source,
    this.theme = WbMarkdownTheme.light,
    this.searchQuery = '',
    this.textCache,
    this.cachePrefix = '',
    this.background = false,
    this.minHeight = 0,
    this.mermaidInteractive = true,
  });

  /// Markdown 源文本。
  final String source;

  /// 渲染主题。
  final WbMarkdownTheme theme;

  /// 搜索高亮词（空 = 不高亮）。
  final String searchQuery;

  /// 文本布局缓存（画布侧传入以复用）。
  final WbCanvasTextCache? textCache;

  /// 文本缓存 key 前缀（建议元素 id）。
  final String cachePrefix;

  /// 是否绘制卡片背景（预览场景由容器决定）。
  final bool background;

  /// 最小高度（不足时以空白占位）。
  final double minHeight;

  /// 点击 Mermaid 图块是否弹出放大查看器（默认开）。
  final bool mermaidInteractive;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth.isFinite &&
                constraints.maxWidth > 0
            ? constraints.maxWidth
            : 400;
        final double height = WbMarkdownPainter.measureHeight(
          source,
          width,
          theme: theme,
          textCache: textCache,
          cachePrefix: cachePrefix,
        );
        final double resolvedHeight =
            height < minHeight ? minHeight : height;
        return SizedBox(
          width: width,
          height: resolvedHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: mermaidInteractive
                ? (TapUpDetails details) =>
                    _handleTap(context, details.localPosition, width)
                : null,
            child: CustomPaint(
              painter: _WbMarkdownViewPainter(
                source: source,
                theme: theme,
                searchQuery: searchQuery,
                textCache: textCache,
                cachePrefix: cachePrefix,
                background: background,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 点击命中 Mermaid 图块时弹出放大查看器。
  void _handleTap(BuildContext context, Offset local, double width) {
    final WbMdLayoutResult result = WbMarkdownRenderCache.layoutFor(
      source: source,
      width: width,
      theme: theme,
      textCache: textCache,
      cachePrefix: cachePrefix,
    );
    for (final WbMdDrawOp op in result.ops) {
      if (op.mermaidCode.isEmpty || !op.rect.contains(local)) {
        continue;
      }
      _openViewer(context, op.mermaidCode, width);
      return;
    }
  }

  /// 弹出图查看器（尺寸随窗口自适应；布局宽沿用内联宽度）。
  void _openViewer(BuildContext context, String code, double layoutWidth) {
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (BuildContext dialogContext) {
        final Size screen = MediaQuery.sizeOf(dialogContext);
        final double viewerWidth = math.min(screen.width - 48, 960);
        final double viewerHeight = math.min(screen.height - 96, 720);
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          backgroundColor: theme.background,
          child: SizedBox(
            width: viewerWidth,
            height: viewerHeight,
            child: WbMermaidViewer(
              code: code,
              theme: theme,
              layoutWidth: layoutWidth,
              onClose: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        );
      },
    );
  }
}

/// 预览画笔。
class _WbMarkdownViewPainter extends CustomPainter {
  const _WbMarkdownViewPainter({
    required this.source,
    required this.theme,
    required this.searchQuery,
    required this.textCache,
    required this.cachePrefix,
    required this.background,
  });

  final String source;
  final WbMarkdownTheme theme;
  final String searchQuery;
  final WbCanvasTextCache? textCache;
  final String cachePrefix;
  final bool background;

  @override
  void paint(Canvas canvas, Size size) {
    WbMarkdownPainter.paint(
      canvas,
      Offset.zero & size,
      source: source,
      theme: theme,
      textCache: textCache,
      cachePrefix: cachePrefix,
      searchQuery: searchQuery,
      background: background,
    );
  }

  @override
  bool shouldRepaint(covariant _WbMarkdownViewPainter oldDelegate) {
    return oldDelegate.source != source ||
        oldDelegate.theme.id != theme.id ||
        oldDelegate.searchQuery != searchQuery ||
        oldDelegate.background != background ||
        oldDelegate.cachePrefix != cachePrefix;
  }
}
