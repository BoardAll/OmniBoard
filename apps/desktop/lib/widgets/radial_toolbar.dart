/// 齿轮圆盘工具栏：收起为浮动按钮，展开为三层径向工具盘。
///
/// 实现《齿轮圆盘交互详细设计 v1.1》M2.5.1–M2.5.4 全部交互：
/// - 单击中心展开 / 收起；单击内环选中并收起；单击外环展开子工具；
///   双击外环选中默认工具（第 5.1 / 7.2 节）；
/// - 从中心向外拖拽：轨迹线 + 经过高亮 + 松开选中 + 回拖取消
///   （第 5.2 节）；
/// - 长按中心锁定 / 解锁（第 5.1 / 7.2 节）；
/// - 右键配置菜单（锁定 / 隐藏 / 尺寸 / 标签 / 最近使用 / 动效 / 轨迹线，
///   第 5.1 / 11 节）；
/// - 键盘：Space / Esc / 数字 1–6 / 字母快捷键 / 方向键 / Enter / Tab
///   （第 5.4 节）；
/// - 最近使用快捷条（第 3.2 节）与"更多"菜单（撤销 / 重做 / AI / 设置）。
///
/// 布局说明：组件布局外框取 360×360（[RadialMetrics.frame]），以容纳
/// 子环（半径 120–180px）的命中区域；底盘仍为 240px（
/// [RadialMetrics.discDiameter]）。已知无法在组件内实现的项（四角吸附、
/// 跨屏拖动、长按画布弹出接线、点击画布收起子工具）见实现报告偏差清单。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../routes.dart';
import '../state/board_state.dart';
import 'radial/radial_config.dart';
import 'radial/radial_layout.dart';
import 'radial/radial_menu.dart';
import 'radial/radial_models.dart';
import 'radial/radial_trail.dart';

/// 齿轮圆盘工具栏。
///
/// 对外保持无参 `const` 构造兼容；以下参数均为可选，供宿主
/// （编辑页 / 临时弹出层）按需接线：
/// - [initialSettings]：初始设置（尺寸 / 标签 / 最近使用 / 动效…）；
/// - [initialExpanded]：挂载即展开（长按弹出场景）；
/// - [autoDismiss] / [autoDismissAfter]：无操作自动淡出（弹出场景）；
/// - [onToolSelected]：选中工具回调（工具 id 与 [RadialCatalog] 对应）；
/// - [onAction]：动作回调（`more` / [kRadialAiAssistantId] /
///   [kRadialSettingsId]）；提供后不再走默认提示行为；
/// - [onSettingsChanged]：右键配置项变化回调；
/// - [onDismissed]：自动淡出结束回调（弹出层据此移除 Overlay）。
class RadialToolbar extends StatefulWidget {
  /// 构造齿轮圆盘工具栏。
  const RadialToolbar({
    super.key,
    this.initialSettings = const RadialSettings(),
    this.initialExpanded = false,
    this.autoDismiss = false,
    this.autoDismissAfter = const Duration(seconds: 3),
    this.onToolSelected,
    this.onAction,
    this.onSettingsChanged,
    this.onDismissed,
    this.onMoved,
  });

  /// 初始设置（挂载后由右键配置菜单在内部更新）。
  final RadialSettings initialSettings;

  /// 挂载即展开（默认收起）。
  final bool initialExpanded;

  /// 是否启用无操作自动淡出（长按弹出场景）。
  final bool autoDismiss;

  /// 自动淡出等待时长。
  final Duration autoDismissAfter;

  /// 选中工具回调。
  final ValueChanged<String>? onToolSelected;

  /// 动作回调（更多菜单 / 子工具中的动作入口）。
  final ValueChanged<String>? onAction;

  /// 设置变化回调。
  final ValueChanged<RadialSettings>? onSettingsChanged;

  /// 自动淡出完成（或调用方请求关闭）时回调。
  final VoidCallback? onDismissed;

  /// 折叠态中心拖动回调（携带拖动增量，用于整体移动圆盘）。
  ///
  /// 提供后：折叠态拖动中心 = 移动整体；展开 / 子环 / 拖拽选中态不受
  /// 影响（从中心向外拖拽选中仍按文档 §5.2 生效）。
  final ValueChanged<Offset>? onMoved;

  @override
  State<RadialToolbar> createState() => _RadialToolbarState();
}

class _RadialToolbarState extends State<RadialToolbar> {
  late RadialSettings _settings;

  late RadialPhase _phase;

  /// 锁定标记（文档 7.2：任意状态可锁定；锁定后点中心不收起）。
  bool _locked = false;

  /// 当前工具 id（收起态中心图标 / 内环高亮 / 最近使用高亮）。
  String _activeTool = 'select';

  /// 子环展开的分组 id。
  String? _expandedGroupId;

  /// 子环滚动偏移。
  int _subScroll = 0;

  /// 拖拽中的命中与指针位置（组件本地坐标）。
  RadialHit _dragHit = RadialHit.none;
  Offset _dragPoint = Offset.zero;

  /// 折叠态整体移动中（中心按钮拖动平移圆盘）。
  bool _moving = false;
  Offset _moveLastLocal = Offset.zero;

  /// 键盘导航焦点（当前高亮扇区）。
  RadialHit? _focusHit;

  /// 最近使用工具 id（最新在前）。
  late List<String> _recentIds;

  /// 最近一次指针是否为触屏 / 手写笔（文档 10.3：触屏放大）。
  bool _touchMode = false;

  /// 自动淡出进行中。
  bool _fading = false;

  Timer? _dismissTimer;
  Timer? _fadeTimer;

  final FocusNode _focusNode = FocusNode(debugLabel: 'wb-radial-toolbar');

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _phase =
        widget.initialExpanded ? RadialPhase.expanded : RadialPhase.collapsed;
    _recentIds = List<String>.of(RadialCatalog.defaultRecentIds);
    if (widget.autoDismiss) {
      _armDismiss();
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _fadeTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 派生状态

  /// 几何度量（档位 × 触屏放大；小屏封顶 0.75，文档 10.2 / 10.3）。
  RadialMetrics get _metrics {
    final double width = MediaQuery.maybeOf(context)?.size.width ?? 1280;
    double scale = _settings.size.scale * (_touchMode ? 1.08 : 1.0);
    if (width < 768) {
      scale = math.min(scale, RadialSizeOption.small.scale);
    }
    return RadialMetrics(scale: scale);
  }

  /// 是否小屏（宽 < 768，文档 10.2）。
  bool get _smallScreen =>
      (MediaQuery.maybeOf(context)?.size.width ?? 1280) < 768;

  /// 是否显示条目标签（小屏自动隐藏，文档 10.2）。
  bool get _showLabels => _settings.showLabels && !_smallScreen;

  /// 环是否可见（expanded / subExpanded / dragging / locked）。
  bool get _ringsVisible =>
      _phase != RadialPhase.collapsed && _phase != RadialPhase.hidden;

  /// 当前工具图标。
  IconData get _activeToolIcon =>
      RadialCatalog.toolById(_activeTool)?.icon ?? LinearIcons.select;

  /// 最近使用工具（按设置截断，过滤动作与未知 id）。
  List<RadialTool> get _recentTools {
    final List<RadialTool> result = <RadialTool>[];
    for (final String id in _recentIds) {
      final RadialTool? tool = RadialCatalog.toolById(id);
      if (tool != null && !tool.isAction) {
        result.add(tool);
      }
      if (result.length >= _settings.recentCount) {
        break;
      }
    }
    return result;
  }

  // -------------------------------------------------------------- 自动淡出

  void _armDismiss() {
    _dismissTimer?.cancel();
    if (!widget.autoDismiss) {
      return;
    }
    _dismissTimer = Timer(widget.autoDismissAfter, _handleAutoDismiss);
  }

  /// 任意交互后重置自动淡出计时。
  void _bumpDismiss() {
    if (widget.autoDismiss && !_fading) {
      _armDismiss();
    }
  }

  void _handleAutoDismiss() {
    if (!mounted || _fading) {
      return;
    }
    setState(() => _fading = true);
    _fadeTimer = Timer(const Duration(milliseconds: 260), () {
      if (mounted) {
        widget.onDismissed?.call();
      }
    });
  }

  // ------------------------------------------------------------------ 状态

  /// 选中工具（内部突变，不触发 setState）。
  void _selectTool(RadialTool tool) {
    _activeTool = tool.id;
    _pushRecent(tool.id);
    _phase = _locked ? RadialPhase.locked : RadialPhase.collapsed;
    _expandedGroupId = null;
    _subScroll = 0;
    _focusHit = null;
    _dragHit = RadialHit.none;
  }

  /// 记录最近使用（仅绘图工具；最多保留 6 条）。
  void _pushRecent(String id) {
    final RadialTool? tool = RadialCatalog.toolById(id);
    if (tool == null || tool.isAction) {
      return;
    }
    _recentIds.remove(id);
    _recentIds.insert(0, id);
    if (_recentIds.length > 6) {
      _recentIds.removeRange(6, _recentIds.length);
    }
  }

  /// 激活任意条目：动作入口 → 更多菜单；工具 → 选中并收起。
  void _activateTool(RadialTool tool) {
    _bumpDismiss();
    _focusNode.requestFocus();
    if (tool.isAction) {
      unawaited(_openMoreMenu());
      return;
    }
    if (_phase == RadialPhase.hidden) {
      _phase = RadialPhase.collapsed;
    }
    setState(() => _selectTool(tool));
    widget.onToolSelected?.call(tool.id);
  }

  /// 内环第 [index] 个条目。
  void _activateInner(int index) {
    if (index < 0 || index >= RadialCatalog.inner.length) {
      return;
    }
    _activateTool(RadialCatalog.inner[index]);
  }

  /// 子环第 [index] 个子工具（相对当前展开分组）。
  void _activateSub(int index) {
    final String? groupId = _expandedGroupId;
    if (groupId == null) {
      return;
    }
    final RadialGroup? group = RadialCatalog.groupById(groupId);
    if (group == null || index < 0 || index >= group.tools.length) {
      return;
    }
    _activateTool(group.tools[index]);
  }

  /// 外环单击：展开 / 收起 / 切换分组子工具（文档 6.3）。
  void _toggleGroup(RadialGroup group, {bool forceOpen = false}) {
    _bumpDismiss();
    _focusNode.requestFocus();
    setState(() {
      final bool sameOpen = _expandedGroupId == group.id;
      if (sameOpen && !forceOpen) {
        _expandedGroupId = null;
        _subScroll = 0;
        _phase = _locked ? RadialPhase.locked : RadialPhase.expanded;
        _focusHit = null;
      } else {
        _expandedGroupId = group.id;
        _subScroll = 0;
        _phase = _locked ? RadialPhase.locked : RadialPhase.subExpanded;
        _focusHit = const RadialHit(RadialZone.sub, index: 0, slot: 0);
      }
    });
  }

  /// 外环双击：选中默认工具并收起（文档 5.1）。
  void _activateGroupDefault(RadialGroup group) {
    _activateTool(group.defaultTool);
  }

  // ---------------------------------------------------------------- 锁定

  /// 锁定 / 解锁（长按中心、配置菜单共用，文档 5.1 / 7.2）。
  void _toggleLock() {
    if (!mounted) {
      return;
    }
    _bumpDismiss();
    setState(() {
      if (_locked) {
        _locked = false;
        _phase = RadialPhase.collapsed;
        _expandedGroupId = null;
        _subScroll = 0;
        _focusHit = null;
      } else {
        _locked = true;
        _phase = RadialPhase.locked;
      }
    });
  }

  /// 隐藏圆盘（保留恢复把手，文档 7.2 hidden 态）。
  void _hide() {
    if (!mounted) {
      return;
    }
    _bumpDismiss();
    setState(() {
      _phase = RadialPhase.hidden;
      _expandedGroupId = null;
      _subScroll = 0;
      _dragHit = RadialHit.none;
      _focusHit = null;
    });
  }

  /// 从恢复把手恢复（hidden → collapsed / locked）。
  void _restore() {
    _bumpDismiss();
    setState(() {
      _phase = _locked ? RadialPhase.locked : RadialPhase.collapsed;
    });
  }

  // ---------------------------------------------------------------- 设置

  void _applySettings(RadialSettings value) {
    if (!mounted) {
      return;
    }
    setState(() => _settings = value);
    widget.onSettingsChanged?.call(value);
  }

  void _clearRecent() {
    if (!mounted) {
      return;
    }
    _bumpDismiss();
    setState(() => _recentIds.clear());
  }

  // ------------------------------------------------------------ 中心交互

  void _onCenterTap() {
    _bumpDismiss();
    _focusNode.requestFocus();
    if (_phase == RadialPhase.hidden || _locked) {
      return;
    }
    setState(() {
      if (_phase == RadialPhase.collapsed) {
        _phase = RadialPhase.expanded;
      } else {
        _phase = RadialPhase.collapsed;
        _expandedGroupId = null;
        _subScroll = 0;
        _focusHit = null;
      }
    });
  }

  void _onCenterLongPress() {
    if (!_settings.longPressEnabled) {
      return;
    }
    _toggleLock();
  }

  // ------------------------------------------------------------ 拖拽选中

  /// 中心按钮本地坐标 → 组件本地坐标。
  Offset _buttonToLocal(Offset buttonLocal) {
    final RadialMetrics metrics = _metrics;
    return buttonLocal +
        metrics.center -
        Offset(metrics.centerRadius, metrics.centerRadius);
  }

  /// 计算拖拽命中（[autoExpandSub] 为真时经过子环带自动展开对应分组）。
  RadialHit _hitForDrag(Offset local, {required bool autoExpandSub}) {
    final RadialMetrics metrics = _metrics;
    final Offset delta = local - metrics.center;
    final double radius = delta.distance;
    final double angle = math.atan2(delta.dy, delta.dx);
    switch (zoneForRadius(radius, metrics)) {
      case RadialZone.none:
        return RadialHit.none;
      case RadialZone.inner:
        return RadialHit(
          RadialZone.inner,
          index: nearestIndexForAngle(angle, RadialCatalog.inner.length),
        );
      case RadialZone.outer:
        return RadialHit(
          RadialZone.outer,
          index: nearestIndexForAngle(angle, RadialCatalog.groups.length),
        );
      case RadialZone.sub:
        final int gi = nearestIndexForAngle(angle, RadialCatalog.groups.length);
        final RadialGroup group = RadialCatalog.groups[gi];
        if (autoExpandSub && _expandedGroupId != group.id) {
          _expandedGroupId = group.id;
          _subScroll = 0;
        }
        final int visible = math.min(kSubVisibleSlots, group.tools.length);
        final int? slot = subSlotForAngle(
          angle,
          angleForIndex(gi, RadialCatalog.groups.length),
          visible,
        );
        if (slot == null) {
          return RadialHit(RadialZone.outer, index: gi);
        }
        return RadialHit(
          RadialZone.sub,
          index: clampSubScroll(_subScroll, group.tools.length) + slot,
          slot: slot,
        );
      case RadialZone.center:
      case RadialZone.recent:
        return RadialHit.none;
    }
  }

  void _onDragStart(Offset buttonLocal) {
    if (_phase == RadialPhase.hidden) {
      return;
    }
    _bumpDismiss();
    _focusNode.requestFocus();
    // 折叠态 + 宿主提供 onMoved：拖动中心 = 移动整体（展开态仍为拖拽选中）。
    if (_phase == RadialPhase.collapsed && widget.onMoved != null) {
      _moving = true;
      _moveLastLocal = buttonLocal;
      return;
    }
    final Offset local = _buttonToLocal(buttonLocal);
    setState(() {
      _phase = RadialPhase.dragging;
      _dragPoint = local;
      _dragHit = _hitForDrag(local, autoExpandSub: true);
    });
  }

  void _onDragUpdate(Offset buttonLocal) {
    _bumpDismiss();
    if (_moving) {
      final Offset delta = buttonLocal - _moveLastLocal;
      _moveLastLocal = buttonLocal;
      if (delta != Offset.zero) {
        widget.onMoved?.call(delta);
      }
      return;
    }
    final Offset local = _buttonToLocal(buttonLocal);
    setState(() {
      _dragPoint = local;
      _dragHit = _hitForDrag(local, autoExpandSub: true);
    });
  }

  void _onDragEnd() {
    _bumpDismiss();
    if (_moving) {
      _moving = false;
      return;
    }
    final RadialHit hit = _dragHit;
    setState(() {
      _dragHit = RadialHit.none;
      switch (hit.zone) {
        case RadialZone.inner:
          _activateInner(hit.index);
        case RadialZone.outer:
          _toggleGroup(RadialCatalog.groups[hit.index], forceOpen: true);
        case RadialZone.sub:
          _activateSub(hit.index);
        case RadialZone.none:
        case RadialZone.center:
        case RadialZone.recent:
          // 回拖取消（文档 5.2）：回到展开态，不选中。
          _phase = _locked ? RadialPhase.locked : RadialPhase.expanded;
          _expandedGroupId = null;
          _subScroll = 0;
      }
    });
  }

  /// 轨迹线末端标签（文档 5.2）。
  String _trailLabel() {
    final RadialHit hit = _dragHit;
    switch (hit.zone) {
      case RadialZone.none:
        return '取消';
      case RadialZone.inner:
        return RadialCatalog.inner[hit.index].label;
      case RadialZone.outer:
        return RadialCatalog.groups[hit.index].label;
      case RadialZone.sub:
        final String? groupId = _expandedGroupId;
        final RadialGroup? group =
            groupId == null ? null : RadialCatalog.groupById(groupId);
        if (group != null && hit.index >= 0 && hit.index < group.tools.length) {
          return group.tools[hit.index].label;
        }
        return '';
      case RadialZone.center:
      case RadialZone.recent:
        return '';
    }
  }

  // ------------------------------------------------------------ 子环滚动

  void _onSubScroll(int delta) {
    final String? groupId = _expandedGroupId;
    if (groupId == null) {
      return;
    }
    final RadialGroup? group = RadialCatalog.groupById(groupId);
    if (group == null) {
      return;
    }
    _bumpDismiss();
    setState(() {
      _subScroll = clampSubScroll(_subScroll + delta, group.tools.length);
      _focusHit = null;
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _expandedGroupId == null) {
      return;
    }
    _onSubScroll(event.scrollDelta.dy > 0 ? 1 : -1);
  }

  // ------------------------------------------------------------ 指针模式

  void _onPointerDown(PointerDownEvent event) {
    final bool touch = event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    if (touch != _touchMode) {
      setState(() => _touchMode = touch);
    }
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    unawaited(_openConfigMenu(details.globalPosition));
  }

  // ------------------------------------------------------------ 菜单接线

  Offset _globalOf(Offset local) {
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is RenderBox) {
      return renderObject.localToGlobal(local);
    }
    return local;
  }

  Future<void> _openConfigMenu(Offset globalPosition) async {
    if (_phase == RadialPhase.hidden) {
      return;
    }
    _bumpDismiss();
    await showRadialConfigMenu(
      context,
      globalPosition: globalPosition,
      settings: _settings,
      locked: _locked,
      hasRecent: _recentIds.isNotEmpty,
      onSettings: _applySettings,
      onToggleLock: _toggleLock,
      onHide: _hide,
      onClearRecent: _clearRecent,
    );
    if (mounted) {
      _bumpDismiss();
    }
  }

  Future<void> _openMoreMenu() async {
    _bumpDismiss();
    await showRadialMoreMenu(
      context,
      globalPosition: _globalOf(_metrics.center),
      onUndo: () => _readBoard()?.undo(),
      onRedo: () => _readBoard()?.redo(),
      onAction: _handleAction,
      onHide: _hide,
    );
    if (mounted) {
      _bumpDismiss();
    }
  }

  /// 读取白板状态（宿主未提供 Provider 时返回 null，演示模式安全）。
  WbBoardState? _readBoard() {
    if (!mounted) {
      return null;
    }
    try {
      return Provider.of<WbBoardState>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// 动作处理：宿主回调优先，否则走默认提示 / 路由。
  void _handleAction(String id) {
    _bumpDismiss();
    final ValueChanged<String>? callback = widget.onAction;
    if (callback != null) {
      callback(id);
      return;
    }
    switch (id) {
      case kRadialSettingsId:
        _tryPushSettings();
      case kRadialAiAssistantId:
        _snack('AI 助手入口（由宿主界面接管）');
      default:
        _snack('「$id」');
    }
  }

  void _tryPushSettings() {
    try {
      context.push(WbRoutes.settingsPath);
    } catch (_) {
      _snack('设置');
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1200),
        content: Text(message),
      ),
    );
  }

  // ------------------------------------------------------------ 键盘

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool modifier = keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed;
    final LogicalKeyboardKey key = event.logicalKey;

    if (key == LogicalKeyboardKey.space && !modifier) {
      _toggleFromKeyboard();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _escape();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab && !modifier) {
      _cycleGroup(keyboard.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _commitFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveFocus(-1, horizontal: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveFocus(1, horizontal: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveFocus(-1, horizontal: false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveFocus(1, horizontal: false);
      return KeyEventResult.handled;
    }
    if (!modifier && _selectByChar(key.keyLabel.toUpperCase())) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Space：展开 / 收起（hidden → collapsed，locked 时不响应）。
  void _toggleFromKeyboard() {
    _bumpDismiss();
    if (_locked) {
      return;
    }
    setState(() {
      if (_phase == RadialPhase.collapsed || _phase == RadialPhase.hidden) {
        _phase = RadialPhase.expanded;
      } else {
        _phase = RadialPhase.collapsed;
        _expandedGroupId = null;
        _subScroll = 0;
      }
      _focusHit = null;
    });
  }

  /// Esc：子工具 → 收起子工具；其余 → 收起圆盘（文档 5.4 / 6.3）。
  void _escape() {
    _bumpDismiss();
    if (_locked) {
      return;
    }
    setState(() {
      if (_expandedGroupId != null) {
        _expandedGroupId = null;
        _subScroll = 0;
        _phase = RadialPhase.expanded;
      } else {
        _phase = RadialPhase.collapsed;
      }
      _dragHit = RadialHit.none;
      _focusHit = null;
    });
  }

  /// 数字 1–6 / 字母快捷键（文档 5.4）。
  bool _selectByChar(String char) {
    if (char.length != 1) {
      return false;
    }
    if (_phase == RadialPhase.hidden) {
      _restore();
      return true;
    }
    final int digit = int.tryParse(char) ?? -1;
    if (digit >= 1 && digit <= RadialCatalog.inner.length) {
      _focusNode.requestFocus();
      _activateInner(digit - 1);
      return true;
    }
    for (final RadialTool tool in RadialCatalog.inner) {
      if (tool.keyword.isNotEmpty && tool.keyword.toUpperCase() == char) {
        _focusNode.requestFocus();
        _activateTool(tool);
        return true;
      }
    }
    return false;
  }

  /// 方向键导航（文档 5.4；子环打开时 ←/→ 走槽位、↑/↓ 滚动，5.4/6.2）。
  void _moveFocus(int step, {required bool horizontal}) {
    if (_phase == RadialPhase.hidden) {
      return;
    }
    _bumpDismiss();
    setState(() {
      final String? groupId = _expandedGroupId;
      if (groupId != null) {
        final RadialGroup? group = RadialCatalog.groupById(groupId);
        if (group == null) {
          return;
        }
        final int visible = math.min(kSubVisibleSlots, group.tools.length);
        final int offset = clampSubScroll(_subScroll, group.tools.length);
        if (horizontal) {
          final int current =
              _focusHit?.zone == RadialZone.sub ? _focusHit!.slot : 0;
          final int slot = (current + step).clamp(0, visible - 1);
          _focusHit =
              RadialHit(RadialZone.sub, index: offset + slot, slot: slot);
        } else {
          _subScroll = clampSubScroll(_subScroll + step, group.tools.length);
          final int newOffset = clampSubScroll(_subScroll, group.tools.length);
          final int slot = _focusHit?.zone == RadialZone.sub
              ? _focusHit!.slot.clamp(0, visible - 1)
              : 0;
          _focusHit =
              RadialHit(RadialZone.sub, index: newOffset + slot, slot: slot);
        }
        return;
      }
      if (_phase == RadialPhase.collapsed) {
        _phase = RadialPhase.expanded;
      }
      if (horizontal) {
        final int count = RadialCatalog.groups.length;
        final int current =
            _focusHit?.zone == RadialZone.outer ? _focusHit!.index : -1;
        _focusHit = RadialHit(
          RadialZone.outer,
          index: ((current + step) % count + count) % count,
        );
      } else {
        final int count = RadialCatalog.inner.length;
        final int current =
            _focusHit?.zone == RadialZone.inner ? _focusHit!.index : -1;
        _focusHit = RadialHit(
          RadialZone.inner,
          index: ((current + step) % count + count) % count,
        );
      }
    });
  }

  /// Enter：提交当前焦点（文档 5.4）。
  void _commitFocus() {
    final RadialHit? hit = _focusHit;
    if (hit == null) {
      return;
    }
    _bumpDismiss();
    switch (hit.zone) {
      case RadialZone.inner:
        _activateInner(hit.index);
      case RadialZone.outer:
        _toggleGroup(RadialCatalog.groups[hit.index], forceOpen: true);
      case RadialZone.sub:
        _activateSub(hit.index);
      case RadialZone.none:
      case RadialZone.center:
      case RadialZone.recent:
        break;
    }
  }

  /// Tab / Shift+Tab：切换到下一个 / 上一个分组（文档 5.4）。
  void _cycleGroup(int direction) {
    _bumpDismiss();
    setState(() {
      final int count = RadialCatalog.groups.length;
      final String? currentId = _expandedGroupId;
      final int current = currentId == null
          ? (direction > 0 ? -1 : 0)
          : RadialCatalog.groupIndex(currentId);
      final int next = ((current + direction) % count + count) % count;
      _expandedGroupId = RadialCatalog.groups[next].id;
      _subScroll = 0;
      if (_phase != RadialPhase.locked) {
        _phase = RadialPhase.subExpanded;
      }
      _focusHit = const RadialHit(RadialZone.sub, index: 0, slot: 0);
    });
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final RadialMetrics metrics = _metrics;

    final Widget body = _phase == RadialPhase.hidden
        ? _buildRestoreHandle(colors, metrics)
        : _buildToolbox(colors, metrics);

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerSignal: _onPointerSignal,
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onSecondaryTapUp: _onSecondaryTapUp,
          child: AnimatedOpacity(
            opacity: _fading ? 0 : 1,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            child: IgnorePointer(ignoring: _fading, child: body),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbox(WbThemeColors colors, RadialMetrics metrics) {
    return SizedBox(
      width: metrics.frame,
      height: metrics.frame,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          RadialMenu(
            metrics: metrics,
            expanded: _ringsVisible,
            activeToolId: _activeTool,
            expandedGroupId: _expandedGroupId,
            subScroll: _subScroll,
            recentTools:
                _settings.showRecent ? _recentTools : const <RadialTool>[],
            highlight: _phase == RadialPhase.dragging ? _dragHit : null,
            focusHit: _focusHit,
            showLabels: _showLabels,
            showRecent: _settings.showRecent,
            animations: _settings.animations,
            onInnerTap: _activateTool,
            onOuterTap: _toggleGroup,
            onOuterDoubleTap: _activateGroupDefault,
            onSubTap: _activateTool,
            onSubScroll: _onSubScroll,
            onRecentTap: _activateTool,
          ),
          Positioned(
            left: metrics.center.dx - metrics.centerRadius,
            top: metrics.center.dy - metrics.centerRadius,
            child: RadialCenterButton(
              key: const ValueKey<String>('radial-center'),
              metrics: metrics,
              phase: _phase,
              activeIcon: _activeToolIcon,
              onTap: _onCenterTap,
              onLongPress: _onCenterLongPress,
              onPanStart: _onDragStart,
              onPanUpdate: _onDragUpdate,
              onPanEnd: _onDragEnd,
            ),
          ),
          if (_phase == RadialPhase.dragging && _settings.showTrail)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey<String>('radial-trail'),
                  painter: RadialTrailPainter(
                    from: metrics.center,
                    to: _dragPoint,
                    label: _trailLabel(),
                    color: colors.radialHighlight.withValues(alpha: 0.6),
                    labelColor: colors.toolbarIcon,
                    labelBackground:
                        colors.radialBackground.withValues(alpha: 0.96),
                    labelStyle: WbTypography.apply(
                      TextStyle(
                        fontSize: metrics.labelFontSize,
                        color: colors.toolbarIcon,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 隐藏态恢复把手（文档 7.2：hidden → 快捷键 / 菜单 → collapsed）。
  Widget _buildRestoreHandle(WbThemeColors colors, RadialMetrics metrics) {
    return SizedBox(
      width: metrics.frame,
      height: metrics.frame,
      child: Center(
        child: Tooltip(
          message: '显示工具盘',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey<String>('radial-restore'),
              behavior: HitTestBehavior.opaque,
              onTap: _restore,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.toolbarBackground,
                  border: Border.all(color: colors.cardBorder),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  LinearIcons.visible,
                  size: 20,
                  color: colors.toolbarIcon,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
