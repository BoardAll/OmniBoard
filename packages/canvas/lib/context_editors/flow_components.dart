/// 流程图图形库扩展支撑：自定义组件、图片缓存与库偏好持久化抽象。
///
/// 本文件服务流程图画布（`flowchart_editor.dart`）的「我的组件」能力：
/// - [WbFlowComponent]：导入的 SVG / 位图组件（归一化：栅格降采样并
///   重编码 PNG，SVG 保留矢量源文本），随节点内嵌序列化保证 `.wbd`
///   自包含；
/// - [WbFlowComponentCache]：组件图片解码缓存（painter 同步读 + 后台
///   解码 + `ChangeNotifier` 触发重绘），栅格与 SVG 统一为 `ui.Image`；
/// - [WbFlowLibraryPrefs] / [WbFlowLibraryStore]：图形库勾选、分组折叠
///   与组件列表的持久化（桌面 `settings.json` / Web `localStorage`
///   由宿主注入；未注入时为内存模式）。
///
/// 组件为应用级资源（跨白板共享）；节点内嵌组件数据用于渲染与文件
/// 互通，库列表本身不写入 `.wbd`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_svg/flutter_svg.dart';

// ---------------------------------------------------------------------------
// 导入源（宿主文件选择结果）
// ---------------------------------------------------------------------------

/// 组件导入源：宿主经 [WbFlowchartEditor.componentImporter] 返回的文件资产。
class WbFlowComponentAsset {
  /// 创建导入源。
  const WbFlowComponentAsset({
    required this.name,
    required this.bytes,
    this.mime = '',
  });

  /// 文件名（含扩展名，用于判型与默认组件名）。
  final String name;

  /// 文件字节。
  final Uint8List bytes;

  /// MIME（可空，空时按扩展名 / 魔数判型）。
  final String mime;
}

// ---------------------------------------------------------------------------
// 组件模型
// ---------------------------------------------------------------------------

/// 「我的组件」条目：导入的 SVG / 位图（归一化后持久化）。
class WbFlowComponent {
  /// 创建组件。
  const WbFlowComponent({
    required this.id,
    required this.name,
    required this.mime,
    required this.data,
    this.width = 120,
    this.height = 120,
  });

  /// PNG 组件 MIME（位图统一重编码为 PNG）。
  static const String mimePng = 'image/png';

  /// SVG 组件 MIME（保留矢量源）。
  static const String mimeSvg = 'image/svg+xml';

  /// 位图导入上限（字节；超出拒绝）。
  static const int maxRasterInputBytes = 2 * 1024 * 1024;

  /// 位图归一化长边上限（超出等比重编码 PNG）。
  static const double maxRasterEdge = 640;

  /// SVG 源文本上限（字节；超出拒绝）。
  static const int maxSvgBytes = 512 * 1024;

  /// SVG 光栅化长边（缓存图片分辨率上限）。
  static const double svgRasterEdge = 1024;

  /// 与载体节点无关的放置基准：放置时长边不超过该值（小图保留原尺寸）。
  static const double preferredEdge = 160;

  /// 组件数量上限。
  static const int maxComponents = 30;

  /// 组件 id（图内 / 缓存键唯一）。
  final String id;

  /// 显示名（默认取文件名去扩展名）。
  final String name;

  /// MIME（[mimePng] / [mimeSvg]）。
  final String mime;

  /// base64 数据（位图 = PNG 字节；SVG = UTF-8 源文本）。
  final String data;

  /// 自然宽（位图为归一化后像素宽；SVG 为 viewBox 宽）。
  final double width;

  /// 自然高。
  final double height;

  /// 是否为 SVG 矢量源。
  bool get isSvg => mime == mimeSvg;

  /// 缓存键（同 id 视为同一图片，跨会话稳定）。
  String get cacheKey => id;

  /// 放置尺寸：长边不超过 [preferredEdge]（小图保留自然尺寸）。
  Size get preferredNodeSize {
    final double longEdge = math.max(width, height);
    if (longEdge <= 0) {
      return const Size(120, 120);
    }
    if (longEdge <= preferredEdge) {
      return Size(width, height);
    }
    final double scale = preferredEdge / longEdge;
    return Size(width * scale, height * scale);
  }

  /// 序列化（`.wbd` 节点内嵌 / 库偏好持久化共用）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'mime': mime,
        'data': data,
        'width': width,
        'height': height,
      };

  /// 反序列化（容错：缺 id / mime / data 返回 null）。
  static WbFlowComponent? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? id = raw['id'];
    final Object? mime = raw['mime'];
    final Object? data = raw['data'];
    if (id is! String ||
        id.isEmpty ||
        mime is! String ||
        mime.isEmpty ||
        data is! String ||
        data.isEmpty) {
      return null;
    }
    return WbFlowComponent(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '组件',
      mime: mime,
      data: data,
      width: _positive(raw['width'], 120),
      height: _positive(raw['height'], 120),
    );
  }

  static double _positive(Object? value, double fallback) =>
      value is num && value > 0 ? value.toDouble() : fallback;

  /// 由导入源归一化（异步）：判型 → 尺寸 / 体积守卫 → 重编码。
  ///
  /// 失败抛出 [FormatException]（中文文案，供对话框直接展示）。
  static Future<WbFlowComponent> fromAsset(
    WbFlowComponentAsset asset, {
    String id = '',
  }) async {
    final String name = _stripExtension(asset.name).trim();
    final String displayName = name.isEmpty ? '组件' : name;
    final String componentId = id.isEmpty
        ? 'cmp-${DateTime.now().microsecondsSinceEpoch}'
        : id;
    final _ComponentKind kind = _detectKind(asset);
    switch (kind) {
      case _ComponentKind.svg:
        if (asset.bytes.length > maxSvgBytes) {
          throw const FormatException('SVG 源文件过大（上限 512KB）');
        }
        final String text;
        try {
          text = utf8.decode(asset.bytes);
        } catch (_) {
          throw const FormatException('SVG 文件不是有效的 UTF-8 文本');
        }
        if (!text.contains('<svg')) {
          throw const FormatException('SVG 文件缺少 <svg> 根元素');
        }
        final Size size = await _probeSvgSize(text);
        return WbFlowComponent(
          id: componentId,
          name: displayName,
          mime: mimeSvg,
          data: base64Encode(utf8.encode(text)),
          width: size.width,
          height: size.height,
        );
      case _ComponentKind.raster:
        if (asset.bytes.length > maxRasterInputBytes) {
          throw const FormatException('图片文件过大（上限 2MB）');
        }
        final ui.Image decoded;
        try {
          decoded = await decodeImageFromList(asset.bytes);
        } catch (_) {
          throw const FormatException('图片解码失败，请更换文件');
        }
        final ui.Image normalized = await _downscaleRaster(decoded);
        final ByteData? png = await normalized.toByteData(
          format: ui.ImageByteFormat.png,
        );
        final int width = normalized.width;
        final int height = normalized.height;
        normalized.dispose();
        if (png == null) {
          throw const FormatException('图片重编码失败，请更换文件');
        }
        final Uint8List pngBytes =
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
        return WbFlowComponent(
          id: componentId,
          name: displayName,
          mime: mimePng,
          data: base64Encode(pngBytes),
          width: width.toDouble(),
          height: height.toDouble(),
        );
      case _ComponentKind.unsupported:
        throw const FormatException(
          '不支持的格式（支持 PNG / JPG / GIF / BMP / WebP / SVG）',
        );
    }
  }

  /// 位图降采样：长边超过 [maxRasterEdge] 时等比缩放（否则原样返回）。
  static Future<ui.Image> _downscaleRaster(ui.Image decoded) async {
    final int maxSide = math.max(decoded.width, decoded.height);
    if (maxSide <= maxRasterEdge) {
      return decoded;
    }
    final double scale = maxRasterEdge / maxSide;
    final int width = math.max((decoded.width * scale).round(), 1);
    final int height = math.max((decoded.height * scale).round(), 1);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawImageRect(
      decoded,
      Rect.fromLTWH(0, 0, decoded.width.toDouble(), decoded.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image scaled = await picture.toImage(width, height);
    picture.dispose();
    decoded.dispose();
    return scaled;
  }

  /// SVG 尺寸探测（无法解析时回退 120x120）。
  static Future<Size> _probeSvgSize(String text) async {
    try {
      final PictureInfo info =
          await vg.loadPicture(SvgStringLoader(text), null);
      final Size size = info.size;
      info.picture.dispose();
      if (size.width.isFinite &&
          size.height.isFinite &&
          size.width > 0 &&
          size.height > 0) {
        return size;
      }
    } catch (_) {
      throw const FormatException('SVG 解析失败，请更换文件');
    }
    return const Size(120, 120);
  }

  /// 判型：扩展名优先（.svg），否则魔数（PNG / JPG / GIF / BMP / WebP）。
  static _ComponentKind _detectKind(WbFlowComponentAsset asset) {
    final String lower = asset.name.toLowerCase();
    final Uint8List b = asset.bytes;
    if (lower.endsWith('.svg') || asset.mime == mimeSvg) {
      return _ComponentKind.svg;
    }
    if (_isPng(b) || _isJpeg(b) || _isGif(b) || _isBmp(b) || _isWebp(b)) {
      return _ComponentKind.raster;
    }
    return _ComponentKind.unsupported;
  }

  static bool _isPng(Uint8List b) =>
      b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47;

  static bool _isJpeg(Uint8List b) =>
      b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

  static bool _isGif(Uint8List b) =>
      b.length >= 4 &&
      b[0] == 0x47 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x38;

  static bool _isBmp(Uint8List b) =>
      b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D;

  static bool _isWebp(Uint8List b) =>
      b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50;

  static String _stripExtension(String name) {
    final int dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}

/// 组件导入判型。
enum _ComponentKind { raster, svg, unsupported }

// ---------------------------------------------------------------------------
// 组件图片缓存
// ---------------------------------------------------------------------------

/// 组件图片解码缓存（painter 同步读 + 后台解码 + 通知重绘）。
///
/// 与 `WbCanvasImageCache` 同型：`imageFor` 同步命中、`request` 后台
/// 加载、解码完成 `notifyListeners` 触发挂载它的 painter / 画布重绘。
/// 位图与 SVG 统一光栅化为 `ui.Image`（SVG 长边不超过
/// [WbFlowComponent.svgRasterEdge]）。
class WbFlowComponentCache extends ChangeNotifier {
  /// 全局单例（painter 无状态持有；测试可经 [resetInstance] 隔离）。
  static WbFlowComponentCache instance = WbFlowComponentCache();

  /// 缓存上限（超出后整体清空，简单可靠）。
  static const int maxEntries = 64;

  final Map<String, ui.Image> _images = <String, ui.Image>{};
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};
  final Set<String> _failed = <String>{};
  bool _disposed = false;

  /// 测试隔离：释放并替换单例。
  @visibleForTesting
  static void resetInstance() {
    instance.dispose();
    instance = WbFlowComponentCache();
  }

  /// 已解码图片（未命中 / 加载中 / 失败返回 null，不触发加载）。
  ui.Image? imageFor(String key) => _images[key];

  /// 是否解码失败过（避免重复自动请求；[load] 可显式重试）。
  bool hasFailed(String key) => _failed.contains(key);

  /// 请求后台加载（不等待；命中 / 加载中 / 已失败时直接返回）。
  void request(WbFlowComponent component) {
    final String key = component.cacheKey;
    if (_images.containsKey(key) ||
        _inFlight.containsKey(key) ||
        _failed.contains(key)) {
      return;
    }
    unawaited(load(component));
  }

  /// 加载并缓存（等待解码完成；显式调用会清理失败标记重试）。
  Future<void> load(WbFlowComponent component) {
    final String key = component.cacheKey;
    _failed.remove(key);
    return _inFlight.putIfAbsent(key, () async {
      try {
        final ui.Image image = await decodeComponent(component);
        if (_disposed) {
          image.dispose();
          return;
        }
        if (_images.length >= maxEntries) {
          for (final ui.Image cached in _images.values) {
            cached.dispose();
          }
          _images.clear();
        }
        _images[key] = image;
        notifyListeners();
      } catch (_) {
        _failed.add(key);
      } finally {
        // 自引用移除：本 future 自身已完成，无需等待。
        _inFlight.remove(key)?.ignore();
      }
    });
  }

  /// 解码组件为 `ui.Image`（位图直解；SVG 光栅化长边 ≤ [WbFlowComponent.svgRasterEdge]）。
  static Future<ui.Image> decodeComponent(WbFlowComponent component) async {
    final Uint8List bytes = base64Decode(component.data);
    if (!component.isSvg) {
      return decodeImageFromList(bytes);
    }
    final String text = utf8.decode(bytes);
    final PictureInfo info = await vg.loadPicture(SvgStringLoader(text), null);
    final ui.Picture picture = info.picture;
    final Size size = info.size;
    final double longEdge = math.max(size.width, size.height);
    final double scale = longEdge <= 0
        ? 1
        : (WbFlowComponent.svgRasterEdge / longEdge).clamp(1.0, 4.0);
    final int width = math.max((size.width * scale).round(), 1);
    final int height = math.max((size.height * scale).round(), 1);
    final ui.Image image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final ui.Image cached in _images.values) {
      cached.dispose();
    }
    _images.clear();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 库偏好与持久化
// ---------------------------------------------------------------------------

/// 图形库偏好：勾选显示的库 / 折叠的库 / 我的组件列表。
class WbFlowLibraryPrefs {
  /// 创建偏好。
  const WbFlowLibraryPrefs({
    required this.enabledLibraries,
    this.collapsedLibraries = const <String>{},
    this.components = const <WbFlowComponent>[],
  });

  /// 启用（显示）的库 id 集合。
  final Set<String> enabledLibraries;

  /// 折叠的库 id 集合。
  final Set<String> collapsedLibraries;

  /// 我的组件列表（导入顺序）。
  final List<WbFlowComponent> components;

  /// 返回修改指定字段后的副本（enabled 用哨兵保留置空语义）。
  WbFlowLibraryPrefs copyWith({
    Set<String>? enabledLibraries,
    Set<String>? collapsedLibraries,
    List<WbFlowComponent>? components,
  }) {
    return WbFlowLibraryPrefs(
      enabledLibraries: enabledLibraries ?? this.enabledLibraries,
      collapsedLibraries: collapsedLibraries ?? this.collapsedLibraries,
      components: components ?? this.components,
    );
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabledLibraries': enabledLibraries.toList()..sort(),
        'collapsedLibraries': collapsedLibraries.toList()..sort(),
        'components': <Map<String, dynamic>>[
          for (final WbFlowComponent component in components)
            component.toJson(),
        ],
      };

  /// 反序列化（容错：缺字段回默认；坏组件条目静默丢弃）。
  ///
  /// [defaultEnabled] 为「字段缺失时的默认启用集合」（即全部库 id）。
  static WbFlowLibraryPrefs fromJson(
    Object? raw, {
    required Set<String> defaultEnabled,
  }) {
    if (raw is! Map) {
      return WbFlowLibraryPrefs(enabledLibraries: defaultEnabled);
    }
    final Object? enabled = raw['enabledLibraries'];
    final Set<String> enabledIds = enabled is List
        ? <String>{
            for (final Object? item in enabled)
              if (item is String && item.isNotEmpty) item,
          }
        : defaultEnabled;
    final Object? collapsed = raw['collapsedLibraries'];
    final Set<String> collapsedIds = collapsed is List
        ? <String>{
            for (final Object? item in collapsed)
              if (item is String && item.isNotEmpty) item,
          }
        : const <String>{};
    final List<WbFlowComponent> components = <WbFlowComponent>[];
    final Object? rawComponents = raw['components'];
    if (rawComponents is List) {
      for (final Object? item in rawComponents) {
        final WbFlowComponent? component = WbFlowComponent.fromJson(item);
        if (component != null) {
          components.add(component);
        }
      }
    }
    return WbFlowLibraryPrefs(
      enabledLibraries: enabledIds,
      collapsedLibraries: collapsedIds,
      components: components,
    );
  }
}

/// 图形库偏好持久化窄接口（宿主注入：桌面 settings.json / Web localStorage）。
abstract interface class WbFlowLibraryStore {
  /// 读取偏好（无数据 / 读取失败返回 null）。
  WbFlowLibraryPrefs? read();

  /// 写入偏好（失败静默）。
  void write(WbFlowLibraryPrefs prefs);
}

/// 内存实现（编辑器未注入存储时的缺省；亦供测试使用）。
class WbFlowMemoryLibraryStore implements WbFlowLibraryStore {
  /// 创建内存存储（可选初值）。
  WbFlowMemoryLibraryStore([this._prefs]);

  WbFlowLibraryPrefs? _prefs;

  @override
  WbFlowLibraryPrefs? read() => _prefs;

  @override
  void write(WbFlowLibraryPrefs prefs) => _prefs = prefs;
}
