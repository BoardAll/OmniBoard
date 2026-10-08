/// 页面管理：页面卡片列表 / 缩略图刷新 / 拖拽排序 / 右键菜单 / 多选
/// （桌面 / Web 共享）。
///
/// 覆盖《左侧栏与页面管理设计》§4：页面区（列表、缩略图、悬停操作、
/// 右键菜单、拖拽排序、多选、导航、缩略图刷新、页面状态）。
///
/// - 数据：消费 [WbPageState]（引擎可用时增删改走引擎，否则演示模式）；
/// - 缩略图：引擎可用时经 [WbCanvasEngine.thumbnail] 取 PNG，否则静态预览
///   （背景图片经 [PageThumbnail.previewImageProvider] 由宿主注入）；
/// - 背景入口：由宿主经 [PageManager.onEditBackground] 注入（null 时菜单项
///   隐藏）；共享包不内置平台专有的背景对话框；
/// - 文件内同时提供 [WbVisibilityIcon]（本体未提供 eye-off，图标包巡检见注释）
///   供页面卡片与图层行共用。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_core/wb_core_common.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../canvas/background_painter.dart';
import '../services/canvas_engine.dart';
import '../state/page_state.dart';

/// 背景 JSON 浅比较（值为原始类型的扁平对象，无需深比较）。
bool _sameBackgroundJson(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final MapEntry<String, dynamic> entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// 共享小部件
// ---------------------------------------------------------------------------

/// 可见性图标：显示态为「眼睛」，隐藏态为「眼睛 + 斜线」。
///
/// design §18 建议 eye-off 图标，但 `packages/icons` 语义清单未提供该变体，
/// 因此按「不新增图标依赖」的约束以合成方式表达隐藏态。
class WbVisibilityIcon extends StatelessWidget {
  const WbVisibilityIcon({
    super.key,
    required this.visible,
    this.size = 16,
    this.color,
  });

  /// 是否可见。
  final bool visible;

  /// 图标边长。
  final double size;

  /// 显式颜色（缺省取当前主题图标色）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color resolved = color ?? context.wbColors.icon;
    if (visible) {
      return Icon(LinearIcons.visible, size: size, color: resolved);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Icon(
            LinearIcons.visible,
            size: size,
            color: resolved.withValues(alpha: 0.55),
          ),
          // 斜线（-45°），表达「已隐藏」。
          Transform.rotate(
            angle: -0.7853981633974483,
            child: Container(
              width: size * 0.9,
              height: 1.5,
              color: resolved,
            ),
          ),
        ],
      ),
    );
  }
}

/// 拖拽插入位置指示线（2px 主色，design §4.6）。
class _DropLine extends StatelessWidget {
  const _DropLine({super.key, required this.colors});

  final WbThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 2,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

/// 页码徽标。
class _PageBadge extends StatelessWidget {
  const _PageBadge({required this.index, this.selected = false});

  final int index;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? colors.primary : colors.cardHover,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$index',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: selected ? theme.colorScheme.onPrimary : colors.icon,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 缩略图
// ---------------------------------------------------------------------------

/// 页面缩略图。
///
/// 刷新时机（design §4.9）：
/// - [epoch] 变化（页面切换 / 手动刷新）→ 立即重新加载；
/// - [WbPage.elementCount] 变化（编辑产生）→ 防抖 [refreshDebounce] 后刷新；
/// - [WbPage.background] 变化（问题 1）→ 引擎模式重新取 PNG，
///   静态预览随重建即时生效；
/// - 演示模式渲染静态预览（背景色 / 图案 / 背景图 + 元素数），
///   引擎可用时渲染返回的 PNG。
class PageThumbnail extends StatefulWidget {
  const PageThumbnail({
    super.key,
    required this.page,
    this.epoch = 0,
    this.width = 200,
    this.height = 125,
    this.previewImageProvider,
  });

  /// 页面摘要。
  final WbPage page;

  /// 刷新令牌：变化即重新加载。
  final int epoch;

  /// 缩略图宽（design §4.3：200×125，16:10）。
  final double width;

  /// 缩略图高。
  final double height;

  /// 背景图片的图片提供者（桌面注入 `FileImage`；Web 省略或 blob URL）。
  ///
  /// null 时背景图片不进入静态预览（仍显示底色 + 元素数角标）。
  final ImageProvider Function(String path)? previewImageProvider;

  /// 编辑停止后刷新缩略图的防抖间隔（design §4.9：500ms）。
  static const Duration refreshDebounce = Duration(milliseconds: 500);

  /// 刷新淡入时长（design §9.4：200ms ease-out）。
  static const Duration fadeDuration = Duration(milliseconds: 200);

  @override
  State<PageThumbnail> createState() => _PageThumbnailState();
}

class _PageThumbnailState extends State<PageThumbnail> {
  Uint8List? _bytes;
  bool _pending = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _bytes = _loadBytes();
  }

  @override
  void didUpdateWidget(PageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.page.id != oldWidget.page.id ||
        widget.epoch != oldWidget.epoch) {
      _debounce?.cancel();
      _pending = false;
      _bytes = _loadBytes();
      return;
    }
    if (widget.page.elementCount != oldWidget.page.elementCount) {
      _scheduleDebouncedRefresh();
      return;
    }
    // 背景变化（问题 1）：引擎 PNG 需重新渲染；静态预览随本帧重建即时生效，
    // 此处仅回退骨架并重新取图。
    if (!_sameBackgroundJson(widget.page.background, oldWidget.page.background)) {
      _debounce?.cancel();
      _pending = false;
      _bytes = _loadBytes();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// 编辑停止 [PageThumbnail.refreshDebounce] 后刷新（期间显示骨架）。
  void _scheduleDebouncedRefresh() {
    _debounce?.cancel();
    // didUpdateWidget 之后必然跟随一次 build，可直接赋值。
    _pending = true;
    _debounce = Timer(PageThumbnail.refreshDebounce, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _pending = false;
        _bytes = _loadBytes();
      });
    });
  }

  /// 宽容读取 Provider（缺省时返回 null；Web 未接线场景不抛错）。
  static T? _maybeRead<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// 读取缩略图（引擎可用时取 PNG；否则返回 null 表示静态预览）。
  Uint8List? _loadBytes() {
    final WbCanvasEngine? engine = _maybeRead<WbCanvasEngine>(context);
    if (engine == null || !engine.isAvailable) {
      return null;
    }
    try {
      return engine.thumbnail(
        widget.page.id,
        widget.width.round(),
        widget.height.round(),
      );
    } catch (_) {
      // 引擎渲染失败 → 回退静态预览（错误呈现交由通知中心）。
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Widget child;
    if (_pending) {
      // 骨架屏（静态色块：骨架 shimmer 为无限动画，会阻塞测试 pumpAndSettle）。
      child = Container(
        key: ValueKey<String>('page-thumb-loading-${widget.page.id}'),
        color: colors.cardHover,
      );
    } else {
      final Uint8List? bytes = _bytes;
      if (bytes != null) {
        child = Image.memory(
          bytes,
          key: ValueKey<String>('page-thumb-image-${widget.page.id}'),
          width: widget.width,
          height: widget.height,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      } else {
        child = _buildPreview(colors);
      }
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: AnimatedSwitcher(
          duration: PageThumbnail.fadeDuration,
          switchInCurve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }

  Widget _buildPreview(WbThemeColors colors) {
    final WbPageBackground background = WbPageBackground.fromJson(
      widget.page.background,
      fallback: colors.canvas,
    );
    final ImageProvider Function(String path)? provider =
        widget.previewImageProvider;
    return WbPageBackgroundLayer(
      key: ValueKey<String>('page-thumb-ready-${widget.page.id}'),
      background: background,
      imageBuilder: background.hasImage && provider != null
          ? (BuildContext context) => Image(
                image: provider(background.imagePath),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (
                  BuildContext context,
                  Object error,
                  StackTrace? stackTrace,
                ) =>
                    const SizedBox.shrink(),
              )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            LinearIcons.page,
            size: 20,
            color: colors.icon.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.page.elementCount} 元素',
            style: TextStyle(fontSize: 10, color: colors.icon),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 页面管理器
// ---------------------------------------------------------------------------

/// 页面背景编辑结果：新背景对象 + 是否应用到全部页面。
class WbPageBackgroundEditResult {
  const WbPageBackgroundEditResult({
    required this.background,
    this.applyToAll = false,
  });

  /// 完整背景对象（background 域存储形态，含可选 `imagePath`）。
  final Map<String, dynamic> background;

  /// true 时由 [PageManager] 应用到全部页面。
  final bool applyToAll;
}

/// 页面管理器。
///
/// 由侧栏「页面」分区挂载（内容区，不含分区标题）；也可独立挂载为纯列表。
class PageManager extends StatefulWidget {
  const PageManager({
    super.key,
    this.refreshSignal,
    this.showThumbnails = true,
    this.canEdit = true,
    this.onBlockedEdit,
    this.onEditBackground,
    this.previewImageProvider,
  });

  /// 外部刷新信号（侧栏「刷新缩略图」按钮）：通知即刷新全部缩略图。
  final Listenable? refreshSignal;

  /// 是否渲染缩略图（design §12「显示缩略图」设置项，默认显示）。
  final bool showThumbnails;

  /// 是否允许编辑（M3 只读收窄；false 时新建 / 删除 / 复制 / 重命名 /
  /// 锁定 / 隐藏 / 背景 / 排序等编辑入口被拦）。
  final bool canEdit;

  /// 编辑被拦时的统一提示回调（宿主弹轻提示；null 时静默）。
  final VoidCallback? onBlockedEdit;

  /// 背景编辑入口：返回编辑结果（null = 取消）；null 时菜单「设置背景」隐藏。
  ///
  /// 桌面宿主提供完整对话框（含背景图片）；Web 宿主提供浏览器版。
  final Future<WbPageBackgroundEditResult?> Function(
    BuildContext context,
    WbPage page,
  )? onEditBackground;

  /// 缩略图静态预览的图片提供者（透传 [PageThumbnail.previewImageProvider]）。
  final ImageProvider Function(String path)? previewImageProvider;

  /// 以页面管理器 context 打开重命名对话框；context 需在 Provider 之下。
  static Future<void> openRenameDialog(
    BuildContext context,
    WbPage page,
  ) async {
    final WbPageState state = context.read<WbPageState>();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _PageRenameDialog(initialName: page.name),
    );
    if (name != null && name.isNotEmpty) {
      state.rename(page.id, name);
    }
  }

  @override
  State<PageManager> createState() => _PageManagerState();
}

/// 页面重命名对话框。
///
/// 控制器由本 State 持有并随对话框元素卸载而释放：`showDialog` 的
/// Future 在 `Navigator.pop` 时即恢复执行，而对话框仍在播放退出动画，
/// 若在 await 之后立刻释放控制器，退出帧中的文本框会引用已销毁对象。
class _PageRenameDialog extends StatefulWidget {
  const _PageRenameDialog({required this.initialName});

  /// 打开对话框时的页面名称。
  final String initialName;

  @override
  State<_PageRenameDialog> createState() => _PageRenameDialogState();
}

class _PageRenameDialogState extends State<_PageRenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名页面'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '页面名称'),
        onSubmitted: (String value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _PageManagerState extends State<PageManager> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'wb.pages');
  final Set<String> _selectedIds = <String>{};
  String? _anchorId;
  String? _draggingId;
  int? _dropIndex;
  int _globalEpoch = 0;
  final Map<String, int> _pageEpochs = <String, int>{};
  String _lastCurrentId = '';

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_onExternalRefresh);
  }

  @override
  void didUpdateWidget(PageManager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      oldWidget.refreshSignal?.removeListener(_onExternalRefresh);
      widget.refreshSignal?.addListener(_onExternalRefresh);
    }
  }

  @override
  void dispose() {
    widget.refreshSignal?.removeListener(_onExternalRefresh);
    _focusNode.dispose();
    super.dispose();
  }

  void _onExternalRefresh() {
    if (mounted) {
      setState(() => _globalEpoch++);
    }
  }

  /// 页面切换时递增该页刷新令牌（下一帧执行，避免在 build 中 setState）。
  void _syncCurrentPageEpoch(String currentPageId) {
    if (currentPageId == _lastCurrentId) {
      return;
    }
    _lastCurrentId = currentPageId;
    if (currentPageId.isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pageEpochs[currentPageId] = (_pageEpochs[currentPageId] ?? 0) + 1;
      });
    });
  }

  int _epochFor(WbPage page) => _globalEpoch + (_pageEpochs[page.id] ?? 0);

  // ---- 权限守卫（M3 只读收窄） ----

  /// 编辑守卫：无编辑权限时经 [PageManager.onBlockedEdit] 提示并拒绝。
  bool _guardEdit() {
    if (widget.canEdit) {
      return true;
    }
    widget.onBlockedEdit?.call();
    return false;
  }

  /// 新建页面（M3 只读收窄：无编辑权限时拦截）。
  void _addPage(WbPageState state) {
    if (!_guardEdit()) {
      return;
    }
    state.addPage();
  }

  // ---- 交互 ----

  void _onCardTap(WbPageState state, WbPage page) {
    _focusNode.requestFocus();
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      setState(() {
        if (_selectedIds.contains(page.id)) {
          _selectedIds.remove(page.id);
        } else {
          _selectedIds.add(page.id);
          _anchorId = page.id;
        }
      });
      return;
    }
    if (keyboard.isShiftPressed && _anchorId != null) {
      final List<WbPage> pages = state.pages;
      final int a = pages.indexWhere((WbPage p) => p.id == _anchorId);
      final int b = pages.indexWhere((WbPage p) => p.id == page.id);
      if (a >= 0 && b >= 0) {
        final int from = a < b ? a : b;
        final int to = a < b ? b : a;
        setState(() {
          _selectedIds
            ..clear()
            ..addAll(<String>[
              for (int i = from; i <= to; i++) pages[i].id,
            ]);
        });
        return;
      }
    }
    setState(() {
      _selectedIds
        ..clear()
        ..add(page.id);
      _anchorId = page.id;
    });
    state.select(page.id);
  }

  /// 多选目标集：[page] 在多选中时返回全部选中页，否则仅 [page]。
  List<String> _selectionFor(WbPageState state, WbPage page) {
    if (_selectedIds.length > 1 && _selectedIds.contains(page.id)) {
      return <String>[
        for (final WbPage p in state.pages)
          if (_selectedIds.contains(p.id)) p.id,
      ];
    }
    return <String>[page.id];
  }

  WbPage? _targetPage(WbPageState state) {
    final List<WbPage> pages = state.pages;
    for (final WbPage page in pages) {
      if (_selectedIds.contains(page.id)) {
        return page;
      }
    }
    for (final WbPage page in pages) {
      if (page.id == state.currentPageId) {
        return page;
      }
    }
    return pages.isEmpty ? null : pages.first;
  }

  void _clearMultiSelection() {
    if (_selectedIds.isEmpty) {
      return;
    }
    setState(() => _selectedIds.clear());
  }

  /// 页面导航（design §4.8）：PageUp / PageDown，循环。
  void _step(WbPageState state, int delta) {
    final List<WbPage> pages = state.pages;
    if (pages.isEmpty) {
      return;
    }
    final int index = pages.indexWhere((WbPage p) => p.id == state.currentPageId);
    final int base = index < 0 ? 0 : index;
    final int next = (base + delta) % pages.length;
    state.select(pages[next].id);
  }

  void _renameSelection(WbPageState state) {
    if (!_guardEdit()) {
      return;
    }
    final WbPage? page = _targetPage(state);
    if (page == null) {
      return;
    }
    unawaited(PageManager.openRenameDialog(context, page));
  }

  void _duplicateSelection(WbPageState state) {
    if (!_guardEdit()) {
      return;
    }
    final WbPage? page = _targetPage(state);
    if (page == null) {
      return;
    }
    for (final String id in _selectionFor(state, page)) {
      state.duplicate(id);
    }
  }

  void _deleteSelection(WbPageState state) {
    if (!_guardEdit()) {
      return;
    }
    final WbPage? page = _targetPage(state);
    if (page == null) {
      return;
    }
    _deletePages(state, page);
  }

  /// 删除（多选时批量；至少保留一页）。
  void _deletePages(WbPageState state, WbPage page) {
    if (!_guardEdit()) {
      return;
    }
    final List<String> ids = _selectionFor(state, page);
    if (state.pages.length <= ids.length) {
      return;
    }
    for (final String id in ids) {
      state.remove(id);
    }
    setState(() => _selectedIds.clear());
  }

  /// 上移 / 下移（块状移动，保持多选内部顺序）。
  void _moveRelative(WbPageState state, WbPage page, int delta) {
    if (!_guardEdit()) {
      return;
    }
    final List<String> ids = _selectionFor(state, page);
    final List<WbPage> pages = state.pages;
    final List<int> positions = <int>[
      for (int i = 0; i < pages.length; i++)
        if (ids.contains(pages[i].id)) i,
    ];
    if (positions.isEmpty) {
      return;
    }
    state.moveMany(ids, delta < 0 ? positions.first - 1 : positions.last + 2);
  }

  void _moveToEdge(WbPageState state, WbPage page, bool toFront) {
    if (!_guardEdit()) {
      return;
    }
    final List<String> ids = _selectionFor(state, page);
    state.moveMany(ids, toFront ? 0 : state.pages.length);
  }

  Future<void> _pickBackground(
    BuildContext context,
    WbPageState state,
    WbPage page,
  ) async {
    if (!_guardEdit()) {
      return;
    }
    final Future<WbPageBackgroundEditResult?> Function(
      BuildContext,
      WbPage,
    )? edit = widget.onEditBackground;
    if (edit == null) {
      return;
    }
    final WbPageBackgroundEditResult? result = await edit(context, page);
    if (result == null || !mounted || !context.mounted) {
      return;
    }
    if (result.applyToAll) {
      for (final WbPage item in state.pages) {
        state.setBackground(item.id, result.background);
      }
      _notify(context, '背景已应用到全部 ${state.pages.length} 页');
    } else {
      state.setBackground(page.id, result.background);
      _notify(context, '背景已应用到当前页');
    }
  }

  void _notify(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1500),
      ),
    );
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
    setState(() => _dropIndex = null);
  }

  void _endDrag() {
    if (_draggingId == null && _dropIndex == null) {
      return;
    }
    setState(() {
      _draggingId = null;
      _dropIndex = null;
    });
  }

  /// 投放：拖到第 [targetIndex] 张卡片之前（= 原列表坐标插入位）。
  void _dropOn(WbPageState state, String draggedId, int targetIndex) {
    if (!_guardEdit()) {
      return;
    }
    state.moveMany(<String>[draggedId], targetIndex);
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

  Future<void> _openPageMenu(
    BuildContext context,
    WbPageState state,
    WbPage page,
    int index,
    Offset position,
  ) async {
    final WbThemeColors colors = context.wbColors;
    final List<WbPage> pages = state.pages;
    final bool multi = _selectedIds.length > 1 && _selectedIds.contains(page.id);
    final int count = multi ? _selectedIds.length : 1;
    final bool canMoveUp = index > 0;
    final bool canMoveDown = index < pages.length - 1;
    final String? action = await showMenu<String>(
      context: context,
      position: _menuPosition(context, position),
      items: <PopupMenuEntry<String>>[
        _menuItem(
          colors,
          'duplicate',
          LinearIcons.duplicate,
          multi ? '复制 $count 页' : '复制页面',
        ),
        _menuItem(colors, 'create', LinearIcons.addPage, '新建页面'),
        const PopupMenuDivider(),
        _menuItem(colors, 'rename', LinearIcons.pen, '重命名', enabled: !multi),
        _menuItem(
          colors,
          'lock',
          page.locked ? LinearIcons.unlock : LinearIcons.lock,
          page.locked ? '解锁' : '锁定',
        ),
        _menuItem(
          colors,
          'hide',
          LinearIcons.visible,
          page.hidden ? '显示' : '隐藏',
        ),
        const PopupMenuDivider(),
        if (widget.onEditBackground != null)
          _menuItem(colors, 'background', LinearIcons.palette, '设置背景'),
        _menuItem(colors, 'export', LinearIcons.export, '导出此页'),
        const PopupMenuDivider(),
        _menuItem(
          colors,
          'up',
          LinearIcons.bringForward,
          '上移',
          enabled: canMoveUp,
        ),
        _menuItem(
          colors,
          'down',
          LinearIcons.sendBackward,
          '下移',
          enabled: canMoveDown,
        ),
        _menuItem(
          colors,
          'front',
          LinearIcons.bringToFront,
          '移到最前',
          enabled: canMoveUp,
        ),
        _menuItem(
          colors,
          'back',
          LinearIcons.sendToBack,
          '移到最后',
          enabled: canMoveDown,
        ),
        const PopupMenuDivider(),
        _menuItem(
          colors,
          'delete',
          LinearIcons.delete,
          multi ? '删除 $count 页' : '删除页面',
          enabled: pages.length > count,
        ),
      ],
    );
    if (action == null || !mounted || !context.mounted) {
      return;
    }
    // M3 只读收窄：编辑动作在派发前统一守卫（export 仅提示，不拦截）。
    const Set<String> editActions = <String>{
      'duplicate',
      'create',
      'rename',
      'lock',
      'hide',
      'background',
      'up',
      'down',
      'front',
      'back',
      'delete',
    };
    if (editActions.contains(action) && !_guardEdit()) {
      return;
    }
    switch (action) {
      case 'duplicate':
        for (final String id in _selectionFor(state, page)) {
          state.duplicate(id);
        }
      case 'create':
        state.addPage();
      case 'rename':
        unawaited(PageManager.openRenameDialog(context, page));
      case 'lock':
        state.setLocked(page.id, !page.locked);
      case 'hide':
        state.setHidden(page.id, !page.hidden);
      case 'background':
        unawaited(_pickBackground(context, state, page));
      case 'export':
        _notify(context, '导出此页：引擎导出链路接入后可用');
      case 'up':
        _moveRelative(state, page, -1);
      case 'down':
        _moveRelative(state, page, 1);
      case 'front':
        _moveToEdge(state, page, true);
      case 'back':
        _moveToEdge(state, page, false);
      case 'delete':
        _deletePages(state, page);
    }
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final WbPageState state = context.watch<WbPageState>();
    final List<WbPage> pages = state.pages;
    _selectedIds.removeWhere(
      (String id) => !pages.any((WbPage p) => p.id == id),
    );
    if (_anchorId != null && !pages.any((WbPage p) => p.id == _anchorId)) {
      _anchorId = null;
    }
    _syncCurrentPageEpoch(state.currentPageId);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _step(state, -1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () =>
            _step(state, 1),
        const SingleActivator(LogicalKeyboardKey.f2): () =>
            _renameSelection(state),
        const SingleActivator(LogicalKeyboardKey.delete): () =>
            _deleteSelection(state),
        const SingleActivator(LogicalKeyboardKey.keyD, control: true): () =>
            _duplicateSelection(state),
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true): () =>
            _duplicateSelection(state),
        const SingleActivator(LogicalKeyboardKey.escape): _clearMultiSelection,
      },
      child: Focus(
        focusNode: _focusNode,
        child: Column(
          children: <Widget>[
            Expanded(child: _buildList(context, state, pages)),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: state.boardId.isEmpty
                      ? null
                      : () => _addPage(state),
                  icon: const Icon(LinearIcons.addPage, size: 18),
                  label: const Text('添加页面'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    WbPageState state,
    List<WbPage> pages,
  ) {
    final WbThemeColors colors = context.wbColors;
    if (pages.isEmpty) {
      return Center(
        child: Text(
          '暂无页面',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colors.icon),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      itemCount: pages.length + 1, // 末位为「拖到末尾」投放区。
      itemBuilder: (BuildContext context, int index) {
        if (index == pages.length) {
          return _buildTailDropZone(context, state, pages);
        }
        return _buildItem(context, state, pages, pages[index], index);
      },
    );
  }

  Widget _buildItem(
    BuildContext context,
    WbPageState state,
    List<WbPage> pages,
    WbPage page,
    int index,
  ) {
    final bool selected = page.id == state.currentPageId;
    final bool multiSelected = _selectedIds.contains(page.id);
    final bool showLine = _draggingId != null && _dropIndex == index;
    return DragTarget<String>(
      onWillAcceptWithDetails: (DragTargetDetails<String> details) =>
          details.data != page.id,
      onMove: (DragTargetDetails<String> details) => _setDropIndex(index),
      onLeave: (Object? data) => _clearDropIndex(index),
      onAcceptWithDetails: (DragTargetDetails<String> details) =>
          _dropOn(state, details.data, index),
      builder: (
        BuildContext context,
        List<String?> candidateData,
        List<Object?> rejectedData,
      ) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (showLine)
              _DropLine(
                key: ValueKey<String>('page-drop-line-$index'),
                colors: context.wbColors,
              ),
            Draggable<String>(
              data: page.id,
              key: ValueKey<String>('page-drag-${page.id}'),
              // M3 只读收窄：无编辑权限时禁止拖拽排序。
              maxSimultaneousDrags: (page.locked || !widget.canEdit) ? 0 : 1,
              onDragStarted: () {
                setState(() {
                  _draggingId = page.id;
                  _dropIndex = null;
                });
              },
              onDragEnd: (DraggableDetails details) => _endDrag(),
              feedback: _DragFeedback(page: page, index: index),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: _PageCard(
                  page: page,
                  index: index,
                  selected: selected,
                  multiSelected: multiSelected,
                  epoch: _epochFor(page),
                  showThumbnail: widget.showThumbnails,
                  previewImageProvider: widget.previewImageProvider,
                  onTap: () => _onCardTap(state, page),
                  onSecondaryTap: (Offset position) => unawaited(
                    _openPageMenu(context, state, page, index, position),
                  ),
                  onMenu: (Offset position) => unawaited(
                    _openPageMenu(context, state, page, index, position),
                  ),
                ),
              ),
              child: _PageCard(
                page: page,
                index: index,
                selected: selected,
                multiSelected: multiSelected,
                epoch: _epochFor(page),
                showThumbnail: widget.showThumbnails,
                previewImageProvider: widget.previewImageProvider,
                onTap: () => _onCardTap(state, page),
                onSecondaryTap: (Offset position) => unawaited(
                  _openPageMenu(context, state, page, index, position),
                ),
                onMenu: (Offset position) => unawaited(
                  _openPageMenu(context, state, page, index, position),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTailDropZone(
    BuildContext context,
    WbPageState state,
    List<WbPage> pages,
  ) {
    final bool active = _draggingId != null && _dropIndex == pages.length;
    return DragTarget<String>(
      onWillAcceptWithDetails: (DragTargetDetails<String> details) => true,
      onMove: (DragTargetDetails<String> details) => _setDropIndex(pages.length),
      onLeave: (Object? data) => _clearDropIndex(pages.length),
      onAcceptWithDetails: (DragTargetDetails<String> details) =>
          _dropOn(state, details.data, pages.length),
      builder: (
        BuildContext context,
        List<String?> candidateData,
        List<Object?> rejectedData,
      ) {
        return SizedBox(
          height: 36,
          child: active
              ? Align(
                  alignment: Alignment.topCenter,
                  child: _DropLine(
                    key: const ValueKey<String>('page-drop-line-end'),
                    colors: context.wbColors,
                  ),
                )
              : null,
        );
      },
    );
  }
}

/// 拖拽反馈（页码 + 页面名预览，design §4.6）。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.page, required this.index});

  final WbPage page;
  final int index;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      key: const ValueKey<String>('page-drag-feedback'),
      color: Colors.transparent,
      child: Opacity(
        opacity: 0.92,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: colors.elevated,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.primary),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _PageBadge(index: index + 1, selected: true),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  page.name.isEmpty ? '第 ${index + 1} 页' : page.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 页面卡片（顶部页码 + 名称 + 状态/操作，中部缩略图）。
class _PageCard extends StatefulWidget {
  const _PageCard({
    required this.page,
    required this.index,
    required this.selected,
    required this.multiSelected,
    required this.epoch,
    required this.showThumbnail,
    required this.onTap,
    required this.onSecondaryTap,
    required this.onMenu,
    this.previewImageProvider,
  });

  final WbPage page;
  final int index;
  final bool selected;
  final bool multiSelected;
  final int epoch;
  final bool showThumbnail;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onSecondaryTap;
  final void Function(Offset globalPosition) onMenu;
  final ImageProvider Function(String path)? previewImageProvider;

  @override
  State<_PageCard> createState() => _PageCardState();
}

class _PageCardState extends State<_PageCard> {
  bool _hovered = false;

  void _openMenuAtCard() {
    final RenderBox box = context.findRenderObject()! as RenderBox;
    widget.onMenu(
      box.localToGlobal(box.size.topRight(const Offset(-8.0, 8.0))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final bool selected = widget.selected;
    return MouseRegion(
      onEnter: (PointerEnterEvent event) => setState(() => _hovered = true),
      onExit: (PointerExitEvent event) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 100),
        opacity: widget.page.hidden ? 0.55 : 1,
        child: Container(
          key: ValueKey<String>('page-card-${widget.page.id}'),
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary.withValues(alpha: 0.08)
                : colors.cardBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? colors.primary
                  : widget.multiSelected
                      ? colors.primary.withValues(alpha: 0.6)
                      : colors.cardBorder,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              hoverColor: colors.cardHover,
              onTap: widget.onTap,
              onSecondaryTapDown: (TapDownDetails details) =>
                  widget.onSecondaryTap(details.globalPosition),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _buildHeaderRow(context, colors, selected),
                    if (widget.showThumbnail) ...<Widget>[
                      const SizedBox(height: 6),
                      LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints c) {
                          final double width =
                              c.maxWidth > 200 ? 200 : c.maxWidth;
                          return PageThumbnail(
                            key: ValueKey<String>(
                              'page-thumb-${widget.page.id}',
                            ),
                            page: widget.page,
                            epoch: widget.epoch,
                            width: width,
                            height: width * 0.625,
                            previewImageProvider: widget.previewImageProvider,
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderRow(
    BuildContext context,
    WbThemeColors colors,
    bool selected,
  ) {
    return Row(
      children: <Widget>[
        _PageBadge(index: widget.index + 1, selected: selected),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            widget.page.name.isEmpty ? '页面 ${widget.index + 1}' : widget.page.name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
        if (widget.page.locked)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(LinearIcons.lock, size: 12, color: colors.icon),
          ),
        if (widget.page.hidden)
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: WbVisibilityIcon(visible: false, size: 12),
          ),
        if (widget.multiSelected)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(
              LinearIcons.check,
              key: ValueKey<String>('page-multi-${widget.page.id}'),
              size: 12,
              color: colors.primary,
            ),
          ),
        if (_hovered) ...<Widget>[
          // 拖拽手柄（整卡可拖；手柄为悬停提示）。
          Tooltip(
            message: '拖拽排序',
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(LinearIcons.menu, size: 14, color: colors.icon),
            ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: '页面操作',
            child: InkWell(
              key: ValueKey<String>('page-menu-${widget.page.id}'),
              borderRadius: BorderRadius.circular(4),
              onTap: _openMenuAtCard,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(LinearIcons.more, size: 14, color: colors.icon),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// 页面背景对话框段已移至宿主侧注入（onEditBackground）；共享包不内置平台专有实现。
