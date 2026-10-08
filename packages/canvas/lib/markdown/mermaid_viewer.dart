/// Mermaid 图放大查看器（独立弹窗：缩放 / 平移 / 重置）。
///
/// 由 [WbMarkdownView] 在点击 Mermaid 图块时以对话框打开；支持
/// 滚轮围绕指针缩放、拖拽平移、双击（按钮）重置为适应窗口。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';

import '../context_editors/context_editor_shell.dart';
import 'markdown_theme.dart';
import 'mermaid_parser.dart';
import 'mermaid_renderer.dart';

/// Mermaid 图放大查看器。
class WbMermaidViewer extends StatefulWidget {
  /// 创建查看器。
  const WbMermaidViewer({
    super.key,
    required this.code,
    this.theme = WbMarkdownTheme.light,
    this.title = 'Mermaid 图',
    this.layoutWidth,
    this.onClose,
  });

  /// Mermaid 源码。
  final String code;

  /// 渲染主题。
  final WbMarkdownTheme theme;

  /// 顶部标题。
  final String title;

  /// 布局宽度（应与内联文档宽度一致；类图 / ER 网格按同宽换行）。
  ///
  /// 为 null 时按默认宽度 960 布局；传无限宽会让网格永不换行、
  /// 全部排成单行（历史缺陷）。
  final double? layoutWidth;

  /// 关闭回调（null 时不显示关闭按钮）。
  final VoidCallback? onClose;

  /// 缩放范围。
  static const double minScale = 0.2;
  static const double maxScale = 5;

  /// 按钮缩放步长。
  static const double zoomStep = 1.25;

  @override
  State<WbMermaidViewer> createState() => _WbMermaidViewerState();
}

class _WbMermaidViewerState extends State<WbMermaidViewer> {
  late final WbMermaidBox _box;
  double _scale = 1;
  Offset _offset = Offset.zero;
  double _gestureStartScale = 1;
  Size _viewport = Size.zero;
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    final WbMermaidDiagram diagram = WbMermaidParser.parse(widget.code);
    _box = WbMermaidRenderer.layout(
      diagram,
      theme: widget.theme,
      // 有限宽布局：类图 / ER 网格换行与内联文档一致。
      maxWidth: widget.layoutWidth ?? 960,
      fontSize: widget.theme.baseFontSize - 1.5,
    );
  }

  /// 首次布局时缩放到适应视口并居中。
  void _ensureFit(Size viewport) {
    _viewport = viewport;
    if (_fitted || viewport.isEmpty || _box.size.isEmpty) {
      return;
    }
    _fitted = true;
    final double fit = math.min(
      1,
      math.min(
        (viewport.width - 32) / _box.size.width,
        (viewport.height - 32) / _box.size.height,
      ),
    );
    _scale = fit.clamp(WbMermaidViewer.minScale, WbMermaidViewer.maxScale);
    _offset = Offset(
      (viewport.width - _box.size.width * _scale) / 2,
      (viewport.height - _box.size.height * _scale) / 2,
    );
  }

  /// 平移限制：图中心保持在视口内（留 40px 边距）。
  Offset _clamped(Offset value) {
    if (_viewport.isEmpty) {
      return value;
    }
    final double w = _box.size.width * _scale;
    final double h = _box.size.height * _scale;
    const double margin = 40;
    final double cx = (value.dx + w / 2).clamp(
      math.min(margin, _viewport.width / 2),
      math.max(_viewport.width - margin, _viewport.width / 2),
    );
    final double cy = (value.dy + h / 2).clamp(
      math.min(margin, _viewport.height / 2),
      math.max(_viewport.height - margin, _viewport.height / 2),
    );
    return Offset(cx - w / 2, cy - h / 2);
  }

  /// 围绕视口点 [focal] 缩放（滚轮 / 按钮）。
  void _zoomAt(double factor, Offset focal) {
    if (_viewport.isEmpty) {
      return;
    }
    final double next = (_scale * factor).clamp(
      WbMermaidViewer.minScale,
      WbMermaidViewer.maxScale,
    );
    if (next == _scale) {
      return;
    }
    setState(() {
      final Offset diagramPoint = (focal - _offset) / _scale;
      _scale = next;
      _offset = _clamped(focal - diagramPoint * _scale);
    });
  }

  /// 重置为适应窗口。
  void _resetToFit() {
    setState(() {
      _fitted = false;
      _ensureFit(_viewport);
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
      _zoomAt(event.scrollDelta.dy > 0 ? 0.9 : 1.1, event.localPosition);
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_viewport.isEmpty) {
      return;
    }
    setState(() {
      _scale = (_gestureStartScale * details.scale).clamp(
        WbMermaidViewer.minScale,
        WbMermaidViewer.maxScale,
      );
      _offset = _clamped(_offset + details.focalPointDelta);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('wb-md-mermaid-viewer'),
      color: widget.theme.background,
      child: Column(
        children: <Widget>[
          _buildToolbar(),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                _ensureFit(constraints.biggest);
                return Listener(
                  onPointerSignal: _onPointerSignal,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onDoubleTap: _resetToFit,
                    child: ClipRect(
                      child: CustomPaint(
                        size: constraints.biggest,
                        painter: _WbMermaidViewerPainter(
                          box: _box,
                          scale: _scale,
                          offset: _offset,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final WbMarkdownTheme theme = widget.theme;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: theme.background,
        border: Border(bottom: BorderSide(color: theme.border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(LinearIcons.page, size: 16, color: theme.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.foreground,
              ),
            ),
          ),
          WbEditorHint(
            '${(_scale * 100).round()}%',
            key: const ValueKey<String>('wb-md-mermaid-scale'),
          ),
          const SizedBox(width: 6),
          WbEditorIconButton(
            key: const ValueKey<String>('wb-md-mermaid-zoom-out'),
            icon: LinearIcons.zoomOut,
            tooltip: '缩小',
            onTap: () =>
                _zoomAt(1 / WbMermaidViewer.zoomStep, _viewport.center(Offset.zero)),
          ),
          WbEditorIconButton(
            key: const ValueKey<String>('wb-md-mermaid-zoom-in'),
            icon: LinearIcons.zoomIn,
            tooltip: '放大',
            onTap: () =>
                _zoomAt(WbMermaidViewer.zoomStep, _viewport.center(Offset.zero)),
          ),
          WbEditorIconButton(
            key: const ValueKey<String>('wb-md-mermaid-reset'),
            icon: LinearIcons.refresh,
            tooltip: '重置缩放',
            onTap: _resetToFit,
          ),
          if (widget.onClose != null)
            WbEditorIconButton(
              key: const ValueKey<String>('wb-md-mermaid-close'),
              icon: LinearIcons.close,
              tooltip: '关闭',
              onTap: widget.onClose!,
            ),
        ],
      ),
    );
  }
}

/// 查看器画笔（按缩放 / 平移绘制图盒）。
class _WbMermaidViewerPainter extends CustomPainter {
  const _WbMermaidViewerPainter({
    required this.box,
    required this.scale,
    required this.offset,
  });

  final WbMermaidBox box;
  final double scale;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    box.draw(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WbMermaidViewerPainter oldDelegate) {
    return oldDelegate.box != box ||
        oldDelegate.scale != scale ||
        oldDelegate.offset != offset;
  }
}
