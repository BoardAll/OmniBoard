/// 上下文工具栏：按选中对象类型（便签 / 文本 / 形状 / 连线 / 图片 / 3D /
/// 函数 / 2D / 表格 / 思维导图 / 流程图 / 多选 / Frame…）渲染样式 / 层级 /
/// 对齐 / 删除等操作集（文档 §4 / §6–16）。
///
/// 交互要点：
/// - 条目按 [WbContextItemKind] 分派：直接命令（可选二次确认）/
///   颜色弹层 / 单选弹层 / 线宽弹层；
/// - 选色后进入"待应用表面"状态（文档 §11.2：3D 面着色，选色 → 点表面），
///   Esc / 取消按钮退出；画布点击由宿主接线（见实现报告偏差）；
/// - 溢出折叠与主工具栏共用 [computeWbToolbarVisibleCount]；
/// - 浮层模式入口 [showWbContextToolbar]：选中对象后出现，默认对象上方，
///   空间不足翻转到下方（文档 §17.1）；浮层不设全屏遮罩——空白点击穿透
///   到下层画布，「点击空白收起」由宿主在选区清空时经
///   [WbContextToolbarHandle.setVisible] 承接（§17.2）；弹层交互期间宿主
///   只隐藏不销毁（Offstage 保活），命令不因 unmount 丢失。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whiteboard_theme/theme.dart';

import 'color_picker_popover.dart';
import 'toolbar_config.dart';
import 'toolbar_item.dart';

/// 上下文工具栏（内嵌模式：并入底部工具栏区；浮层模式见 [showWbContextToolbar]）。
///
/// 用法一（并入底部工具栏）：`selfDecorated: false`，由外层容器提供底色；
/// 用法二（独立展示）：默认 `selfDecorated: true` 自绘工具栏容器外观。
class WbContextToolbar extends StatefulWidget {
  const WbContextToolbar({
    super.key,
    required this.target,
    this.onCommand,
    this.onPendingChanged,
    this.currentColor,
    this.currentLineWidth,
    this.showTypeLabel = true,
    this.selfDecorated = true,
    this.keyPrefix = 'wb-context-',
  });

  /// 上下文目标（类型 + 数量 + 元素 id；空目标不渲染）。
  final WbContextTarget target;

  /// 命令回调（统一命令层出口，[WbToolbarCommand.toolId] 为文档工具 ID）。
  final ValueChanged<WbToolbarCommand>? onCommand;

  /// 待应用样式变化回调（null 表示退出待应用状态）。
  final ValueChanged<WbPendingStyle?>? onPendingChanged;

  /// 当前颜色（颜色按钮角标 / 弹层选中态展示）。
  final Color? currentColor;

  /// 当前线宽（线宽弹层选中态展示）。
  final double? currentLineWidth;

  /// 是否显示类型标签（如"便签" / "多选 ×3"）。
  final bool showTypeLabel;

  /// 是否自绘容器外观（false 用于并入主工具栏容器）。
  final bool selfDecorated;

  /// 自动化测试 key 前缀（条目 key 为 `<prefix><item.id>`）。
  final String keyPrefix;

  @override
  State<WbContextToolbar> createState() => _WbContextToolbarState();
}

class _WbContextToolbarState extends State<WbContextToolbar> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'wb-context-toolbar');

  /// 各单选条目的最近选择（弹层选中打勾展示）。
  final Map<String, String> _lastChoice = <String, String>{};

  /// 线宽最近选择。
  double? _lastWidth;

  /// 待应用样式（文档 §11.2：选色后等待点击表面）。
  WbPendingStyle? _pending;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WbContextToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameContextTarget(oldWidget.target, widget.target)) {
      // 选区目标变化：退出"待应用表面"状态，防跨选区泄漏。
      if (_pending != null) {
        _pending = null;
        widget.onPendingChanged?.call(null);
      }
    }
  }

  /// 类型标签文案（多选追加数量）。
  String get _typeLabel {
    final String base = widget.target.type.label;
    return widget.target.count > 1 ? '$base ×${widget.target.count}' : base;
  }

  /// 标签区宽度估算（预算用，取偏大值保证不溢出）。
  static double _estimateLabelExtent(String label) {
    return 20.0 + label.runes.length * 12.0 + 6.0;
  }

  // ---- 命令与交互分派 ------------------------------------------------------

  void _emit(WbToolbarCommand command) {
    widget.onCommand?.call(command);
  }

  /// 条目分派：直接命令 / 二次确认 / 颜色 / 单选 / 线宽。
  Future<void> _handleItem(WbContextItem item) async {
    switch (item.kind) {
      case WbContextItemKind.action:
        if (item.confirm) {
          final bool ok = await _confirmItem(item);
          // 确认期间浮层可能已被宿主隐藏 / 销毁：命令照发
          //（`_emit` 不依赖 State 挂载，回调引用安全）。
          if (!ok) {
            return;
          }
        }
        _emit(buildWbContextCommand(item));
      case WbContextItemKind.color:
        final Rect anchor = wbGlobalRectOf(context);
        final Color? color = await showWbColorPicker(
          context,
          anchor: anchor,
          title: item.label,
          current: widget.currentColor,
        );
        if (!mounted || color == null) {
          return;
        }
        if (item.awaitsSurfacePaint) {
          // 文档 §11.2：选色后进入"待应用"状态（光标油漆桶 → 点击表面）。
          final WbPendingStyle style = WbPendingStyle(
            toolId: item.command,
            color: color,
            label: item.label,
          );
          setState(() => _pending = style);
          widget.onPendingChanged?.call(style);
          _focusNode.requestFocus();
          _emit(WbToolbarCommand(item.command, <String, Object?>{
            'mode': 'armed',
            'color': wbColorToHex(color),
            if (item.colorSlot.isNotEmpty) 'slot': item.colorSlot,
          }));
        } else {
          _emit(buildWbContextCommand(item, color: color));
        }
      case WbContextItemKind.choice:
        final Rect anchor = wbGlobalRectOf(context);
        final WbChoiceOption? option = await showWbChoicePopover(
          context,
          anchor: anchor,
          title: item.choiceTitle.isEmpty ? item.label : item.choiceTitle,
          options: item.choiceOptions,
          current: _lastChoice[item.id],
        );
        if (!mounted || option == null) {
          return;
        }
        setState(() => _lastChoice[item.id] = option.value);
        _emit(buildWbContextCommand(item, option: option));
      case WbContextItemKind.lineWidth:
        final Rect anchor = wbGlobalRectOf(context);
        final double? width = await showWbLineWidthPicker(
          context,
          anchor: anchor,
          current: _lastWidth ?? widget.currentLineWidth,
          title: item.label,
        );
        if (!mounted || width == null) {
          return;
        }
        setState(() => _lastWidth = width);
        _emit(buildWbContextCommand(item, width: width));
    }
  }

  /// 二次确认（文档 §3.4：删除单元素 = Confirm）。
  Future<bool> _confirmItem(WbContextItem item) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final WbThemeColors colors = dialogContext.wbColors;
        return AlertDialog(
          key: const ValueKey<String>('wb-delete-confirm'),
          backgroundColor: colors.elevated,
          title: Text('删除${widget.target.type.label}？'),
          content: Text(
            widget.target.count > 1
                ? '将删除选中的 ${widget.target.count} 个元素，可通过撤销恢复。'
                : '将删除选中的元素，可通过撤销恢复。',
          ),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('wb-delete-confirm-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey<String>('wb-delete-confirm-ok'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    return ok ?? false;
  }

  /// 退出待应用状态（Esc / 取消按钮）。
  void _cancelPending() {
    final WbPendingStyle? style = _pending;
    if (style == null) {
      return;
    }
    setState(() => _pending = null);
    widget.onPendingChanged?.call(null);
    _emit(WbToolbarCommand(style.toolId, const <String, Object?>{'mode': 'cancel'}));
  }

  /// Esc 退出待应用状态（组件局部按键处理，不注册全局快捷键）。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _pending != null) {
      _cancelPending();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- 构建 ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    if (widget.target.isEmpty) {
      return const SizedBox.shrink();
    }
    final WbContextToolbarSpec spec =
        WbContextCatalog.specFor(widget.target.type);

    final Widget content = _pending == null
        ? _buildItemsRow(context, spec)
        : WbPendingStyleBar(style: _pending!, onCancel: _cancelPending);

    final Widget body = Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: content,
    );

    if (!widget.selfDecorated) {
      return body;
    }
    return Container(
      key: ValueKey<String>('${widget.keyPrefix}bar'),
      height: WbToolbarMetrics.barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: wbToolbarSurfaceDecoration(colors),
      child: body,
    );
  }

  /// 条目行：类型标签 + 上下文条目 + 固定"更多"入口。
  Widget _buildItemsRow(BuildContext context, WbContextToolbarSpec spec) {
    final List<WbToolbarItemEntry> entries = <WbToolbarItemEntry>[
      for (final WbContextItem item in spec.items) _entryFor(item),
    ];
    final List<Widget> leading = widget.showTypeLabel
        ? <Widget>[_buildTypeLabel(context)]
        : const <Widget>[];

    return WbToolbarRow(
      items: entries,
      leading: leading,
      leadingExtent:
          widget.showTypeLabel ? _estimateLabelExtent(_typeLabel) : 0,
      fixedExtent:
          WbToolbarMetrics.separatorExtent + WbToolbarMetrics.itemExtent,
      fixedBuilder: (
        BuildContext context,
        List<WbToolbarItemEntry> hidden,
      ) {
        return <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: WbToolbarMoreButton(
              buttonKey: ValueKey<String>('${widget.keyPrefix}more'),
              active: hidden.isNotEmpty,
              items: <WbToolbarMoreMenuEntry>[
                for (final WbToolbarItemEntry entry in hidden)
                  entry.toMenuEntry(),
                for (int i = 0; i < spec.moreItems.length; i++)
                  WbToolbarMoreMenuEntry(
                    value: spec.moreItems[i],
                    label: spec.moreItems[i].label,
                    icon: spec.moreItems[i].icon,
                    keySuffix: spec.moreItems[i].id,
                    dividerBefore: hidden.isNotEmpty && i == 0,
                  ),
              ],
              onSelected: _handleMoreSelected,
            ),
          ),
        ];
      },
    );
  }

  /// "更多"菜单选中分发（折叠条目 / 配置附加条目）。
  void _handleMoreSelected(Object value) {
    if (value is WbToolbarItemEntry) {
      value.onTap();
      return;
    }
    if (value is WbContextItem) {
      unawaited(_handleItem(value));
    }
  }

  /// 单条目 → 渲染数据。
  WbToolbarItemEntry _entryFor(WbContextItem item) {
    final bool hasBadge =
        item.kind == WbContextItemKind.color && widget.currentColor != null;
    return WbToolbarItemEntry(
      id: item.id,
      label: item.label,
      icon: item.icon,
      tooltip: item.label,
      keyPrefix: widget.keyPrefix,
      badgeColor: hasBadge ? widget.currentColor : null,
      onTap: () => unawaited(_handleItem(item)),
    );
  }

  /// 类型标签（如"便签" / "多选 ×3"）。
  Widget _buildTypeLabel(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        key: ValueKey<String>('${widget.keyPrefix}type-label'),
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.toolbarActive.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          _typeLabel,
          style: TextStyle(
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w600,
            color: colors.toolbarActive,
          ),
        ),
      ),
    );
  }
}

// ---- 浮层入口 --------------------------------------------------------------

/// 上下文目标值比较（`WbContextTarget` 无值相等语义；避开身份比较误判）。
bool _sameContextTarget(WbContextTarget a, WbContextTarget b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.type != b.type || a.count != b.count) {
    return false;
  }
  if (a.elementIds.length != b.elementIds.length) {
    return false;
  }
  for (int i = 0; i < a.elementIds.length; i++) {
    if (a.elementIds[i] != b.elementIds[i]) {
      return false;
    }
  }
  return true;
}

/// 上下文工具栏浮层句柄。
///
/// 长生命周期：宿主创建后经 [update] / [setVisible] 增量驱动，不销毁重建
/// （弹层交互期间只隐藏不卸载——命令不因 unmount 丢失）；[close] 为终极
/// 销毁出口。
class WbContextToolbarHandle {
  WbContextToolbarHandle._();

  void Function()? _close;

  void Function({
    required WbContextTarget target,
    Rect? anchor,
    Color? currentColor,
    double? currentLineWidth,
  })? _update;

  void Function(bool visible)? _setVisible;
  bool _closed = false;

  /// 当前待应用样式（宿主可查询；进入 / 退出"选色再点表面"时更新）。
  WbPendingStyle? pending;

  /// 是否已关闭。
  bool get isClosed => _closed;

  /// 更新浮层内容与锚点（不重建 entry；隐藏期间也生效，下次显示即用新值）。
  void update({
    required WbContextTarget target,
    Rect? anchor,
    Color? currentColor,
    double? currentLineWidth,
  }) {
    if (_closed) {
      return;
    }
    _update?.call(
      target: target,
      anchor: anchor,
      currentColor: currentColor,
      currentLineWidth: currentLineWidth,
    );
  }

  /// 设置浮层显隐（不可见仅 [Offstage] 隐藏，组件 State 保持存活）。
  void setVisible(bool visible) {
    if (_closed) {
      return;
    }
    _setVisible?.call(visible);
  }

  /// 关闭浮层（终极销毁；常规收起请用 [setVisible]）。
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _close?.call();
  }
}

/// 显示上下文工具栏浮层（文档 §17.1：选中对象后出现，默认对象上方，
/// 空间不足时出现在下方）。
///
/// - [target]：选中目标；空目标不显示（返回已关闭句柄）；
/// - [anchor]：选中对象全局矩形（null → 底部工具栏区居中，对应
///   "并入工具栏区"布局）；
/// - [onCommand]：命令回调；
/// - [preferBelow]：true 时优先对象下方（空间不足再翻转上方）；
/// - [currentColor] / [currentLineWidth]：单选元素当前样式（选色 / 线宽
///   弹层的选中态展示；null = 不展示）。
///
/// 返回 [WbContextToolbarHandle]：宿主持有并增量驱动（[WbContextToolbarHandle.update]
/// / [WbContextToolbarHandle.setVisible]）。浮层不设全屏遮罩——空白区域
/// 点击穿透到下层画布，「点击空白收起」由宿主在选区清空时隐藏承接
/// （§17.2）；隐藏走 [Offstage] 保活（待应用样式 / 弹层选择态不丢失），
/// 弹层交互期间的宿主同步不销毁本浮层（命令不因 unmount 丢失）。
///
/// 实现说明：浮层内容用 [Material] 包裹（Overlay 不继承 Scaffold 的
/// Material 祖先，InkWell / 文本样式需要）。
WbContextToolbarHandle showWbContextToolbar(
  BuildContext context, {
  required WbContextTarget target,
  Rect? anchor,
  ValueChanged<WbToolbarCommand>? onCommand,
  bool preferBelow = false,
  Color? currentColor,
  double? currentLineWidth,
}) {
  final WbContextToolbarHandle handle = WbContextToolbarHandle._();
  if (target.isEmpty) {
    handle._closed = true;
    return handle;
  }

  final OverlayState overlay = Overlay.of(context);
  late final OverlayEntry entry;
  bool removed = false;

  final ValueNotifier<_WbContextToolbarOverlayState> state =
      ValueNotifier<_WbContextToolbarOverlayState>(
    _WbContextToolbarOverlayState(
      target: target,
      anchor: anchor,
      currentColor: currentColor,
      currentLineWidth: currentLineWidth,
    ),
  );

  void remove() {
    if (removed) {
      return;
    }
    removed = true;
    handle._closed = true;
    if (entry.mounted) {
      entry.remove();
    }
    // state 不显式 dispose：entry 卸载与监听器解绑存在同帧竞态，
    // 随句柄 / entry 引用一并回收。
  }

  handle._close = remove;
  handle._update = ({
    required WbContextTarget target,
    Rect? anchor,
    Color? currentColor,
    double? currentLineWidth,
  }) {
    if (removed) {
      return;
    }
    state.value = _WbContextToolbarOverlayState(
      target: target,
      anchor: anchor,
      currentColor: currentColor,
      currentLineWidth: currentLineWidth,
      visible: state.value.visible,
    );
  };
  handle._setVisible = (bool visible) {
    if (removed || state.value.visible == visible) {
      return;
    }
    state.value = state.value.copyWith(visible: visible);
  };

  entry = OverlayEntry(
    builder: (BuildContext overlayContext) {
      return ValueListenableBuilder<_WbContextToolbarOverlayState>(
        valueListenable: state,
        builder: (
          BuildContext context,
          _WbContextToolbarOverlayState current,
          Widget? child,
        ) {
          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: Offstage(
                  offstage: !current.visible,
                  child: CustomSingleChildLayout(
                    delegate: _WbContextToolbarLayoutDelegate(
                      anchor: current.anchor,
                      preferBelow: preferBelow,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: WbContextToolbar(
                        key: const ValueKey<String>('wb-context-toolbar-popup'),
                        target: current.target,
                        currentColor: current.currentColor,
                        currentLineWidth: current.currentLineWidth,
                        onCommand: onCommand,
                        onPendingChanged: (WbPendingStyle? style) =>
                            handle.pending = style,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
  overlay.insert(entry);
  return handle;
}

/// 浮层内部状态（[ValueListenableBuilder] 驱动；增量更新不重建 entry）。
class _WbContextToolbarOverlayState {
  const _WbContextToolbarOverlayState({
    required this.target,
    this.anchor,
    this.currentColor,
    this.currentLineWidth,
    this.visible = true,
  });

  /// 选中目标。
  final WbContextTarget target;

  /// 锚点（null → 底部工具栏区居中）。
  final Rect? anchor;

  /// 单选当前颜色。
  final Color? currentColor;

  /// 单选当前线宽。
  final double? currentLineWidth;

  /// 是否可见（false → Offstage 保活隐藏）。
  final bool visible;

  _WbContextToolbarOverlayState copyWith({bool? visible}) {
    return _WbContextToolbarOverlayState(
      target: target,
      anchor: anchor,
      currentColor: currentColor,
      currentLineWidth: currentLineWidth,
      visible: visible ?? this.visible,
    );
  }
}

/// 上下文浮层定位委托：优先对象上方，空间不足翻转到下方（文档 §17.1）；
/// [anchor] 为 null 时按底部工具栏区居中。
class _WbContextToolbarLayoutDelegate extends SingleChildLayoutDelegate {
  const _WbContextToolbarLayoutDelegate({
    this.anchor,
    this.preferBelow = false,
  });

  /// 对象与工具栏间距。
  static const double _gap = 12;

  /// 屏幕安全边距。
  static const double _margin = 8;

  /// 底部工具栏区留白。
  static const double _bottomInset = 16;

  /// 对象全局矩形（null → 底部居中）。
  final Rect? anchor;

  /// 优先置于对象下方。
  final bool preferBelow;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: math.max(160.0, constraints.maxWidth - _margin * 2),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double maxLeft =
        math.max(_margin, size.width - childSize.width - _margin);
    final double maxTop =
        math.max(_margin, size.height - childSize.height - _margin);
    final Rect? rect = anchor;
    if (rect == null) {
      final double left = math.min(
        math.max((size.width - childSize.width) / 2, _margin),
        maxLeft,
      );
      final double top = math.min(
        math.max(size.height - childSize.height - _bottomInset, _margin),
        maxTop,
      );
      return Offset(left, top);
    }
    final double left = math.min(
      math.max(rect.center.dx - childSize.width / 2, _margin),
      maxLeft,
    );
    final double above = rect.top - childSize.height - _gap;
    final double below = rect.bottom + _gap;
    final bool canAbove = above >= _margin;
    final bool canBelow = below <= size.height - childSize.height - _margin;
    final bool placeAbove =
        preferBelow ? (!canBelow && canAbove) : (canAbove || !canBelow);
    final double top =
        math.min(math.max(placeAbove ? above : below, _margin), maxTop);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_WbContextToolbarLayoutDelegate oldDelegate) {
    return anchor != oldDelegate.anchor || preferBelow != oldDelegate.preferBelow;
  }
}
