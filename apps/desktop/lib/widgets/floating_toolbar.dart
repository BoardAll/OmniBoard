/// 底部浮动主工具栏：声明式配置（[WbMainToolbar]）+ 响应式溢出折叠 +
/// 撤销 / 重做 / 更多 + 快捷键角标 + 上下文工具栏切换。
///
/// 行为对齐《可扩展工具栏设计 v1.0》：
/// - §3.1：9 类绘图工具（选择 / 抓手 / 画笔 / 荧光笔 / 橡皮擦 / 便签 /
///   文本 / 形状 / 图片），快捷键角标仅作提示、不注册全局快捷键；
/// - §3.4：撤销 / 重做接线到 [WbBoardState]；
/// - §4：有选中对象时切换为上下文工具栏（[WbContextToolbar]），无选中
///   恢复默认工具集（"工具栏区切换"布局，浮层布局见 [showWbContextToolbar]）；
/// - §5：更多 → 设置、快捷键；
/// - §17.2：溢出条目折叠入"更多"菜单，点击空白处收起（PopupMenu 默认）；
/// - §18：高度 40 / 按钮 32 / 图标 20 / 圆角 / 出现 120ms / 消失 100ms。
///
/// 画布联动偏差：画布控制器（`WbCanvasController`）由 `CanvasView` 内部
/// 持有、对工具栏不可达；本组件维护自身选择状态并输出 [onToolChanged] /
/// [onCommand] 回调，由宿主接线到画布（见实现报告偏差清单）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../state/board_state.dart';
import '../state/selection_state.dart';
import 'canvas/canvas_capture.dart';
import 'canvas/stroke_style.dart';
import 'canvas/screen_sampler.dart';
import 'toolbar/color_picker_popover.dart';
import 'toolbar/color_wheel.dart';
import 'toolbar/context_toolbar.dart';
import 'toolbar/toolbar_config.dart';
import 'toolbar/toolbar_item.dart';

/// 底部浮动工具栏。
///
/// 全部参数可选、带默认值：`const FloatingToolbar()` 保持既有调用方式可用。
class FloatingToolbar extends StatefulWidget {
  const FloatingToolbar({
    super.key,
    this.initialTool = WbToolbarToolIds.select,
    this.activeTool,
    this.onToolChanged,
    this.onCommand,
    this.onUndo,
    this.onRedo,
    this.contextTarget,
    this.contextTypeResolver,
    this.showContextToolbar = true,
    this.onPendingStyleChanged,
    this.penColor,
    this.onPenColorChanged,
    this.penColorLabel = '画笔颜色',
    this.penStyle,
    this.onPenStyleChanged,
  });

  /// 初始高亮工具（未受控模式下使用）。
  final String initialTool;

  /// 受控高亮工具（非 null 时组件不再自管选择态）。
  final String? activeTool;

  /// 工具切换回调（宿主接线到画布；当前画布控制器不可达，见文件头偏差）。
  final ValueChanged<String>? onToolChanged;

  /// 统一命令回调（"更多 → 设置 / 快捷键"与上下文命令出口）。
  final ValueChanged<WbToolbarCommand>? onCommand;

  /// 撤销回调（null 时回落 [WbBoardState.undo]，兼容旧调用）。
  final VoidCallback? onUndo;

  /// 重做回调（null 时回落 [WbBoardState.redo]，兼容旧调用）。
  final VoidCallback? onRedo;

  /// 上下文目标覆盖：非 null 时直接使用（不读取选区 Provider；
  /// 测试与嵌入场景用）。null 时从 [WbSelectionState] 解析。
  final WbContextTarget? contextTarget;

  /// 单元素类型解析器（id → 上下文类型；null → 单选显示通用集）。
  final WbContextTypeResolver? contextTypeResolver;

  /// 是否启用"有选中 → 上下文工具栏"切换。
  final bool showContextToolbar;

  /// 上下文工具栏进入 / 退出"选色再点表面"待应用状态的回调。
  final ValueChanged<WbPendingStyle?>? onPendingStyleChanged;

  /// 当前画笔颜色。与 [onPenColorChanged] 一起提供时，工具栏尾部显示取色按钮。
  final Color? penColor;

  /// 画笔颜色变更。为 null 时不显示取色按钮（测试与未接线场景）。
  final ValueChanged<Color>? onPenColorChanged;

  /// 取色按钮提示与对话框标题（如「荧光笔颜色」）。
  final String penColorLabel;

  /// 当前画笔笔触。与 [onPenStyleChanged] 一起提供、且当前工具为画笔时显示笔触条。
  final WbPenStyle? penStyle;

  /// 画笔笔触变更。
  final ValueChanged<WbPenStyle>? onPenStyleChanged;

  @override
  State<FloatingToolbar> createState() => _FloatingToolbarState();
}

class _FloatingToolbarState extends State<FloatingToolbar> {
  late String _active = widget.initialTool;

  /// 当前高亮工具（受控优先）。
  String get _resolvedActive => widget.activeTool ?? _active;

  /// 选中工具：受控模式下只回调；否则先更新本地高亮。
  void _selectTool(String id) {
    if (widget.activeTool == null && _active != id) {
      setState(() => _active = id);
    }
    widget.onToolChanged?.call(id);
  }

  /// 组首标记（组间渲染额外间距）。
  bool _startsGroup(String id) {
    for (final WbToolbarGroup group in WbMainToolbar.groups) {
      if (group.items.isNotEmpty && group.items.first.id == id) {
        return true;
      }
    }
    return false;
  }

  // ---- Provider 容错读取（演示模式 / 无 Provider 不崩溃）----------------------

  WbSelectionState? _maybeSelection(BuildContext context) {
    try {
      return context.watch<WbSelectionState>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  WbBoardState? _maybeBoard(BuildContext context) {
    try {
      return context.watch<WbBoardState>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// 解析上下文目标（显式覆盖 → 选区 Provider → 无选中）。
  WbContextTarget _resolveTarget(BuildContext context) {
    final WbContextTarget? override = widget.contextTarget;
    if (override != null) {
      return override;
    }
    final WbSelectionState? selection = _maybeSelection(context);
    if (selection == null || selection.isEmpty) {
      return const WbContextTarget(type: WbContextTargetType.none, count: 0);
    }
    return WbContextTarget.fromSelection(
      selection.ids,
      resolver: widget.contextTypeResolver,
    );
  }

  // ---- 构建 ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbContextTarget target = _resolveTarget(context);
    final bool contextMode = widget.showContextToolbar &&
        target.type != WbContextTargetType.none &&
        !target.isEmpty;

    final Widget content = contextMode
        ? WbContextToolbar(
            key: const ValueKey<String>('wb-toolbar-context-content'),
            target: target,
            selfDecorated: false,
            onCommand: widget.onCommand,
            onPendingChanged: widget.onPendingStyleChanged,
          )
        : _buildMainContent(context);

    final bool showStyles = !contextMode &&
        _resolvedActive == WbToolbarToolIds.pen &&
        widget.penStyle != null &&
        widget.onPenStyleChanged != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showStyles) ...<Widget>[
          _PenStyleBar(
            style: widget.penStyle!,
            onChanged: widget.onPenStyleChanged!,
          ),
          const SizedBox(height: 8),
        ],
        _toolbarShell(colors, content, contextMode),
      ],
    );
  }

  Widget _toolbarShell(WbThemeColors colors, Widget content, bool contextMode) {
    return Container(
      key: const ValueKey<String>('wb-floating-toolbar'),
      height: WbToolbarMetrics.barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: wbToolbarSurfaceDecoration(colors),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 120),
        reverseDuration: const Duration(milliseconds: 100),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(
          key: ValueKey<String>(contextMode ? 'wb-context' : 'wb-main'),
          child: content,
        ),
      ),
    );
  }

  /// 主工具行：9 类工具 + 固定尾部（撤销 / 重做 / 更多）。
  Widget _buildMainContent(BuildContext context) {
    final WbBoardState? board = _maybeBoard(context);
    final String active = _resolvedActive;

    final List<WbToolbarItemEntry> entries = <WbToolbarItemEntry>[
      for (final WbToolbarItem item in WbMainToolbar.tools)
        WbToolbarItemEntry(
          id: item.id,
          label: item.label,
          icon: item.icon,
          shortcut: item.shortcut,
          active: item.id == active,
          startsGroup: _startsGroup(item.id),
          onTap: () => _selectTool(item.id),
        ),
    ];

    final bool showPenColor = widget.onPenColorChanged != null;
    return WbToolbarRow(
      items: entries,
      // 容器已含 8+8 水平内边距（LayoutBuilder 约束已扣除），预算传 0。
      padding: 0,
      fixedExtent: WbToolbarMetrics.separatorExtent +
          3 * WbToolbarMetrics.itemExtent +
          (showPenColor ? WbToolbarMetrics.itemExtent : 0),
      fixedBuilder: (
        BuildContext context,
        List<WbToolbarItemEntry> hidden,
      ) {
        return <Widget>[
          if (showPenColor)
            _PenColorButton(
              color: widget.penColor ?? const Color(0xFF1F2933),
              label: widget.penColorLabel,
              onPick: widget.onPenColorChanged!,
            ),
          _fixedButton(
            key: const ValueKey<String>('wb-toolbar-edit.undo'),
            icon: LinearIcons.undo,
            tooltip: '撤销',
            enabled: widget.onUndo != null || board != null,
            onTap: () {
              final VoidCallback? undo = widget.onUndo;
              if (undo != null) {
                undo();
              } else {
                board?.undo();
              }
            },
          ),
          _fixedButton(
            key: const ValueKey<String>('wb-toolbar-edit.redo'),
            icon: LinearIcons.redo,
            tooltip: '重做',
            enabled: widget.onRedo != null || board != null,
            onTap: () {
              final VoidCallback? redo = widget.onRedo;
              if (redo != null) {
                redo();
              } else {
                board?.redo();
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: WbToolbarMoreButton(
              buttonKey: const ValueKey<String>('wb-toolbar-more'),
              active: hidden.isNotEmpty,
              items: <WbToolbarMoreMenuEntry>[
                for (final WbToolbarItemEntry entry in hidden)
                  entry.toMenuEntry(),
                WbToolbarMoreMenuEntry(
                  value: WbToolbarToolIds.settings,
                  label: '设置',
                  icon: LinearIcons.settings,
                  keySuffix: WbToolbarToolIds.settings,
                  dividerBefore: hidden.isNotEmpty,
                ),
                const WbToolbarMoreMenuEntry(
                  value: WbToolbarToolIds.shortcuts,
                  label: '快捷键',
                  icon: LinearIcons.grid,
                  keySuffix: WbToolbarToolIds.shortcuts,
                ),
              ],
              onSelected: _handleMoreSelected,
            ),
          ),
        ];
      },
    );
  }

  /// 固定尾部按钮（撤销 / 重做）。
  Widget _fixedButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: WbToolbarIconButton(
        key: key,
        icon: icon,
        tooltip: tooltip,
        enabled: enabled,
        onTap: onTap,
      ),
    );
  }

  /// "更多"菜单分发：折叠条目 → 选择工具；动作 id → 统一命令。
  void _handleMoreSelected(Object value) {
    if (value is WbToolbarItemEntry) {
      value.onTap();
      return;
    }
    if (value is String) {
      final String id = value;
      if (WbMainToolbar.toolById(id) != null) {
        _selectTool(id);
        return;
      }
      widget.onCommand?.call(WbToolbarCommand(id));
    }
  }
}

/// 画笔笔触切换条：画笔 / 铅笔 / 粉笔 / 圆珠笔 / 刷子。
class _PenStyleBar extends StatelessWidget {
  const _PenStyleBar({required this.style, required this.onChanged});

  final WbPenStyle style;
  final ValueChanged<WbPenStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      key: const ValueKey<String>('wb-pen-style-bar'),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: wbToolbarSurfaceDecoration(colors),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final WbPenStyle item in WbPenStyle.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Tooltip(
                message: item.label,
                child: InkWell(
                  key: ValueKey<String>('wb-pen-style-${item.id}'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onChanged(item),
                  child: Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: item == style
                          ? colors.primary.withValues(alpha: 0.14)
                          : const Color(0x00000000),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item.label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: item == style
                                ? colors.primary
                                : colors.toolbarIcon,
                            fontWeight: item == style ? FontWeight.w600 : null,
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
}

/// 底部工具栏上的画笔色点：点击打开「预设 + Miuix 精细调色」融合对话框。
class _PenColorButton extends StatelessWidget {
  const _PenColorButton({
    required this.color,
    required this.label,
    required this.onPick,
  });

  final Color color;
  final String label;
  final ValueChanged<Color> onPick;

  Future<void> _open(BuildContext context) async {
    Color current = color;
    while (context.mounted) {
      final _PenColorResult? result = await showDialog<_PenColorResult>(
        context: context,
        barrierColor: const Color(0x00000000),
        builder: (BuildContext context) =>
            _PenColorDialog(initial: current, title: label),
      );
      if (!context.mounted || result == null) {
        return;
      }
      if (result.pickFromCanvas) {
        final Color? picked = await _pickFromCanvas(context);
        if (!context.mounted) {
          return;
        }
        if (picked != null) {
          current = picked;
        }
        continue;
      }
      onPick(result.color);
      return;
    }
  }

  /// 收起对话框后全屏取样：放大镜跟随光标，点击屏幕任意位置取色；Esc 取消。
  Future<Color?> _pickFromCanvas(BuildContext context) {
    final OverlayState overlay = Overlay.of(context, rootOverlay: true);
    final Completer<Color?> completer = Completer<Color?>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (BuildContext context) {
        return _CanvasEyedropOverlay(
          onPick: (Color color) {
            if (completer.isCompleted) {
              return;
            }
            entry.remove();
            completer.complete(color);
          },
          onCancel: () {
            if (completer.isCompleted) {
              return;
            }
            entry.remove();
            completer.complete(null);
          },
        );
      },
    );
    overlay.insert(entry);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: label,
        child: InkWell(
          key: const ValueKey<String>('wb-toolbar-pen-color'),
          customBorder: const CircleBorder(),
          onTap: () => _open(context),
          child: ClipOval(
            child: CustomPaint(
              painter: const _CheckerPainter(cell: 4),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x33000000)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 画笔颜色对话框的关闭结果。
class _PenColorResult {
  const _PenColorResult.confirm(this.color) : pickFromCanvas = false;

  const _PenColorResult.pick()
      : color = const Color(0x00000000),
        pickFromCanvas = true;

  final Color color;
  final bool pickFromCanvas;
}

/// 当前颜色：可输入的 RGB（0–255）与 HSV（H 0–360°，S/V 0–100%），以及取色器。
class _PenColorValueBox extends StatefulWidget {
  const _PenColorValueBox({
    required this.color,
    required this.onChanged,
    required this.onEyedrop,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final VoidCallback onEyedrop;

  @override
  State<_PenColorValueBox> createState() => _PenColorValueBoxState();
}

class _PenColorValueBoxState extends State<_PenColorValueBox> {
  late final TextEditingController _red = TextEditingController();
  late final TextEditingController _green = TextEditingController();
  late final TextEditingController _blue = TextEditingController();
  late final TextEditingController _hue = TextEditingController();
  late final TextEditingController _saturation = TextEditingController();
  late final TextEditingController _value = TextEditingController();
  late final TextEditingController _hex = TextEditingController();
  late final FocusNode _redFocus = FocusNode();
  late final FocusNode _greenFocus = FocusNode();
  late final FocusNode _blueFocus = FocusNode();
  late final FocusNode _hueFocus = FocusNode();
  late final FocusNode _saturationFocus = FocusNode();
  late final FocusNode _valueFocus = FocusNode();
  late final FocusNode _hexFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _sync(widget.color, force: true);
  }

  @override
  void didUpdateWidget(_PenColorValueBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.color.toARGB32() != oldWidget.color.toARGB32()) {
      _sync(widget.color, force: false);
    }
  }

  @override
  void dispose() {
    _red.dispose();
    _green.dispose();
    _blue.dispose();
    _hue.dispose();
    _saturation.dispose();
    _value.dispose();
    _hex.dispose();
    _redFocus.dispose();
    _greenFocus.dispose();
    _blueFocus.dispose();
    _hueFocus.dispose();
    _saturationFocus.dispose();
    _valueFocus.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  void _sync(Color color, {required bool force}) {
    final int argb = color.toARGB32();
    final HSVColor hsv = HSVColor.fromColor(color);
    _set(_red, _redFocus, (argb >> 16) & 0xFF, force);
    _set(_green, _greenFocus, (argb >> 8) & 0xFF, force);
    _set(_blue, _blueFocus, argb & 0xFF, force);
    _set(_hue, _hueFocus, hsv.hue.round().clamp(0, 360), force);
    _set(_saturation, _saturationFocus, (hsv.saturation * 100).round(), force);
    _set(_value, _valueFocus, (hsv.value * 100).round(), force);
    final String hex = _hexText(color);
    if ((force || !_hexFocus.hasFocus) && _hex.text != hex) {
      _hex.text = hex;
    }
  }

  String _hexText(Color color) {
    final String rgb = (color.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    return '#$rgb';
  }

  int _alphaByte() => (widget.color.a * 255).round().clamp(0, 255);

  void _set(TextEditingController controller, FocusNode focus, int value,
      bool force) {
    if (!force && focus.hasFocus) {
      return;
    }
    final String text = '$value';
    if (controller.text != text) {
      controller.text = text;
    }
  }

  void _commitRgb() {
    final int? red = _parse(_red.text, 255);
    final int? green = _parse(_green.text, 255);
    final int? blue = _parse(_blue.text, 255);
    if (red == null || green == null || blue == null) {
      return;
    }
    widget.onChanged(Color.fromARGB(_alphaByte(), red, green, blue));
  }

  void _commitHsv() {
    final int? hue = _parse(_hue.text, 360);
    final int? saturation = _parse(_saturation.text, 100);
    final int? value = _parse(_value.text, 100);
    if (hue == null || saturation == null || value == null) {
      return;
    }
    widget.onChanged(
      HSVColor.fromAHSV(
        widget.color.a,
        hue.toDouble(),
        saturation / 100,
        value / 100,
      ).toColor(),
    );
  }

  void _commitHex() {
    String raw = _hex.text.trim();
    if (raw.startsWith('#')) {
      raw = raw.substring(1);
    }
    if (raw.length == 3) {
      raw = '${raw[0]}${raw[0]}${raw[1]}${raw[1]}${raw[2]}${raw[2]}';
    }
    if (raw.length != 6) {
      return;
    }
    final int? parsed = int.tryParse(raw, radix: 16);
    if (parsed == null) {
      return;
    }
    widget.onChanged(
      Color.fromARGB(
        _alphaByte(),
        (parsed >> 16) & 0xFF,
        (parsed >> 8) & 0xFF,
        parsed & 0xFF,
      ),
    );
  }

  int? _parse(String raw, int max) {
    final int? value = int.tryParse(raw.trim());
    if (value == null) {
      return null;
    }
    return value.clamp(0, max);
  }

  @override
  Widget build(BuildContext context) {
    final MiuixThemeData theme = MiuixTheme.of(context);
    final Color muted = theme.colors.onSurfaceVariantSummary;
    final Color fieldFill = theme.colors.surface;
    return Container(
      key: const ValueKey<String>('wb-pen-color-values'),
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: theme.colors.surfaceContainer,
        shape: const MiuixSquircleBorder(cornerRadius: 16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                clipBehavior: Clip.antiAlias,
                decoration: ShapeDecoration(
                  shape: const MiuixSquircleBorder(cornerRadius: 14),
                  shadows: <BoxShadow>[
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: CustomPaint(
                  painter: const _CheckerPainter(cell: 7),
                  child: ColoredBox(color: widget.color),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _labeledField(
                  theme: theme,
                  muted: muted,
                  fill: fieldFill,
                  label: 'HEX',
                  child: TextField(
                    key: const ValueKey<String>('wb-pen-hex'),
                    controller: _hex,
                    focusNode: _hexFocus,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')),
                      LengthLimitingTextInputFormatter(7),
                    ],
                    style: _valueStyle(theme),
                    decoration:
                        _fieldDecoration(fill: fieldFill, hint: '#RRGGBB'),
                    onChanged: (_) => _commitHex(),
                    onSubmitted: (_) => _commitHex(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Tooltip(
                  message: '全屏取色',
                  child: MiuixIconButton(
                    key: const ValueKey<String>('wb-pen-eyedropper'),
                    onPressed: widget.onEyedrop,
                    minWidth: 36,
                    minHeight: 36,
                    cornerRadius: 12,
                    backgroundColor: fieldFill,
                    child: const MiuixIcon(icon: Icons.colorize, size: 18),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _channelCell(theme, muted, fieldFill, 'R', _red, _redFocus,
                  'wb-pen-rgb-r', _commitRgb),
              const SizedBox(width: 8),
              _channelCell(theme, muted, fieldFill, 'G', _green, _greenFocus,
                  'wb-pen-rgb-g', _commitRgb),
              const SizedBox(width: 8),
              _channelCell(theme, muted, fieldFill, 'B', _blue, _blueFocus,
                  'wb-pen-rgb-b', _commitRgb),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              _channelCell(theme, muted, fieldFill, 'H', _hue, _hueFocus,
                  'wb-pen-hsv-h', _commitHsv),
              const SizedBox(width: 8),
              _channelCell(theme, muted, fieldFill, 'S', _saturation,
                  _saturationFocus, 'wb-pen-hsv-s', _commitHsv),
              const SizedBox(width: 8),
              _channelCell(theme, muted, fieldFill, 'V', _value, _valueFocus,
                  'wb-pen-hsv-v', _commitHsv),
            ],
          ),
        ],
      ),
    );
  }

  TextStyle _valueStyle(MiuixThemeData theme) {
    return theme.textStyles.footnote1.copyWith(
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      height: 1.1,
    );
  }

  InputDecoration _fieldDecoration({required Color fill, String? hint}) {
    return InputDecoration(
      isDense: true,
      filled: true,
      hintText: hint,
      fillColor: fill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _labeledField({
    required MiuixThemeData theme,
    required Color muted,
    required Color fill,
    required String label,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 4),
          child: MiuixText(
            label,
            style: theme.textStyles.footnote2.copyWith(
              color: muted,
              letterSpacing: 0.4,
            ),
          ),
        ),
        SizedBox(height: 32, child: child),
      ],
    );
  }

  Widget _channelCell(
    MiuixThemeData theme,
    Color muted,
    Color fill,
    String label,
    TextEditingController controller,
    FocusNode focus,
    String keyName,
    VoidCallback onCommit,
  ) {
    return Expanded(
      child: _labeledField(
        theme: theme,
        muted: muted,
        fill: fill,
        label: label,
        child: TextField(
          key: ValueKey<String>(keyName),
          controller: controller,
          focusNode: focus,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(3),
          ],
          textAlign: TextAlign.center,
          style: _valueStyle(theme),
          decoration: _fieldDecoration(fill: fill),
          onChanged: (_) => onCommit(),
          onSubmitted: (_) => onCommit(),
        ),
      ),
    );
  }
}

/// 全屏取色层：放大镜跟随光标，点击屏幕任意位置取样。
class _CanvasEyedropOverlay extends StatefulWidget {
  const _CanvasEyedropOverlay({required this.onPick, required this.onCancel});

  final ValueChanged<Color> onPick;
  final VoidCallback onCancel;

  @override
  State<_CanvasEyedropOverlay> createState() => _CanvasEyedropOverlayState();
}

class _CanvasEyedropOverlayState extends State<_CanvasEyedropOverlay> {
  static const int _radius = 5;

  WbScreenSampler? _sampler;
  WbCanvasSnapshot? _snapshot;
  Timer? _timer;
  Color? _color;
  List<Color>? _cells;
  Offset? _local;
  var _inside = false;
  var _px = -1;
  var _py = -1;
  var _sawLeftUp = false;
  var _done = false;

  @override
  void initState() {
    super.initState();
    _sampler = WbScreenSampler.tryOpen();
    if (_sampler == null) {
      WbCanvasCapture.capture().then((WbCanvasSnapshot? value) {
        if (mounted) {
          setState(() => _snapshot = value);
        }
      });
    }
    _timer = Timer.periodic(const Duration(milliseconds: 32), _tick);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sampler?.dispose();
    super.dispose();
  }

  void _tick(Timer timer) {
    if (!mounted || _done) {
      return;
    }
    final WbScreenSampler? sampler = _sampler;
    if (sampler == null) {
      return;
    }
    if (sampler.escapeDown) {
      _finishCancel();
      return;
    }
    final ({int x, int y})? cursor = sampler.cursor();
    if (cursor == null) {
      return;
    }
    if (!sampler.leftDown) {
      _sawLeftUp = true;
    } else if (_sawLeftUp) {
      _pickScreen(cursor.x, cursor.y);
      return;
    }
    if (cursor.x == _px && cursor.y == _py) {
      return;
    }
    _px = cursor.x;
    _py = cursor.y;
    final List<Color>? cells =
        sampler.patch(cursor.x, cursor.y, radius: _radius);
    if (cells == null) {
      return;
    }
    setState(() {
      _cells = List<Color>.of(cells);
      _color = cells[_radius * 11 + _radius];
    });
  }

  void _pickScreen(int x, int y) {
    if (_done) {
      return;
    }
    final Color? color = _sampler?.colorAt(x, y);
    if (color == null) {
      return;
    }
    _done = true;
    widget.onPick(color);
  }

  void _finishCancel() {
    if (_done) {
      return;
    }
    _done = true;
    widget.onCancel();
  }

  void _trackCanvas(Offset global) {
    final WbCanvasSnapshot? snapshot = _snapshot;
    setState(() {
      _local = global;
      _inside = true;
      _color = snapshot?.colorAt(global);
      _cells = snapshot?.patch(global, radius: _radius);
    });
  }

  @override
  Widget build(BuildContext context) {
    final MiuixThemeData theme =
        MiuixThemeData.of(Theme.of(context).brightness);
    final Size screen = MediaQuery.sizeOf(context);
    final bool screenPick = _sampler != null;
    final bool follow = _inside && _local != null;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _finishCancel,
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          onExit: (_) => setState(() => _inside = false),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerHover: (PointerHoverEvent event) {
              if (screenPick) {
                setState(() {
                  _inside = true;
                  _local = event.position;
                });
              } else {
                _trackCanvas(event.position);
              }
            },
            onPointerMove: (PointerMoveEvent event) {
              if (screenPick) {
                setState(() {
                  _inside = true;
                  _local = event.position;
                });
              } else {
                _trackCanvas(event.position);
              }
            },
            onPointerDown: (PointerDownEvent event) {
              if (screenPick) {
                return;
              }
              _trackCanvas(event.position);
              final Color? color = _color;
              if (color != null) {
                _done = true;
                widget.onPick(color);
              }
            },
            child: Stack(
              children: <Widget>[
                const SizedBox.expand(),
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: MiuixTheme(
                      data: theme,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: ShapeDecoration(
                          color: theme.colors.surfaceContainer,
                          shape: const MiuixSquircleBorder(cornerRadius: 12),
                        ),
                        child: MiuixText(
                          screenPick ? '点击屏幕任意位置取色，Esc 取消' : '点击画布取色，Esc 取消',
                          style: theme.textStyles.footnote1,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_cells != null && _color != null)
                  Positioned(
                    left: follow
                        ? _loupeLeft(_local!, screen)
                        : (screen.width - 132) / 2,
                    top: follow ? _loupeTop(_local!, screen) : 72,
                    child: _Loupe(
                      cells: _cells!,
                      color: _color!,
                      radius: _radius,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _loupeLeft(Offset cursor, Size screen) {
    const double width = 132;
    final double right = cursor.dx + 20;
    if (right + width > screen.width - 8) {
      return (cursor.dx - width - 20)
          .clamp(8.0, screen.width - width - 8)
          .toDouble();
    }
    return right;
  }

  double _loupeTop(Offset cursor, Size screen) {
    const double height = 156;
    final double above = cursor.dy - height - 16;
    if (above < 8) {
      return (cursor.dy + 20).clamp(8.0, screen.height - height - 8).toDouble();
    }
    return above;
  }
}

class _Loupe extends StatelessWidget {
  const _Loupe(
      {required this.cells, required this.color, required this.radius});

  final List<Color> cells;
  final Color color;
  final int radius;

  @override
  Widget build(BuildContext context) {
    final String hex = (color.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    return Container(
      width: 132,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: const Color(0xF0FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33000000)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
              color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CustomPaint(
            size: const Size(116, 116),
            painter: _LoupePainter(cells: cells, radius: radius),
          ),
          const SizedBox(height: 4),
          Text(
            '#$hex',
            style: const TextStyle(
              fontSize: 12,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _LoupePainter extends CustomPainter {
  const _LoupePainter({required this.cells, required this.radius});

  final List<Color> cells;
  final int radius;

  @override
  void paint(Canvas canvas, Size size) {
    final int side = radius * 2 + 1;
    final double cell = size.width / side;
    final Paint paint = Paint();
    for (int row = 0; row < side; row++) {
      for (int col = 0; col < side; col++) {
        paint.color = cells[row * side + col];
        canvas.drawRect(
          Rect.fromLTWH(col * cell, row * cell, cell, cell),
          paint,
        );
      }
    }
    final double center = radius * cell;
    canvas.drawRect(
      Rect.fromLTWH(center, center, cell, cell),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFFFFF),
    );
    canvas.drawRect(
      Rect.fromLTWH(center + 1, center + 1, cell - 2, cell - 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF000000),
    );
  }

  @override
  bool shouldRepaint(_LoupePainter oldDelegate) => true;
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter({required this.cell});

  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint light = Paint()..color = const Color(0xFFFFFFFF);
    final Paint dark = Paint()..color = const Color(0xFFD0D0D0);
    canvas.drawRect(Offset.zero & size, light);
    for (double y = 0; y < size.height; y += cell) {
      for (double x = 0; x < size.width; x += cell) {
        final bool odd = ((x / cell).floor() + (y / cell).floor()).isOdd;
        if (odd) {
          canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => oldDelegate.cell != cell;
}

class _PenColorDialog extends StatelessWidget {
  const _PenColorDialog({required this.initial, required this.title});

  final Color initial;
  final String title;

  @override
  Widget build(BuildContext context) {
    return MiuixTheme(
      data: MiuixThemeData.of(Theme.of(context).brightness),
      child: MiuixPopupScope(
        establishRoot: true,
        child: Stack(
          children: <Widget>[
            MiuixOverlayDialog(
              key: const ValueKey<String>('wb-pen-color-dialog'),
              show: true,
              renderInRootScaffold: false,
              title: title,
              maxWidth: 560 + MiuixDialogDefaults.insideMargin.width * 2,
              onDismissRequest: () => Navigator.of(context).pop(),
              content: _PenColorDialogBody(initial: initial),
            ),
            const MiuixPopupHost(),
          ],
        ),
      ),
    );
  }
}

class _PenColorDialogBody extends StatefulWidget {
  const _PenColorDialogBody({required this.initial});

  final Color initial;

  @override
  State<_PenColorDialogBody> createState() => _PenColorDialogBodyState();
}

class _PenColorDialogBodyState extends State<_PenColorDialogBody> {
  late Color _selected = widget.initial;

  void _select(Color color) {
    setState(() => _selected = color);
  }

  @override
  Widget build(BuildContext context) {
    const EdgeInsets padding =
        EdgeInsets.symmetric(horizontal: 16, vertical: 6);
    return SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              WbPenColorWheel(
                key: const ValueKey<String>('wb-pen-color-picker'),
                color: _selected,
                onChanged: _select,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: _PenColorValueBox(
                  color: _selected,
                  onChanged: _select,
                  onEyedrop: () =>
                      Navigator.of(context).pop(const _PenColorResult.pick()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              Expanded(
                child: MiuixButton(
                  onPressed: () => Navigator.of(context).pop(),
                  minHeight: 40,
                  cornerRadius: 14,
                  insideMargin: padding,
                  child: const MiuixText('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: MiuixButton(
                  key: const ValueKey<String>('wb-pen-color-confirm'),
                  onPressed: () => Navigator.of(context)
                      .pop(_PenColorResult.confirm(_selected)),
                  minHeight: 40,
                  cornerRadius: 14,
                  insideMargin: padding,
                  colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                  child: const MiuixText('确定'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
