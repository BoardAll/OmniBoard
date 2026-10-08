/// Markdown 全屏阅读器（滚动 / 缩放 / 全文搜索 / 目录侧栏 / 编辑入口）。
///
/// 依据《OmniBoard Markdown 渲染与交互实现方案》§16：
/// - 顶部工具条：标识 / 标题 / 目录开关 / 搜索框（命中数）/ 缩放 / 编辑 /
///   退出；
/// - 左侧目录侧栏：由布局结果的 Heading 锚点生成，点击滚动定位；
/// - 正文：按「虚拟宽度布局 + Transform.scale」实现真实缩放（字号与
///   换行宽度同步放大，滚动范围随缩放变化）；
/// - 搜索为源码级子串高亮（非分词），渲染走 [WbMarkdownView]。
///
/// 组件自包含（无 Provider / FFI 依赖），由宿主以全屏容器挂载
/// （桌面 `showGeneralDialog` / Web `showDialog` Dialog.fullscreen）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../canvas/canvas_model.dart';
import '../context_editors/context_editor_shell.dart';
import 'markdown_layout.dart';
import 'markdown_painter.dart';
import 'markdown_theme.dart';
import 'markdown_view.dart';

/// Markdown 全屏阅读器。
class WbMarkdownReader extends StatefulWidget {
  /// 创建阅读器。
  const WbMarkdownReader({
    super.key,
    required this.source,
    this.title = 'Markdown 阅读',
    this.theme = WbMarkdownTheme.light,
    this.onEdit,
    this.onClose,
  });

  /// Markdown 源文本。
  final String source;

  /// 顶部标题（宿主可传元素名 / 首标题）。
  final String title;

  /// 渲染主题。
  final WbMarkdownTheme theme;

  /// 编辑入口回调（null 时不显示编辑按钮）。
  final VoidCallback? onEdit;

  /// 退出回调（null 时不显示关闭按钮）。
  final VoidCallback? onClose;

  /// 目录侧栏宽度。
  static const double tocWidth = 220;

  /// 正文水平内边距。
  static const double contentPadding = 24;

  /// 缩放范围 / 步长。
  static const double minZoom = 0.5;
  static const double maxZoom = 2.0;
  static const double zoomStep = 0.1;

  @override
  State<WbMarkdownReader> createState() => _WbMarkdownReaderState();
}

class _WbMarkdownReaderState extends State<WbMarkdownReader> {
  final WbCanvasTextCache _textCache = WbCanvasTextCache();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _query = '';
  bool _showToc = true;
  double _zoom = 1.0;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 源码级子串命中计数（与渲染层高亮口径一致：不区分大小写）。
  int _countMatches(String source, String query) {
    if (query.isEmpty) {
      return 0;
    }
    final String lower = source.toLowerCase();
    final String needle = query.toLowerCase();
    int count = 0;
    int index = 0;
    while (true) {
      final int found = lower.indexOf(needle, index);
      if (found < 0) {
        return count;
      }
      count++;
      index = found + needle.length;
    }
  }

  void _zoomBy(double delta) {
    setState(() {
      _zoom = (_zoom + delta).clamp(
        WbMarkdownReader.minZoom,
        WbMarkdownReader.maxZoom,
      );
    });
  }

  void _jumpToHeading(double top) {
    if (!_scrollController.hasClients) {
      return;
    }
    final double target = math.max(0, top * _zoom - 12);
    final double max = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      math.min(target, max),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    // 正文「虚拟宽度」：视口按缩放反算，目录与正文共用同一口径
    // （Heading 锚点坐标与正文布局一一对应）。
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double tocWidth = _showToc ? WbMarkdownReader.tocWidth : 0;
    final double viewport = math.max(260, screenWidth - tocWidth - 2);
    final double virtualWidth = math.max(
      280,
      (viewport - WbMarkdownReader.contentPadding * 2) / _zoom,
    );
    final WbMdLayoutResult layout = WbMarkdownRenderCache.layoutFor(
      source: widget.source,
      width: virtualWidth,
      theme: widget.theme,
      textCache: _textCache,
      cachePrefix: 'wb-md-reader',
    );

    return Material(
      key: const ValueKey<String>('wb-md-reader'),
      color: colors.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildToolbar(colors),
          Divider(height: 1, thickness: 1, color: colors.cardBorder),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_showToc) ...<Widget>[
                  _buildToc(colors, layout.headings),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: colors.cardBorder,
                  ),
                ],
                Expanded(child: _buildDocument(virtualWidth, layout.height)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部工具条。
  Widget _buildToolbar(WbThemeColors colors) {
    final int matches = _countMatches(widget.source, _query);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: <Widget>[
          Icon(LinearIcons.page, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              widget.title,
              style: WbTypography.title.copyWith(color: colors.icon),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          WbEditorIconButton(
            key: const ValueKey<String>('wb-md-reader-toc-toggle'),
            icon: LinearIcons.menu,
            tooltip: '目录',
            active: _showToc,
            onTap: () => setState(() => _showToc = !_showToc),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 240,
            child: TextField(
              key: const ValueKey<String>('wb-md-reader-search'),
              controller: _searchController,
              style: WbTypography.body.copyWith(color: colors.icon),
              decoration: wbEditorInputDecoration(
                context,
                hint: '搜索全文…',
                suffix: _query.isEmpty ? null : '$matches 处',
              ),
              onChanged: (String value) => setState(() => _query = value),
            ),
          ),
          const Spacer(),
          WbEditorHint('${(_zoom * 100).round()}%'),
          const SizedBox(width: 4),
          WbEditorIconButton(
            key: const ValueKey<String>('wb-md-reader-zoom-out'),
            icon: LinearIcons.zoomOut,
            tooltip: '缩小',
            onTap: () => _zoomBy(-WbMarkdownReader.zoomStep),
          ),
          WbEditorIconButton(
            key: const ValueKey<String>('wb-md-reader-zoom-in'),
            icon: LinearIcons.zoomIn,
            tooltip: '放大',
            onTap: () => _zoomBy(WbMarkdownReader.zoomStep),
          ),
          const SizedBox(width: 8),
          if (widget.onEdit != null)
            WbEditorIconButton(
              key: const ValueKey<String>('wb-md-reader-edit'),
              icon: LinearIcons.pen,
              tooltip: '编辑',
              onTap: widget.onEdit!,
            ),
          if (widget.onClose != null)
            WbEditorIconButton(
              key: const ValueKey<String>('wb-md-reader-close'),
              icon: LinearIcons.close,
              tooltip: '退出阅读',
              onTap: widget.onClose!,
            ),
        ],
      ),
    );
  }

  /// 目录侧栏（Heading 锚点生成，点击滚动定位）。
  Widget _buildToc(WbThemeColors colors, List<WbMdHeadingAnchor> headings) {
    return SizedBox(
      width: WbMarkdownReader.tocWidth,
      child: ColoredBox(
        color: colors.canvas.withValues(alpha: 0.5),
        child: headings.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: WbEditorHint('暂无目录'),
              )
            : ListView.builder(
                key: const ValueKey<String>('wb-md-reader-toc'),
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: headings.length,
                itemBuilder: (BuildContext context, int index) {
                  final WbMdHeadingAnchor heading = headings[index];
                  final bool major = heading.level <= 2;
                  return InkWell(
                    key: ValueKey<String>('wb-md-reader-toc-$index'),
                    onTap: () => _jumpToHeading(heading.top),
                    hoverColor: colors.cardHover,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        10 + (heading.level - 1) * 12.0,
                        6,
                        8,
                        6,
                      ),
                      child: Text(
                        heading.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (major ? WbTypography.label : WbTypography.caption)
                            .copyWith(
                          color: colors.icon
                              .withValues(alpha: major ? 0.85 : 0.6),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// 正文：虚拟宽度布局 + 等比缩放（滚动范围随缩放变化）。
  Widget _buildDocument(double virtualWidth, double contentHeight) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double scaledWidth = virtualWidth * _zoom;
        final double scaledHeight = contentHeight * _zoom;
        final double viewWidth = math.max(
          constraints.maxWidth,
          scaledWidth + WbMarkdownReader.contentPadding * 2,
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: viewWidth,
            child: Scrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: WbMarkdownReader.contentPadding,
                  vertical: 20,
                ),
                child: Center(
                  child: SizedBox(
                    width: scaledWidth,
                    height: scaledHeight,
                    child: Transform.scale(
                      scale: _zoom,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: virtualWidth,
                        height: contentHeight,
                        child: WbMarkdownView(
                          source: widget.source,
                          theme: widget.theme,
                          searchQuery: _query,
                          textCache: _textCache,
                          cachePrefix: 'wb-md-reader',
                          background: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
