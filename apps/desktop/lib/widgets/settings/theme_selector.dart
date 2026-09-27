/// 主题选择器：9 个内置主题（+ 自定义）预览卡片、跟随系统、图标包
/// 与导入 / 导出入口（《主题与背景系统设计》§8.1 / §8.3 / §8.4 / §10.2）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import 'settings_section.dart';

/// 主题卡片网格（含跟随系统开关、图标包、导入 / 导出入口）。
///
/// 受控组件：状态全部由构造参数传入、变更通过回调上抛，未挂载
/// Provider 时也可独立 pump（组件测试 / 独立预览）。
class ThemeSelector extends StatelessWidget {
  const ThemeSelector({
    super.key,
    required this.themes,
    required this.selectedId,
    required this.onSelect,
    this.effectiveThemeId,
    this.followSystem = false,
    this.onFollowSystemChanged,
    this.iconStyleId = 'linear',
    this.onIconStyleChanged,
    this.onImport,
    this.onExport,
    this.reduceMotion = false,
    this.highContrast = false,
  });

  /// 可选主题（内置 + 自定义，顺序与 `WbThemeManager.available` 一致）。
  final List<WbThemeData> themes;

  /// 当前已应用主题 id。
  final String selectedId;

  /// 生效主题 id（跟随系统时可能不同于 [selectedId]；用于打标）。
  final String? effectiveThemeId;

  /// 点击卡片即时应用主题。
  final ValueChanged<String> onSelect;

  /// 跟随系统深浅色开关状态。
  final bool followSystem;

  /// 跟随系统开关回调（null 时开关禁用）。
  final ValueChanged<bool>? onFollowSystemChanged;

  /// 图标包 id（`WbIconStyle.id`，5 种）。
  final String iconStyleId;

  /// 图标包切换回调（null 时禁用选择）。
  final ValueChanged<String>? onIconStyleChanged;

  /// 导入主题包回调（null 时按钮禁用并提示）。
  final VoidCallback? onImport;

  /// 导出当前主题回调（null 时按钮禁用并提示）。
  final VoidCallback? onExport;

  /// 减少动效（卡片过渡时长归零）。
  final bool reduceMotion;

  /// 高对比度（卡片描边加强）。
  final bool highContrast;

  /// 内置主题描述（文档 §4 / §10.2；未知 id 视为自定义主题）。
  static String descriptionFor(String themeId) => switch (themeId) {
        'clean-professional' => '默认主题，适合大多数场景',
        'dark-night' => '深色界面，夜间与低光环境',
        'blackboard' => '课堂黑板质感，白粉笔联动',
        'greenboard' => '护眼草绿板，白字书写',
        'minimal' => '极简黑白，专注内容本身',
        'hand-drawn' => '米黄纸张与手绘质感',
        'cyber' => '深色霓虹，科技感界面',
        'kids' => '明快彩色，适合儿童使用',
        'enterprise' => '严谨稳重的商务配色',
        _ => '自定义主题',
      };

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SettingsTile(
          leading: Icon(LinearIcons.darkMode, size: 18, color: colors.icon),
          title: '跟随系统深浅色',
          subtitle: _followSystemCaption(),
          trailing: Switch(
            key: const ValueKey<String>('theme-follow-system'),
            value: followSystem,
            onChanged: onFollowSystemChanged,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Tooltip(
              message: onImport == null
                  ? '平台文件选择通道接入后开放（Wave 4）'
                  : '导入 .zip / JSON 主题包',
              child: OutlinedButton.icon(
                key: const ValueKey<String>('theme-import'),
                onPressed: onImport,
                icon: const Icon(LinearIcons.import, size: 16),
                label: const Text('导入主题包'),
              ),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: onExport == null
                  ? '平台文件保存通道接入后开放（Wave 4）'
                  : '导出当前主题（.zip / JSON）',
              child: OutlinedButton.icon(
                key: const ValueKey<String>('theme-export'),
                onPressed: onExport,
                icon: const Icon(LinearIcons.export, size: 16),
                label: const Text('导出当前主题'),
              ),
            ),
          ],
        ),
        SettingsTile(
          leading: Icon(LinearIcons.grid, size: 18, color: colors.icon),
          title: '图标包',
          subtitle: '主题包携带的图标风格（文档 §3.5，共 5 种）',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final WbIconStyle style in WbIconStyle.values)
              ChoiceChip(
                key: ValueKey<String>('icon-style-${style.id}'),
                label: Text(style.displayName),
                selected: style.id == iconStyleId,
                onSelected: onIconStyleChanged == null
                    ? null
                    : (bool _) => onIconStyleChanged!.call(style.id),
              ),
          ],
        ),
        SettingsTile(
          leading: Icon(LinearIcons.text, size: 18, color: colors.icon),
          title: '字体',
          subtitle: '系统默认字体；自定义字体包 Wave 4 接入（字号缩放见「无障碍」）',
        ),
        const Divider(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final WbThemeData theme in themes)
              _ThemeCard(
                theme: theme,
                selected: theme.id == selectedId,
                effective:
                    effectiveThemeId != null && theme.id == effectiveThemeId,
                description: descriptionFor(theme.id),
                onTap: () => onSelect(theme.id),
                reduceMotion: reduceMotion,
                highContrast: highContrast,
              ),
          ],
        ),
      ],
    );
  }

  String _followSystemCaption() {
    if (!followSystem) {
      return '开启后系统为暗色时自动切换到深色主题';
    }
    final String id = effectiveThemeId ?? '';
    for (final WbThemeData theme in themes) {
      if (theme.id == id) {
        return '系统暗色时自动使用「${theme.name}」';
      }
    }
    return '跟随系统深浅色（生效主题取决于系统亮度）';
  }
}

/// 主题预览块：用主题自身颜色绘制微缩界面（文档 §10.2）。
class WbThemePreview extends StatelessWidget {
  const WbThemePreview({super.key, required this.theme, this.height = 84});

  /// 被预览的主题。
  final WbThemeData theme;

  /// 预览高度。
  final double height;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors c = theme.colors;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: c.canvas),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                height: 16,
                color: c.surface,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: c.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const Spacer(),
                    _bar(c.border, 22, 4),
                    const SizedBox(width: 4),
                    _bar(c.border, 12, 4),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 16,
              bottom: 0,
              width: 24,
              child: ColoredBox(color: c.surface.withValues(alpha: 0.92)),
            ),
            Positioned(
              left: 34,
              top: 28,
              child: _bar(c.icon.withValues(alpha: 0.75), 72, 5),
            ),
            Positioned(
              left: 34,
              top: 40,
              child: _bar(c.icon.withValues(alpha: 0.5), 48, 5),
            ),
            Positioned(
              left: 34,
              top: 52,
              child: _bar(c.icon.withValues(alpha: 0.3), 60, 5),
            ),
            Positioned(
              left: 34,
              top: 64,
              child: _bar(c.primary, 26, 8, radius: 4),
            ),
            Positioned(
              right: 10,
              top: 26,
              child: Container(
                width: 44,
                height: 24,
                decoration: BoxDecoration(
                  color: c.elevated,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: c.border),
                ),
                child: Center(child: _bar(c.primary, 18, 5)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(Color color, double width, double height, {double radius = 2.5}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 主题卡片：预览 + 名称 + 描述 + 选中 / 生效标记。
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.theme,
    required this.selected,
    required this.effective,
    required this.description,
    required this.onTap,
    required this.reduceMotion,
    required this.highContrast,
  });

  final WbThemeData theme;
  final bool selected;
  final bool effective;
  final String description;
  final VoidCallback onTap;
  final bool reduceMotion;
  final bool highContrast;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final TextTheme text = Theme.of(context).textTheme;
    final BorderRadius radius = BorderRadius.circular(context.wbTheme.radius.m);
    return SizedBox(
      width: 216,
      child: AnimatedContainer(
        key: ValueKey<String>('theme-card-${theme.id}'),
        duration: reduceMotion ? Duration.zero : WbDuration.medium,
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
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  WbThemePreview(theme: theme),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          theme.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          LinearIcons.check,
                          key: ValueKey<String>('theme-card-check-${theme.id}'),
                          size: 16,
                          color: colors.primary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: colors.icon),
                  ),
                  if (effective)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        key: ValueKey<String>('theme-card-effective-${theme.id}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '跟随系统生效',
                          style: TextStyle(fontSize: 10, color: colors.primary),
                        ),
                      ),
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

/// 显示主题包导入对话框；校验通过返回主题包，取消 / 校验失败返回 null。
///
/// 文件选择（.zip）依赖平台文件选择通道（Wave 4 接入）；当前支持粘贴
/// 主题包 JSON 完成「校验 → 预览 → 导入」（文档 §8.3 步骤 4–7）。
Future<WbThemePack?> showWbThemeImportDialog(BuildContext context) {
  return showDialog<WbThemePack>(
    context: context,
    builder: (BuildContext dialogContext) => const _ThemeImportDialog(),
  );
}

/// 显示主题导出对话框（占位：展示主题 JSON）。
///
/// `.zip` 保存依赖平台文件保存通道（Wave 4 接入），文档 §8.4 步骤 4–5。
Future<void> showWbThemeExportDialog(
  BuildContext context,
  WbThemeData theme,
) {
  final String json = WbThemeLoader.serialize(theme, pretty: true);
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      final WbThemeColors colors = dialogContext.wbColors;
      return AlertDialog(
        key: const ValueKey<String>('theme-export-dialog'),
        title: Text('导出主题「${theme.name}」'),
        content: SizedBox(
          width: 520,
          height: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '保存 .zip 依赖平台文件保存通道（Wave 4 接入）；'
                '当前可预览主题 JSON 并自行保存。',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.hover,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: colors.border),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      json,
                      key: const ValueKey<String>('theme-export-json'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('theme-export-close'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

class _ThemeImportDialog extends StatefulWidget {
  const _ThemeImportDialog();

  @override
  State<_ThemeImportDialog> createState() => _ThemeImportDialogState();
}

class _ThemeImportDialogState extends State<_ThemeImportDialog> {
  final TextEditingController _controller = TextEditingController();
  WbThemePack? _parsed;
  bool _showError = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {
      _parsed = WbThemeLoader.parsePack(value);
      _showError = false;
    });
  }

  void _confirm() {
    final WbThemePack? pack = WbThemeLoader.parsePack(_controller.text);
    if (pack == null) {
      setState(() => _showError = true);
      return;
    }
    Navigator.of(context).pop(pack);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return AlertDialog(
      key: const ValueKey<String>('theme-import-dialog'),
      title: const Text('导入主题包'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '从 .zip 文件导入依赖平台文件选择通道（Wave 4 接入）；'
              '当前可粘贴主题包 JSON 完成校验与导入。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey<String>('theme-import-field'),
              controller: _controller,
              onChanged: _onChanged,
              minLines: 4,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText: '{"id": "my-pack", "name": "我的主题包", "themes": [...]}',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_showError)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '格式无效：需为含 themes 数组的主题包 JSON',
                  key: const ValueKey<String>('theme-import-error'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (_parsed != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: <Widget>[
                    Icon(LinearIcons.check, size: 14, color: colors.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '已识别「${_parsed!.name}」，共 ${_parsed!.themes.length} 个主题',
                        key: const ValueKey<String>('theme-import-preview'),
                        style: TextStyle(fontSize: 12, color: colors.primary),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('theme-import-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('theme-import-confirm'),
          onPressed: _confirm,
          child: const Text('校验并导入'),
        ),
      ],
    );
  }
}
