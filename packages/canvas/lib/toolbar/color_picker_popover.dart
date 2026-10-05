/// 工具栏样式弹层：颜色选择、单选（对齐 / 线型 / 字号等）、线宽选择，
/// 以及"选色再点表面"的待应用样式状态模型与状态条。
///
/// 交互对齐《可扩展工具栏设计 v1.0》：
/// - §11.2：选色后进入"待应用"状态（光标油漆桶 → 点击表面应用 → Esc 退出）；
/// - §12.2：函数换色 / 换线型实时生效（即时应用路径）；
/// - §17.2：点击空白处收起（遮罩点击关闭）；
/// - §18.3：轻阴影 + 毛玻璃感（阴影 + 边框近似）。
///
/// 颜色数据：预设 12 色板 + 主题色（`context.wbColors.primary`，动态注入）
/// + 自定义 `#RGB / #RRGGBB / #AARRGGBB` 输入。
///
/// 所有弹层以 [OverlayEntry] 锚定在触发按钮附近（优先上方，空间不足翻转到
/// 下方），返回所选值；点击遮罩返回 null 表示取消。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'toolbar_config.dart';
import 'toolbar_item.dart';

/// 取得组件全局外接矩形（弹层锚点定位用；无 RenderBox 时返回 [Rect.zero]）。
Rect wbGlobalRectOf(BuildContext context) {
  final RenderObject? object = context.findRenderObject();
  if (object is RenderBox && object.hasSize) {
    return object.localToGlobal(Offset.zero) & object.size;
  }
  return Rect.zero;
}

// ---- 通用弹层入口 ----------------------------------------------------------

const double _kPopoverMargin = 8;
const double _kPopoverGap = 8;

Future<T?> _showWbPopover<T>({
  required BuildContext context,
  required Rect anchor,
  required double width,
  required double estimatedHeight,
  required Widget Function(BuildContext context, void Function(T? value) close)
      builder,
}) {
  final OverlayState overlay = Overlay.of(context);
  final MediaQueryData media = MediaQuery.of(context);
  final Completer<T?> completer = Completer<T?>();
  late final OverlayEntry entry;

  void close(T? value) {
    if (completer.isCompleted) {
      return;
    }
    if (entry.mounted) {
      entry.remove();
    }
    completer.complete(value);
  }

  final double maxLeft = media.size.width - width - _kPopoverMargin;
  final double left = (anchor.center.dx - width / 2).clamp(
    _kPopoverMargin,
    maxLeft < _kPopoverMargin ? _kPopoverMargin : maxLeft,
  );
  final double above = anchor.top - estimatedHeight - _kPopoverGap;
  final double top;
  if (above >= _kPopoverMargin) {
    top = above;
  } else {
    final double below = anchor.bottom + _kPopoverGap;
    top = below.clamp(
      0.0,
      (media.size.height - estimatedHeight).clamp(0.0, double.infinity),
    );
  }

  entry = OverlayEntry(
    builder: (BuildContext overlayContext) {
      return Stack(
        children: <Widget>[
          // 透明遮罩：点击空白处收起（文档 §17.2）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => close(null),
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: width,
            child: Material(
              color: Colors.transparent,
              child: builder(overlayContext, close),
            ),
          ),
        ],
      );
    },
  );
  overlay.insert(entry);
  return completer.future;
}

// ---- 颜色选择弹层 ----------------------------------------------------------

/// 弹出颜色选择弹层。
///
/// - [anchor]：触发按钮的全局矩形（用 [wbGlobalRectOf] 获取）；
/// - [current]：当前颜色（显示选中圈）；[themeColor] 非空时显示主题色行；
/// - [palette]：预设色板（默认 [WbToolbarPalette.presets]）；
/// - 返回所选颜色；点击外部 / 遮罩返回 null。
Future<Color?> showWbColorPicker(
  BuildContext context, {
  required Rect anchor,
  String title = '选择颜色',
  Color? current,
  Color? themeColor,
  List<Color>? palette,
}) {
  final WbThemeColors colors = context.wbColors;
  return _showWbPopover<Color>(
    context: context,
    anchor: anchor,
    width: 232,
    estimatedHeight: themeColor == null ? 186 : 224,
    builder: (BuildContext context, void Function(Color? value) close) {
      return WbColorPickerPanel(
        title: title,
        current: current,
        themeColor: themeColor ?? colors.primary,
        palette: palette ?? WbToolbarPalette.presets,
        onPick: (Color color) => close(color),
      );
    },
  );
}

/// 颜色选择面板（预设 12 色 + 主题色 + 自定义输入）。
///
/// [showChrome] 为 false 时仅渲染内容（无外框 / 阴影），便于嵌入对话框等宿主。
class WbColorPickerPanel extends StatelessWidget {
  const WbColorPickerPanel({
    super.key,
    required this.onPick,
    this.title = '选择颜色',
    this.current,
    this.themeColor,
    this.palette = WbToolbarPalette.presets,
    this.showChrome = true,
    this.showTitle = true,
    this.showCustomInput = true,
    this.showSelection = true,
  });

  /// 选色回调。
  final ValueChanged<Color> onPick;

  /// 面板标题。
  final String title;

  /// 当前颜色。
  final Color? current;

  /// 主题色（null 不显示主题色行）。
  final Color? themeColor;

  /// 预设色板。
  final List<Color> palette;

  /// 是否绘制外框、边框与阴影。
  final bool showChrome;

  /// 是否显示标题文字。
  final bool showTitle;

  /// 是否显示自定义十六进制输入行。
  final bool showCustomInput;

  /// 是否在色点上显示选中圈。
  final bool showSelection;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showTitle) ...<Widget>[
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: colors.icon.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (int i = 0; i < palette.length; i++)
              _SwatchDot(
                key: ValueKey<String>('wb-color-swatch-$i'),
                color: palette[i],
                selected: showSelection && current == palette[i],
                onTap: () => onPick(palette[i]),
              ),
          ],
        ),
        if (themeColor != null) ...<Widget>[
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _SwatchDot(
                key: const ValueKey<String>('wb-color-swatch-theme'),
                color: themeColor!,
                selected: showSelection && current == themeColor,
                onTap: () => onPick(themeColor!),
              ),
              const SizedBox(width: 8),
              Text(
                '主题色',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: colors.icon),
              ),
            ],
          ),
        ],
        if (showCustomInput) ...<Widget>[
          const SizedBox(height: 10),
          _CustomColorRow(onSubmit: onPick),
        ],
      ],
    );
    if (!showChrome) {
      return body;
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
        boxShadow: wbToolbarShadow,
      ),
      child: body,
    );
  }
}

/// 单个色板圆点（24px，选中显示主色圈）。
class _SwatchDot extends StatelessWidget {
  const _SwatchDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: wbColorToHex(color),
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? colors.primary : colors.cardBorder,
                width: selected ? 2 : 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 自定义十六进制颜色输入行。
class _CustomColorRow extends StatefulWidget {
  const _CustomColorRow({required this.onSubmit});

  final ValueChanged<Color> onSubmit;

  @override
  State<_CustomColorRow> createState() => _CustomColorRowState();
}

class _CustomColorRowState extends State<_CustomColorRow> {
  final TextEditingController _controller = TextEditingController();
  Color? _parsed;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    final Color? parsed = parseWbHexColor(raw);
    if (parsed != _parsed) {
      setState(() => _parsed = parsed);
    }
  }

  void _submit() {
    final Color? parsed = _parsed;
    if (parsed != null) {
      widget.onSubmit(parsed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Row(
      children: <Widget>[
        Expanded(
          child: SizedBox(
            height: 30,
            child: TextField(
              key: const ValueKey<String>('wb-color-custom-input'),
              controller: _controller,
              onChanged: _onChanged,
              onSubmitted: (_) => _submit(),
              style: Theme.of(context).textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                hintText: '#RRGGBB',
                hintStyle: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: colors.icon.withValues(alpha: 0.5)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: colors.cardBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: colors.cardBorder),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        WbToolbarIconButton(
          key: const ValueKey<String>('wb-color-custom-apply'),
          icon: LinearIcons.check,
          tooltip: '应用自定义颜色',
          enabled: _parsed != null,
          interactive: _parsed != null,
          iconSize: 16,
          onTap: _submit,
        ),
      ],
    );
  }
}

/// 解析 `#RGB / #RRGGBB / #AARRGGBB`（可省略 `#`）；非法返回 null。
Color? parseWbHexColor(String raw) {
  String value = raw.trim();
  if (value.startsWith('#')) {
    value = value.substring(1);
  }
  if (value.length == 3) {
    final String r = value[0];
    final String g = value[1];
    final String b = value[2];
    value = '$r$r$g$g$b$b';
  }
  if (value.length != 6 && value.length != 8) {
    return null;
  }
  final int? parsed = int.tryParse(value, radix: 16);
  if (parsed == null) {
    return null;
  }
  return Color(value.length == 6 ? 0xFF000000 | parsed : parsed);
}

// ---- 单选弹层 --------------------------------------------------------------

/// 弹出单选弹层（对齐 / 线型 / 字号等通用参数选择）。
Future<WbChoiceOption?> showWbChoicePopover(
  BuildContext context, {
  required Rect anchor,
  required String title,
  required List<WbChoiceOption> options,
  String? current,
}) {
  return _showWbPopover<WbChoiceOption>(
    context: context,
    anchor: anchor,
    width: 200,
    estimatedHeight: 52.0 + options.length * 32,
    builder: (BuildContext context, void Function(WbChoiceOption? value) close) {
      return WbChoicePopoverPanel(
        title: title,
        options: options,
        current: current,
        onPick: (WbChoiceOption option) => close(option),
      );
    },
  );
}

/// 单选弹层面板。
class WbChoicePopoverPanel extends StatelessWidget {
  const WbChoicePopoverPanel({
    super.key,
    required this.title,
    required this.options,
    required this.onPick,
    this.current,
  });

  /// 标题。
  final String title;

  /// 选项。
  final List<WbChoiceOption> options;

  /// 选中回调。
  final ValueChanged<WbChoiceOption> onPick;

  /// 当前值。
  final String? current;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
        boxShadow: wbToolbarShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: colors.icon.withValues(alpha: 0.75)),
            ),
          ),
          for (final WbChoiceOption option in options)
            InkWell(
              key: ValueKey<String>('wb-choice-${option.value}'),
              onTap: () => onPick(option),
              hoverColor: colors.cardHover,
              child: SizedBox(
                height: 32,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: <Widget>[
                      if (option.icon != null) ...<Widget>[
                        Icon(option.icon, size: 16, color: colors.toolbarIcon),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          option.label,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colors.icon),
                        ),
                      ),
                      if (current == option.value)
                        Icon(LinearIcons.check,
                            size: 15, color: colors.primary),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- 线宽选择弹层 ----------------------------------------------------------

/// 弹出线宽选择弹层（文档 §9 / §12 / §13 的"线宽"按钮）。
Future<double?> showWbLineWidthPicker(
  BuildContext context, {
  required Rect anchor,
  double? current,
  List<double> widths = WbToolbarPalette.lineWidths,
  String title = '线宽',
}) {
  return _showWbPopover<double>(
    context: context,
    anchor: anchor,
    width: 176,
    estimatedHeight: 96,
    builder: (BuildContext context, void Function(double? value) close) {
      return WbLineWidthPickerPanel(
        title: title,
        widths: widths,
        current: current,
        onPick: (double width) => close(width),
      );
    },
  );
}

/// 线宽选择面板（不同粗细圆点 + 数值）。
class WbLineWidthPickerPanel extends StatelessWidget {
  const WbLineWidthPickerPanel({
    super.key,
    required this.onPick,
    this.title = '线宽',
    this.widths = WbToolbarPalette.lineWidths,
    this.current,
  });

  /// 选中回调。
  final ValueChanged<double> onPick;

  /// 标题。
  final String title;

  /// 线宽档位。
  final List<double> widths;

  /// 当前线宽。
  final double? current;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
        boxShadow: wbToolbarShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: colors.icon.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < widths.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 6),
                Tooltip(
                  message: '线宽 ${widths[i].toInt()}',
                  waitDuration: const Duration(milliseconds: 600),
                  child: InkWell(
                    key: ValueKey<String>('wb-line-width-$i'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onPick(widths[i]),
                    hoverColor: colors.cardHover,
                    child: Container(
                      width: 34,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: current == widths[i]
                              ? colors.primary
                              : Colors.transparent,
                        ),
                      ),
                      child: Container(
                        width: widths[i] + 6,
                        height: widths[i] + 6,
                        decoration: BoxDecoration(
                          color: colors.toolbarIcon,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ---- 待应用样式（"选色再点表面"）-------------------------------------------

/// 待应用样式：选色 / 选宽完成后、等待用户在表面（如 3D 面）点击应用的状态。
///
/// 文档 §11.2 的"选色后点表面"二级交互；画布点击由宿主接线（当前画布控制
/// 器对工具栏不可达，见实现报告偏差），工具栏负责状态展示与 Esc 退出。
class WbPendingStyle {
  const WbPendingStyle({
    required this.toolId,
    required this.color,
    required this.label,
  });

  /// 待执行工具 id（如 `render.3d.setFaceColor`）。
  final String toolId;

  /// 已选颜色。
  final Color color;

  /// 应用目标文案（如 '3D 表面'）。
  final String label;

  @override
  String toString() => 'WbPendingStyle($toolId, $color)';
}

/// 待应用样式状态条（替换工具栏主行显示）。
class WbPendingStyleBar extends StatelessWidget {
  const WbPendingStyleBar({
    super.key,
    required this.style,
    required this.onCancel,
  });

  /// 待应用样式。
  final WbPendingStyle style;

  /// 退出待应用状态（Esc / 关闭按钮）。
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Row(
      key: const ValueKey<String>('wb-toolbar-pending'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: style.color,
            shape: BoxShape.circle,
            border: Border.all(color: colors.cardBorder),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '已选 ${wbColorToHex(style.color)} · 点击${style.label}应用（Esc 退出）',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colors.icon),
        ),
        const SizedBox(width: 6),
        WbToolbarIconButton(
          key: const ValueKey<String>('wb-toolbar-pending-cancel'),
          icon: LinearIcons.close,
          tooltip: '退出应用模式',
          iconSize: 16,
          onTap: onCancel,
        ),
      ],
    );
  }
}
