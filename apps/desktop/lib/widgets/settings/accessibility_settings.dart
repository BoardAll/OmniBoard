/// 无障碍设置：减少动效 / 减少透明度 / 高对比度 / 字号缩放
/// （《主题与背景系统设计》§8.5 设置项表、§9 无障碍设计）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'settings_section.dart';

/// 无障碍设置（受控组件）。
///
/// 全部为开关 / 滑杆形式；状态由宿主（设置页）与 `WbThemeState` 衔接，
/// 未挂载 Provider 也可独立 pump。
class AccessibilitySettings extends StatelessWidget {
  const AccessibilitySettings({
    super.key,
    required this.reduceMotion,
    required this.onReduceMotionChanged,
    required this.reduceTransparency,
    required this.onReduceTransparencyChanged,
    required this.highContrast,
    required this.onHighContrastChanged,
    required this.fontScale,
    required this.onFontScaleChanged,
    this.minFontScale = 0.8,
    this.maxFontScale = 1.5,
  });

  /// 减少动效开关。
  final bool reduceMotion;

  /// 减少动效回调（null 时禁用；开启后界面过渡时长归零）。
  final ValueChanged<bool>? onReduceMotionChanged;

  /// 减少透明度开关。
  final bool reduceTransparency;

  /// 减少透明度回调（null 时禁用）。
  final ValueChanged<bool>? onReduceTransparencyChanged;

  /// 高对比度开关。
  final bool highContrast;

  /// 高对比度回调（null 时禁用）。
  final ValueChanged<bool>? onHighContrastChanged;

  /// 字号缩放（[minFontScale]–[maxFontScale]）。
  final double fontScale;

  /// 字号缩放回调（null 时禁用）。
  final ValueChanged<double>? onFontScaleChanged;

  /// 字号缩放下限（与 `WbAppearancePrefs.minFontScale` 一致：80%）。
  final double minFontScale;

  /// 字号缩放上限（与 `WbAppearancePrefs.maxFontScale` 一致：150%）。
  final double maxFontScale;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SettingsTile(
          leading: Icon(LinearIcons.refresh, size: 18, color: colors.icon),
          title: '减少动效',
          subtitle: '界面过渡与动画降为即时切换（文档 §9）',
          trailing: Switch(
            key: const ValueKey<String>('a11y-reduce-motion'),
            value: reduceMotion,
            onChanged: onReduceMotionChanged,
          ),
        ),
        SettingsTile(
          leading: Icon(LinearIcons.opacity, size: 18, color: colors.icon),
          title: '减少透明度',
          subtitle: '磨砂 / 半透明面板改用不透明底色',
          trailing: Switch(
            key: const ValueKey<String>('a11y-reduce-transparency'),
            value: reduceTransparency,
            onChanged: onReduceTransparencyChanged,
          ),
        ),
        SettingsTile(
          leading: Icon(LinearIcons.visible, size: 18, color: colors.icon),
          title: '高对比度',
          subtitle: '加强边框与前景对比，聚焦控件更醒目（文档 §9）',
          trailing: Switch(
            key: const ValueKey<String>('a11y-high-contrast'),
            value: highContrast,
            onChanged: onHighContrastChanged,
          ),
        ),
        SettingsTile(
          leading: Icon(LinearIcons.fontSize, size: 18, color: colors.icon),
          title: '字号缩放',
          subtitle: '缩放应用内文字（80%–150%）',
          trailing: SizedBox(
            width: 220,
            child: Slider(
              key: const ValueKey<String>('a11y-font-scale'),
              min: minFontScale,
              max: maxFontScale,
              divisions: 14,
              value: fontScale.clamp(minFontScale, maxFontScale),
              onChanged: onFontScaleChanged,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 28, bottom: 4),
          child: Row(
            children: <Widget>[
              Text(
                '当前字号：',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                '${(fontScale * 100).round()}%',
                key: const ValueKey<String>('a11y-font-scale-label'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              TextButton(
                key: const ValueKey<String>('a11y-font-scale-reset'),
                onPressed: onFontScaleChanged == null
                    ? null
                    : () => onFontScaleChanged!(1.0),
                child: const Text('重置为 100%'),
              ),
            ],
          ),
        ),
        const Divider(height: 20),
        const SettingsHint(
          message: '键盘导航：Tab / Shift+Tab 遍历全部可交互控件，Enter / 空格激活（文档 §9）。',
          icon: LinearIcons.select,
        ),
        const SettingsHint(
          message: '屏幕阅读器：主要控件均带语义标签；焦点环在高对比度下加粗显示。',
          icon: LinearIcons.comment,
        ),
      ],
    );
  }
}
