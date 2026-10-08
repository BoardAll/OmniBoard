/// 持久化画布存储（引擎 + 浏览器本地存储复合；P2 多页存档）。
///
/// 数据流（Web 端持久化，与桌面 `.wbd` 文件格式互通）：
/// - `load`：引擎（`WbWasmCanvasStore`）优先；引擎为空时读本地存档
///   （`.wbd` JSON 编码）恢复该页并尽力回灌引擎（失败静默）；
/// - `upsert` / `remove`：引擎尽力同步 + 对应页镜像更新 + 全部页
///   快照写穿本地存储（同步写，失败静默）；
/// - `replaceAll`（撤销 / 重做 / 导入 / 整板载入）：该页镜像整体替换 +
///   写穿存储 + 引擎差量同步（逐元素 `upsert` 覆盖 + 删除多余 id），
///   保证刷新后引擎重建而存档丢失导入数据的场景不出现；
/// - 多页合并（P2）：镜像为「页 id → 元素」全量表（首次访问时从存档
///   整体载入），写穿时全部页一并落盘（页间互不覆盖）；切页 / 未知页
///   返回空（不再回退他页元素）；
/// - 存档键 `wb.canvas.<boardId>`，值为 `WbBoardFileCodec` 编码，
///   桌面端可直接打开、反之亦可（文件格式互通）。
///
/// 引擎调用全部吞错（与画布控制器「存储同步失败不影响本地状态」
/// 口径一致）；本类不抛异常（`undo` / `redo` 路径未包 try）。
library;

import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/canvas/canvas_store.dart';
import 'package:whiteboard_canvas/services/board_file_codec.dart';

import 'wb_browser_io.dart';

/// 持久化画布存储：本地存储为持久化后端，引擎为尽力同步后端。
class WbPersistentCanvasStore implements WbCanvasStore {
  /// 创建持久化存储。
  ///
  /// [engine] 为引擎侧存储（可空：纯本地模式 / VM 测试）；
  /// [pageId] 为引擎首页 id（空串 = 白板无页面，存档回退
  /// [fallbackPageId]）。
  WbPersistentCanvasStore({
    required WbCanvasStorage storage,
    required this.boardId,
    this.boardName = '',
    this.engine,
    String pageId = '',
  })  : _storage = storage,
        _pageId = pageId;

  /// 存档键前缀（完整键为 `wb.canvas.<boardId>`）。
  static const String keyPrefix = 'wb.canvas.';

  /// 无页面 id 时的存档页 id（引擎未创建页面 / 纯本地模式）。
  static const String fallbackPageId = 'default';

  final WbCanvasStorage _storage;

  /// 白板 id（路由参数；存档键来源）。
  final String boardId;

  /// 白板名（写入存档信封）。
  final String boardName;

  /// 引擎侧存储（可空；全部调用尽力而为、吞错）。
  final WbCanvasStore? engine;

  final String _pageId;

  /// 按页元素镜像（全量；null = 未从存档载入）。
  Map<String, List<WbCanvasElement>>? _pagesById;

  /// 最近访问页 id（`currentElements` / 存档 `currentPageId` 来源）。
  String _lastPageId = '';

  /// 存档键（浏览器本地存储）。
  String get storageKey => '$keyPrefix$boardId';

  /// 最近访问页元素（未载入返回空列表）。
  List<WbCanvasElement> get currentElements => List<WbCanvasElement>.of(
        _pagesById?[_lastPageId] ?? const <WbCanvasElement>[],
      );

  /// 归一化页 id（空串回退构造传入页 id，再回退 [fallbackPageId]）。
  String _effectivePageId(String pageId) {
    if (pageId.isNotEmpty) {
      return pageId;
    }
    return _pageId.isNotEmpty ? _pageId : fallbackPageId;
  }

  // ---------------------------------------------------------------------------
  // WbCanvasStore
  // ---------------------------------------------------------------------------

  @override
  List<WbCanvasElement> load(String pageId) {
    final String pid = _effectivePageId(pageId);
    final Map<String, List<WbCanvasElement>> pages = _ensureArchiveLoaded();
    _lastPageId = pid;
    final WbCanvasStore? engine = this.engine;
    if (engine != null) {
      List<WbCanvasElement> fromEngine = const <WbCanvasElement>[];
      try {
        fromEngine = engine.load(pid);
      } catch (_) {
        // 引擎错误：继续走本地存档恢复。
      }
      if (fromEngine.isNotEmpty) {
        final List<WbCanvasElement> mirror =
            List<WbCanvasElement>.of(fromEngine);
        pages[pid] = mirror;
        _persist(pid);
        return List<WbCanvasElement>.of(mirror);
      }
    }
    final List<WbCanvasElement> restored =
        List<WbCanvasElement>.of(pages[pid] ?? const <WbCanvasElement>[]);
    pages[pid] = List<WbCanvasElement>.of(restored);
    // 回灌引擎（尽力而为：失败静默，本地状态仍完整）。
    if (engine != null && restored.isNotEmpty) {
      for (final WbCanvasElement element in restored) {
        try {
          engine.upsert(pid, element);
        } catch (_) {
          // 引擎错误：忽略。
        }
      }
    }
    _persist(pid);
    return restored;
  }

  @override
  void upsert(String pageId, WbCanvasElement element) {
    final String pid = _effectivePageId(pageId);
    final Map<String, List<WbCanvasElement>> pages = _ensureArchiveLoaded();
    _lastPageId = pid;
    try {
      engine?.upsert(pid, element);
    } catch (_) {
      // 引擎错误：本地镜像与存档仍更新。
    }
    final List<WbCanvasElement> elements =
        pages.putIfAbsent(pid, () => <WbCanvasElement>[]);
    final int index = elements
        .indexWhere((WbCanvasElement candidate) => candidate.id == element.id);
    if (index >= 0) {
      elements[index] = element;
    } else {
      elements.add(element);
    }
    _persist(pid);
  }

  @override
  void remove(String pageId, String elementId) {
    final String pid = _effectivePageId(pageId);
    final Map<String, List<WbCanvasElement>> pages = _ensureArchiveLoaded();
    _lastPageId = pid;
    try {
      engine?.remove(pid, elementId);
    } catch (_) {
      // 引擎错误：本地镜像与存档仍更新。
    }
    pages
        .putIfAbsent(pid, () => <WbCanvasElement>[])
        .removeWhere((WbCanvasElement candidate) => candidate.id == elementId);
    _persist(pid);
  }

  @override
  void replaceAll(String pageId, List<WbCanvasElement> elements) {
    final String pid = _effectivePageId(pageId);
    final Map<String, List<WbCanvasElement>> pages = _ensureArchiveLoaded();
    _lastPageId = pid;
    final List<WbCanvasElement> next = List<WbCanvasElement>.of(elements);
    pages[pid] = next;
    _persist(pid);
    _syncEngine(pid, next);
  }

  // ---------------------------------------------------------------------------
  // 存档读写
  // ---------------------------------------------------------------------------

  /// 载入全量存档镜像（首次访问读盘一次；缺失 / 损坏从空开始）。
  Map<String, List<WbCanvasElement>> _ensureArchiveLoaded() {
    Map<String, List<WbCanvasElement>>? pages = _pagesById;
    if (pages != null) {
      return pages;
    }
    pages = <String, List<WbCanvasElement>>{};
    final String? source = _storage.read(storageKey);
    if (source != null && source.isNotEmpty) {
      try {
        final WbBoardData data = WbBoardFileCodec.decode(source);
        for (final WbBoardPageData page in data.pages) {
          pages[page.id] = List<WbCanvasElement>.of(page.elements);
        }
      } on FormatException {
        // 存档损坏：视为无存档（下一次写穿会覆盖）。
        pages.clear();
      }
    }
    _pagesById = pages;
    return pages;
  }

  /// 把全量页镜像写穿本地存储（失败静默；[pageId] 为最近访问页）。
  void _persist(String pageId) {
    try {
      final Map<String, List<WbCanvasElement>> pages =
          _pagesById ?? const <String, List<WbCanvasElement>>{};
      final WbBoardData data = WbBoardData(
        boardId: boardId,
        boardName: boardName,
        currentPageId: pageId,
        pages: <WbBoardPageData>[
          for (final MapEntry<String, List<WbCanvasElement>> entry
              in pages.entries)
            WbBoardPageData(
              id: entry.key,
              elements: List<WbCanvasElement>.of(entry.value),
            ),
        ],
      );
      _storage.write(storageKey, WbBoardFileCodec.encode(data));
    } catch (_) {
      // 本地存储异常：静默（内存状态不受影响）。
    }
  }

  /// 引擎差量同步（替换语义模拟）：
  /// 逐元素 `upsert`（覆盖内容 / 补缺失），再删除引擎多出的 id。
  void _syncEngine(String pageId, List<WbCanvasElement> next) {
    final WbCanvasStore? engine = this.engine;
    if (engine == null) {
      return;
    }
    try {
      final Set<String> nextIds = <String>{
        for (final WbCanvasElement element in next) element.id,
      };
      final List<WbCanvasElement> current = engine.load(pageId);
      for (final WbCanvasElement element in next) {
        engine.upsert(pageId, element);
      }
      for (final WbCanvasElement element in current) {
        if (!nextIds.contains(element.id)) {
          engine.remove(pageId, element.id);
        }
      }
    } catch (_) {
      // 引擎错误：静默（本地与存档仍完整）。
    }
  }
}
