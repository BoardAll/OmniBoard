/// 图层区（《左侧栏与页面管理设计》§5）：当前页元素列表。
///
/// 覆盖 M2.6.4 的图层列表 / 显示隐藏 / 锁定 / 排序 / 重命名 / 右键菜单：
/// - 数据源：引擎可用时 `ffi.element.list(pageId)`；否则使用进程内演示缓存
///   （[resetDemoLayers] 仅测试使用）；
/// - 显示序为**顶层在前**（zIndex 降序）；拖拽或菜单排序后统一回写 zIndex；
/// - 选中与画布共用 `WbSelectionState`（provider 可选，缺失时降级为内部选区）；
/// - 视觉 token 全部取自 `context.wbColors`，图标仅使用 `packages/icons` 已有项。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../services/ffi_service.dart';
import '../state/page_state.dart';
import '../state/selection_state.dart';
import 'canvas/canvas_controller.dart';
import 'canvas/canvas_model.dart';
import 'page_manager.dart' show WbVisibilityIcon;

/// 双击行的判定窗口（与 Flutter 的 `kDoubleTapTimeout` 对齐）。
///
/// 图层行不注册 `InkWell.onDoubleTap`：双击识别器会 hold 手势
/// 竞技场至超时，使行内按钮点击延迟约 300ms；单击/双击改由
/// `_handleRowTap` 依据本窗口手动判定。
const Duration _wbLayerDoubleTapWindow = Duration(milliseconds: 300);

// ---------------------------------------------------------------------------
// 演示模式图层缓存（无引擎的开发 / 测试环境）
// ---------------------------------------------------------------------------

/// 演示模式图层缓存：按页面 id 键控，跨组件重挂载保留。
final Map<String, List<WbElement>> _demoLayers = <String, List<WbElement>>{};

/// 清空演示模式图层缓存（仅测试使用，保证用例间确定性）。
@visibleForTesting
void resetDemoLayers() => _demoLayers.clear();

// ---------------------------------------------------------------------------
// 类型映射（design §5.4）
// ---------------------------------------------------------------------------

/// 图层类型的展示信息（类型标签 + 图标）。
class WbLayerTypeVisual {
  const WbLayerTypeVisual(this.label, this.icon);

  /// 展示标签（如「便签」「连线」）。
  final String label;

  /// 展示图标（取自 `packages/icons`）。
  final IconData icon;
}

/// 元素类型 → 展示信息。
///
/// 映射规则见 design §5.4；未知类型回退为原始类型名 + 形状图标。
WbLayerTypeVisual wbLayerTypeVisual(String type) {
  switch (type) {
    case 'note':
    case 'sticky':
      return const WbLayerTypeVisual('便签', LinearIcons.stickyNote);
    case 'text':
      return const WbLayerTypeVisual('文本', LinearIcons.text);
    case 'shape':
    case '2d':
      return const WbLayerTypeVisual('形状', LinearIcons.shape);
    case 'connector':
    case 'line':
    case 'arrow':
      return const WbLayerTypeVisual('连线', LinearIcons.connector);
    case 'image':
      return const WbLayerTypeVisual('图片', LinearIcons.image);
    case '3d':
    case 'cube':
      return const WbLayerTypeVisual('3D', LinearIcons.cube);
    case 'function':
    case 'formula':
      return const WbLayerTypeVisual('函数', LinearIcons.formula);
    case 'table':
      return const WbLayerTypeVisual('表格', LinearIcons.table);
    case 'mindmap':
      return const WbLayerTypeVisual('导图', LinearIcons.mindmap);
    case 'flowchart':
      return const WbLayerTypeVisual('流程图', LinearIcons.flowchart);
    case 'frame':
      return const WbLayerTypeVisual('Frame', LinearIcons.board);
    case 'page':
    case 'document':
      return const WbLayerTypeVisual('文档', LinearIcons.page);
    default:
      return WbLayerTypeVisual(
        type.isEmpty ? '元素' : type,
        LinearIcons.shape,
      );
  }
}

/// 图层显示名：优先 `raw['name']`，否则「类型标签 + z 序（1 起）」。
///
/// [zRank] 为元素在 zIndex 升序中的位置（1 起），与 design §5.2
/// 示例「便签 1 / 形状 2 / 连线 3」的编号方式一致。
String wbLayerDisplayName(WbElement element, int zRank) {
  final Object? name = element.raw['name'];
  if (name is String && name.isNotEmpty) {
    return name;
  }
  return '${wbLayerTypeVisual(element.type).label} $zRank';
}

/// 图层行视图模型：统一「画布控制器」与「FFI / 演示缓存」两条数据源。
class _LayerEntry {
  const _LayerEntry({
    required this.id,
    required this.type,
    required this.visible,
    required this.locked,
    required this.name,
  });

  /// 元素 id。
  final String id;

  /// 元素类型（`note` / `shape` / `image` / ...）。
  final String type;

  /// 是否可见。
  final bool visible;

  /// 是否锁定。
  final bool locked;

  /// 自定义名称（空串 = 使用「类型标签 + z 序」）。
  final String name;
}

/// 行显示名：优先自定义名，否则「类型标签 + z 序」。
String _entryDisplayName(_LayerEntry entry, int zRank) {
  if (entry.name.isNotEmpty) {
    return entry.name;
  }
  return '${wbLayerTypeVisual(entry.type).label} $zRank';
}

// ---------------------------------------------------------------------------
// 元素拷贝（WbElement 无 copyWith，按变更字段重建 raw）
// ---------------------------------------------------------------------------

WbElement _copyElement(
  WbElement el, {
  bool? visible,
  bool? locked,
  String? name,
  int? zIndex,
}) {
  final Map<String, dynamic> raw = Map<String, dynamic>.of(el.raw);
  raw['id'] = el.id;
  raw['type'] = el.type;
  raw['position'] = <String, dynamic>{'x': el.x, 'y': el.y};
  raw['size'] = <String, dynamic>{'width': el.width, 'height': el.height};
  final int z = zIndex ?? el.zIndex;
  raw['zIndex'] = z;
  raw['rotation'] = el.rotation;
  final bool vis = visible ?? el.visible;
  raw['visible'] = vis;
  final bool lk = locked ?? el.locked;
  raw['locked'] = lk;
  if (name != null) {
    raw['name'] = name;
  }
  return WbElement(
    id: el.id,
    type: el.type,
    x: el.x,
    y: el.y,
    width: el.width,
    height: el.height,
    zIndex: z,
    rotation: el.rotation,
    locked: lk,
    visible: vis,
    raw: raw,
  );
}

// ---------------------------------------------------------------------------
// 演示数据种子
// ---------------------------------------------------------------------------

List<WbElement> _seedDemoLayers(String pageId) {
  int seq = 0;
  WbElement make(String type, String name, int z) {
    seq++;
    final String id = '$pageId-el-$seq';
    return WbElement(
      id: id,
      type: type,
      x: 80.0 * seq,
      y: 80,
      width: 200,
      height: 120,
      zIndex: z,
      raw: <String, dynamic>{
        'id': id,
        'type': type,
        'name': name,
        'position': <String, dynamic>{'x': 80.0 * seq, 'y': 80.0},
        'size': <String, dynamic>{'width': 200.0, 'height': 120.0},
        'zIndex': z,
        'rotation': 0.0,
        'locked': false,
        'visible': true,
      },
    );
  }

  return <WbElement>[
    make('note', '便签 1', 0),
    make('shape', '形状 2', 1),
    make('connector', '连线 3', 2),
  ];
}

// ---------------------------------------------------------------------------
// 图层面板
// ---------------------------------------------------------------------------

/// 图层面板（左侧栏「图层」分区内容）。
///
/// 构造保持 `const LayersPanel()` 可用；[refreshSignal] 为可选的外部刷新
/// 信号（侧栏手动刷新按钮）。
class LayersPanel extends StatefulWidget {
  const LayersPanel({super.key, this.refreshSignal, this.canvasController});

  /// 外部刷新信号（触发后重新拉取当前页元素）。
  final Listenable? refreshSignal;

  /// 画布控制器（可选）。
  ///
  /// 注入后面板数据源直接取 [WbCanvasController.elements]（与画布同源），
  /// 行操作统一走 updateElement / removeElement / applyZOrder（支持撤销）；
  /// 未注入时保持 FFI / 演示缓存路径（兼容既有测试嵌入）。
  final WbCanvasController? canvasController;

  @override
  State<LayersPanel> createState() => _LayersPanelState();
}

class _LayersPanelState extends State<LayersPanel> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'wb.layers');
  final TextEditingController _renameController = TextEditingController();
  final Set<String> _fallbackSelection = <String>{};

  WbPageState? _pages;
  bool _demoMode = true;
  String _pageId = '';
  int _lastCount = 0;
  List<WbElement> _elements = const <WbElement>[];
  bool _loaded = false;
  bool _reloadScheduled = false;
  String? _renamingId;
  String? _draggingId;
  int _dropIndex = -1;
  String? _lastTapId;
  Timer? _rowTapTimer;

  /// 控制器模式：注入控制器时数据源与写回均走画布（单一数据源）。
  bool get _controllerMode => widget.canvasController != null;

  /// 画布变更（元素增删改 / 选中）→ 刷新面板。
  void _onCanvasChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_onExternalRefresh);
    widget.canvasController?.addListener(_onCanvasChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final WbPageState? pages = _maybeRead<WbPageState>(context);
    if (!identical(pages, _pages)) {
      _pages?.removeListener(_onPagesChanged);
      _pages = pages;
      pages?.addListener(_onPagesChanged);
    }
    final WbFfiService? ffi = _maybeRead<WbFfiService>(context);
    _demoMode = !_controllerMode && (ffi == null || !ffi.isAvailable);
    _scheduleReload();
  }

  @override
  void didUpdateWidget(covariant LayersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      oldWidget.refreshSignal?.removeListener(_onExternalRefresh);
      widget.refreshSignal?.addListener(_onExternalRefresh);
    }
    if (oldWidget.canvasController != widget.canvasController) {
      oldWidget.canvasController?.removeListener(_onCanvasChanged);
      widget.canvasController?.addListener(_onCanvasChanged);
      _scheduleReload();
    }
  }

  @override
  void dispose() {
    widget.refreshSignal?.removeListener(_onExternalRefresh);
    widget.canvasController?.removeListener(_onCanvasChanged);
    _pages?.removeListener(_onPagesChanged);
    _renameController.dispose();
    _rowTapTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  // ---- 数据装载 ----

  void _onExternalRefresh() => _scheduleReload();

  void _onPagesChanged() {
    if (_controllerMode) {
      return;
    }
    final WbPageState? pages = _pages;
    if (pages == null) {
      return;
    }
    if (pages.currentPageId != _pageId ||
        (pages.currentPage?.elementCount ?? 0) != _lastCount) {
      _scheduleReload();
    }
  }

  void _scheduleReload() {
    if (_reloadScheduled) {
      return;
    }
    _reloadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadScheduled = false;
      if (!mounted) {
        return;
      }
      setState(_load);
    });
  }

  void _load() {
    if (_controllerMode) {
      // 控制器模式：数据源即控制器元素，无需拉取 FFI / 演示缓存。
      _loaded = true;
      _renamingId = null;
      _draggingId = null;
      _dropIndex = -1;
      return;
    }
    final WbPageState? pages = _pages;
    final String id = pages?.currentPageId ?? '';
    _pageId = id;
    _lastCount = pages?.currentPage?.elementCount ?? 0;
    _renamingId = null;
    _draggingId = null;
    _dropIndex = -1;
    if (id.isEmpty) {
      _elements = const <WbElement>[];
      _loaded = true;
      return;
    }
    final List<WbElement> items = _fetch(id)
      ..sort((WbElement a, WbElement b) {
        final int byZ = b.zIndex.compareTo(a.zIndex);
        if (byZ != 0) {
          return byZ;
        }
        return a.id.compareTo(b.id);
      });
    _elements = items;
    _loaded = true;
  }

  List<WbElement> _fetch(String pageId) {
    if (!_demoMode) {
      final WbFfiService? ffi = _maybeRead<WbFfiService>(context);
      try {
        final List<WbElement> items = ffi!.element.list(pageId);
        return List<WbElement>.of(items);
      } catch (_) {
        // 引擎错误：呈现空列表（错误呈现由通知中心统一处理）。
        return <WbElement>[];
      }
    }
    return List<WbElement>.of(
      _demoLayers.putIfAbsent(pageId, () => _seedDemoLayers(pageId)),
    );
  }

  /// 把当前显示序（顶层在前）回写演示缓存。
  void _persistDemo() {
    if (!_demoMode || _pageId.isEmpty) {
      return;
    }
    _demoLayers[_pageId] = List<WbElement>.of(_elements);
  }

  /// 当前显示行（顶层在前）。
  ///
  /// 控制器模式取画布元素（zIndex 降序、id 升序稳定）；否则用 FFI /
  /// 演示缓存（已在 [_load] 中按同规则排序）。
  List<_LayerEntry> get _rows {
    final WbCanvasController? controller = widget.canvasController;
    if (controller != null) {
      final List<WbCanvasElement> sorted =
          List<WbCanvasElement>.of(controller.elements)
            ..sort((WbCanvasElement a, WbCanvasElement b) {
              final int byZ = b.zIndex.compareTo(a.zIndex);
              if (byZ != 0) {
                return byZ;
              }
              return a.id.compareTo(b.id);
            });
      return <_LayerEntry>[
        for (final WbCanvasElement e in sorted)
          _LayerEntry(
            id: e.id,
            type: e.type,
            visible: e.visible,
            locked: e.locked,
            name: e.name,
          ),
      ];
    }
    return <_LayerEntry>[
      for (final WbElement e in _elements) _entryFromFfi(e),
    ];
  }

  static _LayerEntry _entryFromFfi(WbElement element) {
    final Object? rawName = element.raw['name'];
    return _LayerEntry(
      id: element.id,
      type: element.type,
      visible: element.visible,
      locked: element.locked,
      name: rawName is String ? rawName : '',
    );
  }

  // ---- 元素变更 ----

  void _replace(WbElement next) {
    final int index = _elements.indexWhere((WbElement e) => e.id == next.id);
    if (index < 0) {
      return;
    }
    setState(() => _elements[index] = next);
    _persistDemo();
  }

  void _toggleVisible(String id) {
    final WbCanvasController? controller = widget.canvasController;
    if (controller != null) {
      controller.updateElement(
        id,
        (WbCanvasElement e) => e.copyWith(visible: !e.visible),
      );
      return;
    }
    final WbElement? el = _ffiElementById(id);
    if (el == null) {
      return;
    }
    final WbElement next = _copyElement(el, visible: !el.visible);
    _pushUpdate(next, <String, dynamic>{'visible': next.visible});
    _replace(next);
  }

  void _toggleLocked(String id) {
    final WbCanvasController? controller = widget.canvasController;
    if (controller != null) {
      controller.updateElement(
        id,
        (WbCanvasElement e) => e.copyWith(locked: !e.locked),
      );
      return;
    }
    final WbElement? el = _ffiElementById(id);
    if (el == null) {
      return;
    }
    final WbElement next = _copyElement(el, locked: !el.locked);
    _pushUpdate(next, <String, dynamic>{'locked': next.locked});
    _replace(next);
  }

  /// FFI / 演示缓存路径：按 id 取行元素（无则 null）。
  WbElement? _ffiElementById(String id) {
    for (final WbElement e in _elements) {
      if (e.id == id) {
        return e;
      }
    }
    return null;
  }

  void _deleteElement(String id) {
    final WbCanvasController? controller = widget.canvasController;
    if (controller != null) {
      controller.removeElement(id);
    } else {
      if (!_demoMode) {
        final WbFfiService? ffi = _maybeRead<WbFfiService>(context);
        try {
          ffi?.element.delete(id);
        } catch (_) {
          // 引擎错误：仍更新本地视图。
        }
      }
      setState(() {
        _elements = <WbElement>[
          for (final WbElement e in _elements)
            if (e.id != id) e,
        ];
      });
      _persistDemo();
    }
    final WbSelectionState? selection = _maybeRead<WbSelectionState>(context);
    if (selection != null && selection.contains(id)) {
      selection.remove(id);
    }
    _fallbackSelection.remove(id);
  }

  void _pushUpdate(WbElement el, Map<String, dynamic> patch) {
    if (_demoMode) {
      return;
    }
    final WbFfiService? ffi = _maybeRead<WbFfiService>(context);
    if (ffi == null || !ffi.isAvailable) {
      return;
    }
    try {
      ffi.element.update(el.id, patch);
    } catch (_) {
      // 引擎错误：本地视图保留（保证 UI 可用）。
    }
  }

  void _pushZOrder(List<WbElement> topFirst) {
    if (_demoMode) {
      return;
    }
    final WbFfiService? ffi = _maybeRead<WbFfiService>(context);
    if (ffi == null || !ffi.isAvailable) {
      return;
    }
    for (final WbElement el in topFirst) {
      try {
        ffi.element.update(el.id, <String, dynamic>{'zIndex': el.zIndex});
      } catch (_) {
        // 忽略单个失败，继续尝试其余元素。
      }
    }
  }

  /// 应用新的显示序（[topFirstIds] 顶层在前）：zIndex = len-1-i，并回写数据源。
  void _applyOrder(List<String> topFirstIds) {
    final WbCanvasController? controller = widget.canvasController;
    if (controller != null) {
      controller.applyZOrder(topFirstIds);
      return;
    }
    final Map<String, WbElement> byId = <String, WbElement>{
      for (final WbElement e in _elements) e.id: e,
    };
    final int len = topFirstIds.length;
    final List<WbElement> updated = <WbElement>[];
    for (int i = 0; i < len; i++) {
      final WbElement? el = byId[topFirstIds[i]];
      if (el == null) {
        continue;
      }
      final int z = len - 1 - i;
      updated.add(el.zIndex == z ? el : _copyElement(el, zIndex: z));
    }
    setState(() => _elements = updated);
    _persistDemo();
    _pushZOrder(updated);
  }

  void _reorder(int from, int to) {
    final List<_LayerEntry> rows = _rows;
    if (from == to || from < 0 || from >= rows.length) {
      return;
    }
    final List<_LayerEntry> next = List<_LayerEntry>.of(rows);
    final _LayerEntry moved = next.removeAt(from);
    next.insert(to.clamp(0, next.length), moved);
    _applyOrder(<String>[for (final _LayerEntry e in next) e.id]);
  }

  // ---- 重命名（双击 / 右键菜单） ----

  void _startRename(_LayerEntry entry, int zRank) {
    final String current = _entryDisplayName(entry, zRank);
    _renameController
      ..text = current
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: current.length,
      );
    setState(() => _renamingId = entry.id);
  }

  void _commitRename(String id, String value) {
    final String name = value.trim();
    final bool wasRenaming = _renamingId == id;
    if (wasRenaming) {
      setState(() => _renamingId = null);
    }
    if (name.isEmpty) {
      return;
    }
    final WbCanvasController? controller = widget.canvasController;
    if (controller != null) {
      controller.updateElement(
        id,
        (WbCanvasElement e) => e.copyWith(name: name),
      );
      return;
    }
    final WbElement? el = _ffiElementById(id);
    if (el == null) {
      return;
    }
    final WbElement next = _copyElement(el, name: name);
    _pushUpdate(next, <String, dynamic>{'name': name});
    _replace(next);
  }

  // ---- 拖拽排序 ----

  void _setDropIndex(int index) {
    if (_dropIndex == index) {
      return;
    }
    setState(() => _dropIndex = index);
  }

  void _clearDropIndex(int index) {
    if (_dropIndex != index) {
      return;
    }
    setState(() => _dropIndex = -1);
  }

  void _endDrag() {
    if (_draggingId == null && _dropIndex == -1) {
      return;
    }
    setState(() {
      _draggingId = null;
      _dropIndex = -1;
    });
  }

  /// 投放：拖到第 [targetIndex] 行之前（= 原列表坐标插入位）。
  void _dropOn(String draggedId, int targetIndex) {
    final List<_LayerEntry> rows = _rows;
    final int from = rows.indexWhere((_LayerEntry e) => e.id == draggedId);
    if (from < 0) {
      _endDrag();
      return;
    }
    int insertAt = targetIndex;
    if (from < targetIndex) {
      insertAt -= 1;
    }
    insertAt = insertAt.clamp(0, rows.length - 1);
    if (insertAt != from) {
      final List<_LayerEntry> next = List<_LayerEntry>.of(rows);
      final _LayerEntry moved = next.removeAt(from);
      next.insert(insertAt, moved);
      _applyOrder(<String>[for (final _LayerEntry e in next) e.id]);
    }
    _endDrag();
  }

  // ---- 右键菜单 ----

  RelativeRect _menuPosition(BuildContext context, Offset globalPosition) {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    return RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      overlay.size.width - globalPosition.dx,
      overlay.size.height - globalPosition.dy,
    );
  }

  PopupMenuItem<String> _menuItem(
    WbThemeColors colors,
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) {
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: colors.icon),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// 打开图层菜单；[anchor] 为右键位置，缺省锚定到 [context] 底部左侧。
  Future<void> _openMenu(
    BuildContext context,
    List<_LayerEntry> rows,
    int index, {
    Offset? anchor,
  }) async {
    if (index < 0 || index >= rows.length) {
      return;
    }
    final _LayerEntry entry = rows[index];
    final WbThemeColors colors = context.wbColors;
    final int last = rows.length - 1;
    Offset position = anchor ?? Offset.zero;
    if (anchor == null) {
      final RenderBox box = context.findRenderObject()! as RenderBox;
      position = box.localToGlobal(box.size.bottomLeft(Offset.zero));
    }
    final String? action = await showMenu<String>(
      context: context,
      position: _menuPosition(context, position),
      items: <PopupMenuEntry<String>>[
        _menuItem(
          colors,
          'front',
          LinearIcons.bringToFront,
          '置于顶层',
          enabled: index > 0,
        ),
        _menuItem(
          colors,
          'up',
          LinearIcons.bringForward,
          '上移一层',
          enabled: index > 0,
        ),
        _menuItem(
          colors,
          'down',
          LinearIcons.sendBackward,
          '下移一层',
          enabled: index < last,
        ),
        _menuItem(
          colors,
          'back',
          LinearIcons.sendToBack,
          '置于底层',
          enabled: index < last,
        ),
        const PopupMenuDivider(),
        _menuItem(colors, 'rename', LinearIcons.pen, '重命名'),
        _menuItem(
          colors,
          'toggle-visible',
          LinearIcons.visible,
          entry.visible ? '隐藏' : '显示',
        ),
        _menuItem(
          colors,
          'toggle-lock',
          entry.locked ? LinearIcons.unlock : LinearIcons.lock,
          entry.locked ? '解锁' : '锁定',
        ),
        const PopupMenuDivider(),
        _menuItem(colors, 'delete', LinearIcons.delete, '删除'),
      ],
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case 'front':
        _reorder(index, 0);
      case 'up':
        _reorder(index, index - 1);
      case 'down':
        _reorder(index, index + 1);
      case 'back':
        _reorder(index, last);
      case 'rename':
        _startRename(entry, rows.length - index);
      case 'toggle-visible':
        _toggleVisible(entry.id);
      case 'toggle-lock':
        _toggleLocked(entry.id);
      case 'delete':
        _deleteElement(entry.id);
    }
  }

  // ---- 选区联动 ----

  /// 行点击入口：手动实现「单击选中 / 双击重命名」。
  ///
  /// 不用 `InkWell.onDoubleTap`：其双击识别器会 hold 手势竞技场
  /// 直至超时，令行内按钮点击延迟约 300ms；单击/双击在此手动判定，
  /// 单击即时生效，同一元素在窗口内的第二次点击进入重命名。
  void _handleRowTap(_LayerEntry entry, int zRank) {
    final bool isSecondTap = _lastTapId == entry.id;
    _rowTapTimer?.cancel();
    _rowTapTimer = null;
    if (isSecondTap) {
      _lastTapId = null;
      _startRename(entry, zRank);
      return;
    }
    _lastTapId = entry.id;
    _rowTapTimer = Timer(_wbLayerDoubleTapWindow, () {
      _rowTapTimer = null;
      _lastTapId = null;
    });
    _onRowTap(entry.id);
  }

  void _onRowTap(String id) {
    final WbSelectionState? selection = _maybeRead<WbSelectionState>(context);
    final bool multi = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (selection == null) {
      setState(() {
        if (multi) {
          if (!_fallbackSelection.add(id)) {
            _fallbackSelection.remove(id);
          }
        } else {
          _fallbackSelection
            ..clear()
            ..add(id);
        }
      });
      return;
    }
    if (multi) {
      selection.toggle(id);
    } else {
      selection.select(<String>[id]);
    }
  }

  Set<String> _selectedIds(BuildContext context) =>
      _maybeWatch<WbSelectionState>(context)?.ids ?? _fallbackSelection;

  T? _maybeRead<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  T? _maybeWatch<T>(BuildContext context) {
    try {
      return context.watch<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Set<String> selected = _selectedIds(context);
    final List<_LayerEntry> rows = _rows;
    if (!_loaded) {
      return const SizedBox.expand();
    }
    if (rows.isEmpty) {
      return Center(
        child: Text(
          '暂无元素',
          key: const ValueKey<String>('layers-empty'),
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colors.icon),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_demoMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
            child: Text(
              '演示模式：样例元素',
              key: const ValueKey<String>('layers-demo-hint'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: colors.icon,
                  ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey<String>('layers-list'),
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            itemCount: rows.length + 1, // 末位为「拖到末尾」投放区。
            itemBuilder: (BuildContext context, int index) {
              if (index == rows.length) {
                return _buildTailDropZone(context, rows);
              }
              return _buildItem(context, rows, index, selected);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildItem(
    BuildContext context,
    List<_LayerEntry> rows,
    int index,
    Set<String> selected,
  ) {
    final _LayerEntry entry = rows[index];
    final bool isSelected = selected.contains(entry.id);
    final bool showLine = _draggingId != null && _dropIndex == index;
    return DragTarget<String>(
      onWillAcceptWithDetails: (DragTargetDetails<String> details) =>
          details.data != entry.id,
      onMove: (DragTargetDetails<String> details) => _setDropIndex(index),
      onLeave: (Object? data) => _clearDropIndex(index),
      onAcceptWithDetails: (DragTargetDetails<String> details) =>
          _dropOn(details.data, index),
      builder: (
        BuildContext context,
        List<String?> candidateData,
        List<Object?> rejectedData,
      ) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (showLine)
              Container(
                key: ValueKey<String>('layer-drop-line-$index'),
                height: 2,
                margin: const EdgeInsets.symmetric(vertical: 1),
                color: context.wbColors.primary,
              ),
            Draggable<String>(
              data: entry.id,
              key: ValueKey<String>('layer-drag-${entry.id}'),
              maxSimultaneousDrags: entry.locked ? 0 : 1,
              onDragStarted: () {
                setState(() {
                  _draggingId = entry.id;
                  _dropIndex = -1;
                });
              },
              onDragEnd: (DraggableDetails details) => _endDrag(),
              feedback: _LayerDragFeedback(
                type: entry.type,
                name: _entryDisplayName(entry, rows.length - index),
              ),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: _buildRow(context, rows, index, isSelected),
              ),
              child: _buildRow(context, rows, index, isSelected),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRow(
    BuildContext context,
    List<_LayerEntry> rows,
    int index,
    bool isSelected,
  ) {
    final _LayerEntry entry = rows[index];
    final WbThemeColors colors = context.wbColors;
    final WbLayerTypeVisual visual = wbLayerTypeVisual(entry.type);
    final int zRank = rows.length - index;
    return Opacity(
      opacity: entry.visible ? 1 : 0.55,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey<String>('layer-row-${entry.id}'),
          onTap: () => _handleRowTap(entry, zRank),
          onSecondaryTapDown: (TapDownDetails details) => unawaited(
            _openMenu(context, rows, index, anchor: details.globalPosition),
          ),
          hoverColor: colors.hover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              children: <Widget>[
                Container(
                  key: ValueKey<String>('layer-selected-${entry.id}'),
                  width: 2,
                  height: 18,
                  margin: const EdgeInsets.only(right: 6),
                  color: isSelected ? colors.primary : Colors.transparent,
                ),
                Icon(visual.icon, size: 15, color: colors.icon),
                const SizedBox(width: 8),
                Expanded(child: _buildName(context, entry, zRank)),
                IconButton(
                  key: ValueKey<String>('layer-lock-${entry.id}'),
                  icon: Icon(
                    entry.locked ? LinearIcons.lock : LinearIcons.unlock,
                    size: 15,
                    color: entry.locked
                        ? colors.primary
                        : colors.icon.withValues(alpha: 0.45),
                  ),
                  tooltip: entry.locked ? '解锁' : '锁定',
                  onPressed: () => _toggleLocked(entry.id),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 26, minHeight: 26),
                  splashRadius: 14,
                ),
                IconButton(
                  key: ValueKey<String>('layer-visible-${entry.id}'),
                  icon: WbVisibilityIcon(
                    visible: entry.visible,
                    size: 15,
                    color: colors.icon,
                  ),
                  tooltip: entry.visible ? '隐藏' : '显示',
                  onPressed: () => _toggleVisible(entry.id),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 26, minHeight: 26),
                  splashRadius: 14,
                ),
                IconButton(
                  key: ValueKey<String>('layer-menu-${entry.id}'),
                  icon: Icon(LinearIcons.more, size: 15, color: colors.icon),
                  tooltip: '更多操作',
                  onPressed: () => unawaited(_openMenu(context, rows, index)),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 26, minHeight: 26),
                  splashRadius: 14,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildName(BuildContext context, _LayerEntry entry, int zRank) {
    final String name = _entryDisplayName(entry, zRank);
    if (_renamingId == entry.id) {
      return SizedBox(
        height: 22,
        child: TextField(
          key: ValueKey<String>('layer-rename-${entry.id}'),
          controller: _renameController,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          onSubmitted: (String value) => _commitRename(entry.id, value),
          onTapOutside: (PointerDownEvent event) =>
              _commitRename(entry.id, _renameController.text),
        ),
      );
    }
    return Text(
      name,
      key: ValueKey<String>('layer-name-${entry.id}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
    );
  }

  Widget _buildTailDropZone(BuildContext context, List<_LayerEntry> rows) {
    final bool active = _draggingId != null && _dropIndex == rows.length;
    return DragTarget<String>(
      key: const ValueKey<String>('layer-end-drop'),
      onWillAcceptWithDetails: (DragTargetDetails<String> details) => true,
      onMove: (DragTargetDetails<String> details) =>
          _setDropIndex(rows.length),
      onLeave: (Object? data) => _clearDropIndex(rows.length),
      onAcceptWithDetails: (DragTargetDetails<String> details) =>
          _dropOn(details.data, rows.length),
      builder: (
        BuildContext context,
        List<String?> candidateData,
        List<Object?> rejectedData,
      ) {
        return SizedBox(
          height: 28,
          child: active
              ? Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    key: const ValueKey<String>('layer-drop-line-end'),
                    height: 2,
                    margin: const EdgeInsets.symmetric(vertical: 1),
                    color: context.wbColors.primary,
                  ),
                )
              : null,
        );
      },
    );
  }
}

/// 拖拽反馈（类型图标 + 图层名，design §5.3）。
class _LayerDragFeedback extends StatelessWidget {
  const _LayerDragFeedback({required this.type, required this.name});

  /// 元素类型（图标按类型映射）。
  final String type;

  /// 图层显示名。
  final String name;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbLayerTypeVisual visual = wbLayerTypeVisual(type);
    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey<String>('layer-drag-feedback'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.elevated,
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(6),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(visual.icon, size: 15, color: colors.icon),
            const SizedBox(width: 6),
            Text(
              name,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
