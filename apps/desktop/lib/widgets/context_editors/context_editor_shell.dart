/// 专业元素上下文编辑器共享外壳（Wave 3.6）。
///
/// 本文件提供：
/// - [WbContextPalette]：上下文编辑器统一调色板（流程图节点色对齐
///   《流程图模块设计》§12.1，通用强调色与 `widgets/canvas/canvas_model.dart`
///   的 `WbCanvasPalette` 同口径）；
/// - [WbContextMetrics]：节点尺寸 / 圆角 / 间距等排版常量；
/// - [WbContextEditorShell]：统一面板容器（标题栏 + 操作区 + 关闭按钮）；
/// - 一组紧凑控件（图标按钮 / 选择 chip / 色板行 / 滑杆 / 开关行等），
///   供各编辑器复用，避免跨文件重复实现。
///
/// 设计约定：
/// - 颜色优先走主题 token（`context.wbColors`），主题扩展缺失时回退内置
///   默认主题，因此组件不依赖 Provider / 主题环境即可独立挂载与测试；
/// - 所有交互控件通过 `Key` 暴露稳定标识（`wb-ctx-*` 前缀），供测试与
///   后续自动化引用；
/// - 面板自身不产生网络 / FFI 调用，变更一律通过各编辑器的 `onChanged`
///   上报，由集成层决定落盘方式。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

/// 上下文编辑器统一调色板。
///
/// 流程图节点色与《流程图模块设计》§12.1 一致；通用选择色与
/// `WbCanvasPalette`（canvas_model.dart）保持同一色板口径。
abstract final class WbContextPalette {
  // ---- 流程图节点色（§12.1 亮色口径）----
  /// 开始节点（绿）。
  static const Color flowStart = Color(0xFF34C724);

  /// 结束节点（红）。
  static const Color flowEnd = Color(0xFFF54A45);

  /// 处理节点（蓝，与 `WbCanvasPalette.shapeColors[0]` 一致）。
  static const Color flowProcess = Color(0xFF3370FF);

  /// 判断节点（橙）。
  static const Color flowDecision = Color(0xFFFF8800);

  /// 输入 / 输出节点（紫）。
  static const Color flowInputOutput = Color(0xFF7C5CFF);

  /// 文档节点（灰）。
  static const Color flowDocument = Color(0xFF646A73);

  /// 数据库节点（青）。
  static const Color flowDatabase = Color(0xFF00B8D9);

  /// 手动操作节点（黄）。
  static const Color flowManual = Color(0xFFFFC107);

  /// 连接点（灰）。
  static const Color flowConnector = Color(0xFF8C8C8C);

  /// 注释底色（浅黄）。
  static const Color flowAnnotation = Color(0xFFFFF7CC);

  /// 连线路由色。
  static const Color flowLine = Color(0xFF646A73);

  /// 泳道背景 / 边框（§12.1）。
  static const Color flowLaneBackground = Color(0xFFF7F8FA);
  static const Color flowLaneBorder = Color(0xFFE5E6EB);

  // ---- 通用选择色板（前 4 色与 WbCanvasPalette.shapeColors 相同口径）----
  /// 通用颜色选项（形状 / 表头 / 材质 / 曲线共用）。
  static const List<Color> swatches = <Color>[
    Color(0xFF3370FF),
    Color(0xFF12A150),
    Color(0xFFE5484D),
    Color(0xFFF5A623),
    Color(0xFF7C5CFF),
    Color(0xFF00B8D9),
    Color(0xFF1F2933),
    Color(0xFFFFF2B2),
  ];

  /// 默认元素色（= [swatches] 首色，供常量默认值引用）。
  static const Color defaultElementColor = Color(0xFF3370FF);

  /// 函数曲线默认色板（多曲线依次取色）。
  static const List<Color> curveSwatches = <Color>[
    Color(0xFF3370FF),
    Color(0xFFE5484D),
    Color(0xFF12A150),
    Color(0xFFF5A623),
    Color(0xFF7C5CFF),
    Color(0xFF00B8D9),
  ];

  /// 浅色填充（节点内部 / 选中底色），保持与画布元素“淡底彩边”风格一致。
  static Color softFill(Color color, {double alpha = 0.14}) =>
      color.withValues(alpha: alpha);
}

/// 上下文编辑器排版常量（与画布元素口径一致）。
abstract final class WbContextMetrics {
  /// 面板圆角（与画布悬浮面板一致）。
  static const double panelRadius = 12;

  /// 小控件圆角。
  static const double controlRadius = 8;

  /// 流程图节点默认宽 / 高（§12.3 内边距 12x16 的紧凑近似）。
  static const double flowNodeWidth = 132;
  static const double flowNodeHeight = 46;

  /// 流程图节点圆角（§12.3：节点圆角 8，判断 0 由绘制器处理）。
  static const double flowNodeRadius = 8;

  /// 流程图预览世界尺寸（无约束时的回退布局画布）。
  static const Size flowFallbackCanvas = Size(420, 320);

  /// 思维导图节点尺寸。
  static const double mindNodeWidth = 132;
  static const double mindNodeHeight = 34;

  /// 编辑器内边距。
  static const EdgeInsets panelPadding = EdgeInsets.all(12);

  /// 编辑器面板默认宽度。
  static const double defaultWidth = 420;
}

/// 上下文编辑器外壳：统一标题栏 / 操作区 / 关闭约定。
///
/// 使用方按如下结构挂载（需提供有界高度，内部使用 [Expanded] 承载内容）：
///
/// ```dart
/// SizedBox(
///   width: 420,
///   height: 680,
///   child: WbFlowchartEditor(onChanged: (m) { ... }),
/// )
/// ```
class WbContextEditorShell extends StatelessWidget {
  /// 创建外壳。
  const WbContextEditorShell({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.actions = const <Widget>[],
    this.onClose,
    this.width = WbContextMetrics.defaultWidth,
    this.child,
  });

  /// 面板标题。
  final String title;

  /// 标题图标（来自 `whiteboard_icons`）。
  final IconData icon;

  /// 次级说明（可选）。
  final String? subtitle;

  /// 标题栏右侧附加操作（关闭按钮之前）。
  final List<Widget> actions;

  /// 关闭回调（null 时隐藏关闭按钮）。
  final VoidCallback? onClose;

  /// 面板宽度。
  final double width;

  /// 面板内容。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final String? sub = subtitle;
    return SizedBox(
      width: width,
      child: Material(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(WbContextMetrics.panelRadius),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WbContextMetrics.panelRadius),
            border: Border.all(color: colors.cardBorder),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                child: Row(
                  children: <Widget>[
                    Icon(icon, size: 18, color: colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            style: WbTypography.title.copyWith(color: colors.icon),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (sub != null && sub.isNotEmpty)
                            Text(
                              sub,
                              style: WbTypography.caption
                                  .copyWith(color: colors.icon.withValues(alpha: 0.6)),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    ...actions,
                    if (onClose != null)
                      WbEditorIconButton(
                        key: const ValueKey<String>('wb-ctx-editor-close'),
                        icon: LinearIcons.close,
                        tooltip: '关闭编辑器',
                        onTap: onClose!,
                      ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: colors.cardBorder),
              Expanded(child: child ?? const SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
  }
}

/// 编辑器内紧凑图标按钮（28x28，含 hover / active 态）。
class WbEditorIconButton extends StatelessWidget {
  /// 创建按钮。
  const WbEditorIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.active = false,
    this.enabled = true,
    this.size = 28,
    this.iconSize = 16,
  });

  /// 图标。
  final IconData icon;

  /// 点击回调。
  final VoidCallback onTap;

  /// 悬浮提示。
  final String? tooltip;

  /// 激活态（主色高亮）。
  final bool active;

  /// 是否可用。
  final bool enabled;

  /// 按钮边长。
  final double size;

  /// 图标尺寸。
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Color foreground = enabled
        ? (active ? colors.primary : colors.toolbarIcon)
        : colors.toolbarIcon.withValues(alpha: 0.35);
    final Widget button = Material(
      color: active ? colors.primary.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
        hoverColor: colors.cardHover,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: iconSize, color: foreground),
        ),
      ),
    );
    final String? message = tooltip;
    if (message == null) {
      return button;
    }
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 600),
      child: button,
    );
  }
}

/// 文本选择 chip（单选语义；用于方向 / 布局 / 样式等开关组）。
class WbEditorChip extends StatelessWidget {
  /// 创建 chip。
  const WbEditorChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
    this.dense = false,
  });

  /// 文本。
  final String label;

  /// 是否选中。
  final bool selected;

  /// 点击回调（null 时禁用）。
  final VoidCallback? onTap;

  /// 前置图标（可选）。
  final IconData? icon;

  /// 紧凑模式（更小内边距）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Color foreground = selected ? colors.primary : colors.toolbarIcon;
    final Widget? leading = icon == null
        ? null
        : Icon(icon, size: dense ? 12 : 14, color: foreground);
    return Material(
      color: selected
          ? colors.primary.withValues(alpha: 0.12)
          : colors.cardHover.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
        hoverColor: colors.cardHover,
        child: Padding(
          padding: dense
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (leading != null) ...<Widget>[leading, const SizedBox(width: 4)],
              Text(
                label,
                style: (dense ? WbTypography.caption : WbTypography.label)
                    .copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 色板选择行（圆点色块，点击选择）。
class WbEditorColorRow extends StatelessWidget {
  /// 创建色板行。
  const WbEditorColorRow({
    super.key,
    required this.colors,
    required this.onSelect,
    this.selected,
    this.keyPrefix = 'wb-ctx-color',
    this.swatchSize = 20,
  });

  /// 可选项。
  final List<Color> colors;

  /// 选中回调。
  final ValueChanged<Color> onSelect;

  /// 当前选中色（null 不显示选中环）。
  final Color? selected;

  /// 子项 key 前缀（格式 `$keyPrefix-$i`）。
  final String keyPrefix;

  /// 色块直径。
  final double swatchSize;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors tokens = context.wbColors;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (int i = 0; i < colors.length; i++)
          _WbColorSwatch(
            key: ValueKey<String>('$keyPrefix-$i'),
            color: colors[i],
            selected: selected != null && selected!.toARGB32() == colors[i].toARGB32(),
            border: tokens.cardBorder,
            size: swatchSize,
            onTap: () => onSelect(colors[i]),
          ),
      ],
    );
  }
}

/// 单个色块。
class _WbColorSwatch extends StatelessWidget {
  const _WbColorSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.border,
    required this.size,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final Color border;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? context.wbColors.primary : border,
            width: selected ? 2.4 : 1,
          ),
        ),
      ),
    );
  }
}

/// 区块标题（小号次要文本）。
class WbEditorSectionTitle extends StatelessWidget {
  /// 创建标题。
  const WbEditorSectionTitle({super.key, required this.title, this.trailing});

  /// 标题文本。
  final String title;

  /// 右侧附加内容。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: WbTypography.label.copyWith(
                color: colors.icon.withValues(alpha: 0.62),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 标签 + 滑杆 + 数值行。
class WbEditorSlider extends StatelessWidget {
  /// 创建滑杆行。
  const WbEditorSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.valueLabel,
    this.divisions,
  });

  /// 标签。
  final String label;

  /// 当前值。
  final double value;

  /// 最小值。
  final double min;

  /// 最大值。
  final double max;

  /// 变更回调。
  final ValueChanged<double> onChanged;

  /// 数值展示文本（默认保留一位小数）。
  final String? valueLabel;

  /// 分段数（null 连续）。
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final String shown = valueLabel ?? value.toStringAsFixed(1);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: WbTypography.caption.copyWith(color: colors.icon),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            shown,
            textAlign: TextAlign.right,
            style: WbTypography.caption.copyWith(
              color: colors.icon.withValues(alpha: 0.75),
            ),
          ),
        ),
      ],
    );
  }
}

/// 开关行（标签 + Switch，紧凑）。
class WbEditorSwitchRow extends StatelessWidget {
  /// 创建开关行。
  const WbEditorSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  /// 标签。
  final String label;

  /// 当前值。
  final bool value;

  /// 变更回调。
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: WbTypography.caption.copyWith(color: colors.icon),
          ),
        ),
        SizedBox(
          height: 26,
          child: FittedBox(
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }
}

/// 次要提示文本。
class WbEditorHint extends StatelessWidget {
  /// 创建提示。
  const WbEditorHint(this.text, {super.key});

  /// 文本。
  final String text;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Text(
      text,
      style: WbTypography.caption.copyWith(
        color: colors.icon.withValues(alpha: 0.55),
      ),
    );
  }
}

/// 编辑器内输入框统一装饰（紧凑）。
InputDecoration wbEditorInputDecoration(
  BuildContext context, {
  String? hint,
  String? suffix,
}) {
  final WbThemeColors colors = context.wbColors;
  return InputDecoration(
    isDense: true,
    hintText: hint,
    suffixText: suffix,
    hintStyle: WbTypography.body.copyWith(
      color: colors.icon.withValues(alpha: 0.4),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    filled: true,
    fillColor: colors.canvas.withValues(alpha: 0.6),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      borderSide: BorderSide(color: colors.cardBorder),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      borderSide: BorderSide(color: colors.cardBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      borderSide: BorderSide(color: colors.primary, width: 1.4),
    ),
  );
}
