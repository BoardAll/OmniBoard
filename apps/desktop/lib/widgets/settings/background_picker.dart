/// 背景选择器：内置预设网格（纯色 / 点阵 / 网格 / 横线 / 方格）、
/// 自定义色与图案参数（《主题与背景系统设计》§8.2 / §7.2 / §10.1）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_core/wb_core.dart' show WbBackgroundPreset;
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../canvas/background_painter.dart';
import 'settings_section.dart';

/// 背景预览块：用背景自身参数绘制的微缩画布。
class WbBackgroundPreview extends StatelessWidget {
  const WbBackgroundPreview({
    super.key,
    required this.type,
    required this.baseColor,
    this.patternColor,
    this.spacing = 20,
    this.opacity = 1.0,
    this.width = double.infinity,
    this.height = 64,
  });

  /// 图案类型：solid / dot / grid / lined / squared。
  final String type;

  /// 底色。
  final Color baseColor;

  /// 图案色（null 时不绘制图案）。
  final Color? patternColor;

  /// 图案间距（逻辑像素；<= 0 时使用 20）。
  final double spacing;

  /// 图案不透明度（0–1）。
  final double opacity;

  /// 预览宽度。
  final double width;

  /// 预览高度。
  final double height;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: baseColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: patternColor == null || type == 'solid' || opacity <= 0
          ? null
          : CustomPaint(
              painter: WbBackgroundPatternPainter(
                type: type,
                patternColor: patternColor,
                spacing: spacing,
                opacity: opacity,
              ),
            ),
    );
  }
}

/// 背景选择器（受控组件）。
///
/// 状态由构造参数传入、变更经回调上抛；未挂载 Provider 也可独立 pump。
/// 应用动作（写入页面背景）由宿主经 `WbPageState.setBackground` 完成，
/// 本组件只负责选择与预览。
class BackgroundPicker extends StatelessWidget {
  const BackgroundPicker({
    super.key,
    required this.presets,
    required this.selectedPresetId,
    required this.customColor,
    required this.onPresetSelected,
    this.onPickCustomColor,
    required this.followTheme,
    this.onFollowThemeChanged,
    required this.spacing,
    this.onSpacingChanged,
    required this.patternColor,
    this.onPickPatternColor,
    required this.opacity,
    this.onOpacityChanged,
    this.onApplyToCurrentPage,
    this.onApplyToAllPages,
    this.applyHint,
    this.reduceMotion = false,
    this.highContrast = false,
  });

  /// 可选背景预设（内置 11 个，顺序与 `WbBackgroundService.builtinPresets` 一致）。
  final List<WbBackgroundPreset> presets;

  /// 当前选中预设 id（自定义色非空时不生效）。
  final String selectedPresetId;

  /// 自定义背景色（`#RRGGBB`；空串 = 未选）。
  final String customColor;

  /// 选择预设回调（即时生效由宿主完成）。
  final ValueChanged<String> onPresetSelected;

  /// 打开自定义色选择（null 时卡片禁用）。
  final VoidCallback? onPickCustomColor;

  /// 背景是否跟随主题。
  final bool followTheme;

  /// 跟随主题开关回调（null 时禁用）。
  final ValueChanged<bool>? onFollowThemeChanged;

  /// 图案间距覆盖（0 = 跟随预设）。
  final int spacing;

  /// 图案间距回调（null 时滑杆禁用）。
  final ValueChanged<int>? onSpacingChanged;

  /// 图案颜色覆盖（`#RRGGBB`；空串 = 跟随预设）。
  final String patternColor;

  /// 打开图案色选择（null 时按钮禁用）。
  final VoidCallback? onPickPatternColor;

  /// 图案透明度（0–1）。
  final double opacity;

  /// 图案透明度回调（null 时滑杆禁用）。
  final ValueChanged<double>? onOpacityChanged;

  /// 应用到当前页（null 时按钮禁用）。
  final VoidCallback? onApplyToCurrentPage;

  /// 应用到全部页（null 时按钮禁用）。
  final VoidCallback? onApplyToAllPages;

  /// 应用区说明文案（可选，有默认值）。
  final String? applyHint;

  /// 减少动效（卡片过渡时长归零）。
  final bool reduceMotion;

  /// 高对比度（卡片描边加强）。
  final bool highContrast;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final bool custom = customColor.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SettingsTile(
          leading: Icon(LinearIcons.sync, size: 18, color: colors.icon),
          title: '背景跟随主题',
          subtitle: followTheme
              ? '切换主题时自动使用主题默认背景（文档 §7.2）'
              : '已关闭：背景独立于主题，手动选择后保持',
          trailing: Switch(
            key: const ValueKey<String>('background-follow-theme'),
            value: followTheme,
            onChanged: onFollowThemeChanged,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final WbBackgroundPreset preset in presets)
              _BackgroundCard(
                key: ValueKey<String>('background-preset-${preset.id}'),
                checkKey: ValueKey<String>('background-check-${preset.id}'),
                label: preset.name,
                selected: !custom && preset.id == selectedPresetId,
                preview: _presetPreview(preset),
                onTap: () => onPresetSelected(preset.id),
                reduceMotion: reduceMotion,
                highContrast: highContrast,
              ),
            _BackgroundCard(
              key: const ValueKey<String>('background-custom-color'),
              checkKey: const ValueKey<String>('background-custom-check'),
              label: '自定义色',
              selected: custom,
              preview: WbBackgroundPreview(
                type: 'solid',
                baseColor: custom
                    ? WbColorUtils.fromHex(
                        customColor,
                        fallback: const Color(0xFFFFFFFF),
                      )
                    : const Color(0xFFE4E7EC),
              ),
              onTap: onPickCustomColor,
              reduceMotion: reduceMotion,
              highContrast: highContrast,
            ),
          ],
        ),
        const Divider(height: 28),
        SettingsTile(
          leading: Icon(LinearIcons.grid, size: 18, color: colors.icon),
          title: '图案间距',
          subtitle: spacing == 0
              ? '跟随预设（点阵 20 / 网格 25 px 等）'
              : '覆盖值：$spacing px',
          trailing: SizedBox(
            width: 240,
            child: Slider(
              key: const ValueKey<String>('background-spacing'),
              min: 0,
              max: 120,
              divisions: 24,
              value: spacing.toDouble().clamp(0, 120),
              onChanged: onSpacingChanged == null
                  ? null
                  : (double value) => onSpacingChanged!(value.round()),
            ),
          ),
        ),
        SettingsTile(
          leading: Icon(LinearIcons.palette, size: 18, color: colors.icon),
          title: '图案颜色',
          subtitle: patternColor.isEmpty ? '跟随预设' : '覆盖值：$patternColor',
          trailing: Tooltip(
            message: '选择图案颜色',
            child: InkWell(
              key: const ValueKey<String>('background-pattern-color'),
              borderRadius: BorderRadius.circular(6),
              onTap: onPickPatternColor,
              child: Container(
                width: 44,
                height: 26,
                decoration: BoxDecoration(
                  color: patternColor.isEmpty
                      ? const Color(0xFFD0D5DD)
                      : WbColorUtils.fromHex(
                          patternColor,
                          fallback: const Color(0xFFD0D5DD),
                        ),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: onPickPatternColor == null
                        ? colors.border
                        : colors.icon,
                  ),
                ),
              ),
            ),
          ),
        ),
        SettingsTile(
          leading: Icon(LinearIcons.opacity, size: 18, color: colors.icon),
          title: '图案透明度',
          subtitle: '${(opacity * 100).round()}%',
          trailing: SizedBox(
            width: 240,
            child: Slider(
              key: const ValueKey<String>('background-opacity'),
              min: 0,
              max: 1,
              divisions: 20,
              value: opacity.clamp(0, 1),
              onChanged: onOpacityChanged,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            FilledButton.icon(
              key: const ValueKey<String>('background-apply-current'),
              onPressed: onApplyToCurrentPage,
              icon: const Icon(LinearIcons.check, size: 16),
              label: const Text('应用到当前页'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              key: const ValueKey<String>('background-apply-all'),
              onPressed: onApplyToAllPages,
              icon: const Icon(LinearIcons.duplicate, size: 16),
              label: const Text('应用到全部页'),
            ),
          ],
        ),
        SettingsHint(
          message: applyHint ??
              '应用后经 WbPageState.setBackground 写入页面（缩略图即时更新；'
                  '画布渲染器消费留 Wave 3 集成）',
        ),
      ],
    );
  }

  Widget _presetPreview(WbBackgroundPreset preset) {
    final Color base = WbColorUtils.fromHex(
      preset.color,
      fallback: const Color(0xFFFFFFFF),
    );
    final Color? line = preset.lineColor.isEmpty
        ? null
        : WbColorUtils.fromHex(
            preset.lineColor,
            fallback: const Color(0xFFD0D5DD),
          );
    final bool active = customColor.isEmpty && preset.id == selectedPresetId;
    return WbBackgroundPreview(
      type: preset.type,
      baseColor: base,
      patternColor: line,
      spacing: preset.spacing.toDouble(),
      opacity: active ? opacity : 1.0,
    );
  }
}

/// 背景预设卡片：预览 + 名称 + 选中勾。
class _BackgroundCard extends StatelessWidget {
  const _BackgroundCard({
    super.key,
    required this.checkKey,
    required this.label,
    required this.preview,
    required this.selected,
    required this.onTap,
    required this.reduceMotion,
    required this.highContrast,
  });

  final Key checkKey;
  final String label;
  final Widget preview;
  final bool selected;
  final VoidCallback? onTap;
  final bool reduceMotion;
  final bool highContrast;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final TextTheme text = Theme.of(context).textTheme;
    final BorderRadius radius = BorderRadius.circular(context.wbTheme.radius.m);
    return SizedBox(
      width: 128,
      child: AnimatedContainer(
        duration: reduceMotion ? Duration.zero : WbDuration.fast,
        curve: WbCurves.standard,
        decoration: BoxDecoration(
          color: colors.cardBackground,
          borderRadius: radius,
          border: Border.all(
            color: selected
                ? colors.primary
                : (highContrast ? colors.icon : colors.cardBorder),
            width: selected || highContrast ? 2 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  preview,
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          LinearIcons.check,
                          key: checkKey,
                          size: 14,
                          color: colors.primary,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 自定义背景色候选色板（14 色：浅色 9 + 深色 5）。
const List<Color> _kBackgroundSwatches = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFFF5F6F8),
  Color(0xFFFBF3E4),
  Color(0xFFE8F0FE),
  Color(0xFFE6F4EA),
  Color(0xFFFCE8E6),
  Color(0xFFFEF7E0),
  Color(0xFFEDE7F6),
  Color(0xFFE0F7FA),
  Color(0xFF263238),
  Color(0xFF1A1D21),
  Color(0xFF1E3A2F),
  Color(0xFF121417),
  Color(0xFF3E2723),
];

/// 显示背景色选择对话框；确认返回颜色，取消返回 null。
Future<Color?> showWbBackgroundColorDialog(
  BuildContext context, {
  Color initialColor = const Color(0xFFFFFFFF),
  String title = '自定义背景色',
}) {
  return showDialog<Color>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _ColorPickerDialog(initialColor: initialColor, title: title),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initialColor, required this.title});

  final Color initialColor;
  final String title;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  static final RegExp _hexPattern = RegExp(r'^#?[0-9a-fA-F]{6}$');

  late Color _selected = widget.initialColor;
  late final TextEditingController _controller =
      TextEditingController(text: _hexText(widget.initialColor));
  bool _error = false;

  static String _hexText(Color color) =>
      WbColorUtils.toHex(color).replaceFirst('#', '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onHexChanged(String value) {
    final String text = value.trim();
    final bool valid = _hexPattern.hasMatch(text);
    setState(() {
      _error = !valid;
      if (valid) {
        _selected = WbColorUtils.fromHex(text);
      }
    });
  }

  void _pick(Color color) {
    setState(() {
      _selected = color;
      _error = false;
      _controller.text = _hexText(color);
    });
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return AlertDialog(
      key: const ValueKey<String>('bg-color-dialog'),
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              key: const ValueKey<String>('bg-color-preview'),
              height: 40,
              decoration: BoxDecoration(
                color: _selected,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: colors.border),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final Color color in _kBackgroundSwatches)
                  Tooltip(
                    message: WbColorUtils.toHex(color),
                    child: InkWell(
                      key: ValueKey<String>(
                        'bg-swatch-${WbColorUtils.toHex(color)}',
                      ),
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _pick(color),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: color == _selected
                                ? colors.primary
                                : colors.border,
                            width: color == _selected ? 2 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('bg-hex-field'),
              controller: _controller,
              onChanged: _onHexChanged,
              decoration: const InputDecoration(
                labelText: '十六进制色值',
                hintText: '如 F5F6F8 或 #F5F6F8',
                prefixText: '# ',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_error)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '格式无效：请输入 6 位十六进制色值',
                  key: const ValueKey<String>('bg-hex-error'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('bg-color-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('bg-color-confirm'),
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
