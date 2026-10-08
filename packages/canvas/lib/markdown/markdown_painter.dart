/// Markdown 渲染缓存与绘制入口。
///
/// [WbMarkdownRenderCache]：整篇布局缓存（LRU，key = sourceHash + width +
/// themeId，上限 32 篇）；移动 / 缩放 / 选择时复用布局，不重新 Parse
/// （方案 §22 性能要求）。[WbMarkdownPainter]：画布内元素与预览 widget
/// 共用的绘制实现（视口裁剪 + 搜索高亮）。
library;

import 'dart:collection';

import 'package:flutter/painting.dart';

import '../canvas/canvas_model.dart';
import 'markdown_ast.dart';
import 'markdown_layout.dart';
import 'markdown_parser.dart';
import 'markdown_theme.dart';

/// 整篇 Markdown 渲染缓存（全局 LRU）。
abstract final class WbMarkdownRenderCache {
  /// LRU 上限（篇数）。
  static const int maxEntries = 32;

  /// 布局最小高度（保持默认内容卡片观感）。
  static const double minLayoutHeight = 120;

  static final LinkedHashMap<String, WbMdLayoutResult> _entries =
      LinkedHashMap<String, WbMdLayoutResult>();

  /// 真正执行 Parse + Layout 的次数（测试断言缓存命中用）。
  static int parseCount = 0;

  /// 缓存命中次数（测试用）。
  static int hitCount = 0;

  /// 取（或构建）整篇布局。
  ///
  /// [width] 参与 key（像素级取整）；[cachePrefix] 为文本缓存前缀
  /// （建议元素 id；空则使用 source hash）。
  static WbMdLayoutResult layoutFor({
    required String source,
    required double width,
    required WbMarkdownTheme theme,
    WbCanvasTextCache? textCache,
    String cachePrefix = '',
  }) {
    final int widthKey = width.round();
    final String key = '${source.hashCode}|$widthKey|${theme.id}';
    final WbMdLayoutResult? cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached; // LRU touch。
      hitCount++;
      return cached;
    }
    parseCount++;
    final WbMdDocument document = WbMarkdownParser.parse(source);
    final WbMdLayoutResult result = WbMarkdownLayoutEngine.layout(
      document: document,
      theme: theme,
      width: width,
      minHeight: minLayoutHeight,
      textCache: textCache,
      cachePrefix: cachePrefix.isEmpty
          ? 'wb-md|${source.hashCode}'
          : cachePrefix,
    );
    _put(key, result);
    return result;
  }

  static void _put(String key, WbMdLayoutResult value) {
    if (_entries.length >= maxEntries && !_entries.containsKey(key)) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = value;
  }

  /// 主动失效（系统字体变化 / 主题切换等整体场景）。
  static void clear() {
    _entries.clear();
  }

  /// 重置统计（测试用）。
  static void resetStats() {
    parseCount = 0;
    hitCount = 0;
  }
}

/// Markdown 绘制入口（画布元素 / 预览 widget 共用）。
abstract final class WbMarkdownPainter {
  /// 测量：按 [width] 布局返回内容高度（下限 [WbMarkdownRenderCache.minLayoutHeight]）。
  static double measureHeight(
    String source,
    double width, {
    WbMarkdownTheme? theme,
    WbCanvasTextCache? textCache,
    String cachePrefix = '',
  }) {
    final WbMdLayoutResult result = WbMarkdownRenderCache.layoutFor(
      source: source,
      width: width,
      theme: theme ?? WbMarkdownTheme.light,
      textCache: textCache,
      cachePrefix: cachePrefix,
    );
    return result.height;
  }

  /// 绘制到 [rect]（世界坐标；内部按元素局部坐标布局并裁剪）。
  ///
  /// [searchQuery] 非空时对命中块叠加高亮（全文搜索，方案 Reader）。
  /// [background] 为 true 时先绘制元素卡片底（圆角白底 + 描边）。
  static void paint(
    Canvas canvas,
    Rect rect, {
    required String source,
    required WbMarkdownTheme theme,
    WbCanvasTextCache? textCache,
    String cachePrefix = '',
    String searchQuery = '',
    bool background = true,
  }) {
    final WbMdLayoutResult layout = WbMarkdownRenderCache.layoutFor(
      source: source,
      width: rect.width,
      theme: theme,
      textCache: textCache,
      cachePrefix: cachePrefix,
    );
    canvas.save();
    canvas.translate(rect.left, rect.top);
    canvas.clipRect(Rect.fromLTWH(0, 0, rect.width, rect.height));
    if (background) {
      final RRect rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, rect.width, rect.height),
        const Radius.circular(8),
      );
      canvas.drawRRect(rrect, Paint()..color = theme.background);
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = theme.border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final String query = searchQuery.toLowerCase();
    for (final WbMdDrawOp op in layout.ops) {
      if (op.rect.top > rect.height || op.rect.bottom < 0) {
        continue; // 视口（元素区域）外裁剪。
      }
      op.draw(canvas);
      if (query.isNotEmpty &&
          op.searchText.toLowerCase().contains(query)) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            op.rect.inflate(2),
            const Radius.circular(3),
          ),
          Paint()..color = theme.searchHighlight,
        );
      }
    }
    canvas.restore();
  }
}
