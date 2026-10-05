/// 页面背景设置对话框（桌面）：完整背景入口——预设 / 自定义色 /
/// 图案参数 / 背景图片。
///
/// 由编辑页经 `PageManager.onEditBackground` 注入（共享版页面管理器
/// 不内置平台专有对话框）。结果类型为共享的
/// [WbPageBackgroundEditResult]。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_canvas/widgets/page_manager.dart'
    show WbPageBackgroundEditResult;
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';
import 'package:whiteboard_windows/whiteboard_windows.dart';

import 'settings/background_picker.dart';

/// 打开页面背景对话框；返回编辑结果（null = 取消）。
Future<WbPageBackgroundEditResult?> showWbDesktopPageBackgroundDialog(
  BuildContext context,
  WbPage page,
) {
  return showDialog<WbPageBackgroundEditResult>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _WbDesktopPageBackgroundDialog(initial: page.background),
  );
}

/// 页面背景设置对话框：复用 [BackgroundPicker]（预设网格 / 自定义色 /
/// 图案间距 / 图案色 / 透明度），并补充背景图片选择入口。
class _WbDesktopPageBackgroundDialog extends StatefulWidget {
  const _WbDesktopPageBackgroundDialog({required this.initial});

  /// 当前页面背景对象（可能为空 Map）。
  final Map<String, dynamic> initial;

  @override
  State<_WbDesktopPageBackgroundDialog> createState() =>
      _WbDesktopPageBackgroundDialogState();
}

class _WbDesktopPageBackgroundDialogState
    extends State<_WbDesktopPageBackgroundDialog> {
  /// 已选预设 id（自定义色非空时不生效）。
  late String _presetId;

  /// 自定义背景色 `#RRGGBB`（空串 = 未选）。
  late String _customColor;

  /// 图案间距覆盖（0 = 跟随预设）。
  late int _spacing;

  /// 图案色覆盖 `#RRGGBB`（空串 = 跟随预设）。
  late String _patternColor;

  /// 图案透明度（0–1）。
  late double _opacity;

  /// 背景图片绝对路径（空串 = 未选）。
  late String _imagePath;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic> initial = widget.initial;
    final bool custom = initial['custom'] == true;
    _customColor = custom ? (initial['baseColor'] as String? ?? '') : '';
    final String presetId = initial['preset'] as String? ??
        initial['id'] as String? ??
        'whiteboard';
    _presetId = WbBackgroundService.presetById(presetId)?.id ?? 'whiteboard';
    _spacing = (initial['spacing'] as num?)?.toInt() ?? 0;
    _patternColor = initial['patternColor'] as String? ?? '';
    _opacity = ((initial['opacity'] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0);
    _imagePath = initial['imagePath'] as String? ?? '';
  }

  void _onPresetSelected(String id) {
    final WbBackgroundPreset? preset = WbBackgroundService.presetById(id);
    if (preset == null) {
      return;
    }
    setState(() {
      _customColor = '';
      _presetId = preset.id;
      // 切换预设时图案覆盖参数复位为该预设自身参数（避免跨预设残留）。
      _spacing = preset.spacing;
      _patternColor = preset.lineColor;
      _opacity = 1;
    });
  }

  Future<void> _pickCustomColor() async {
    final Color? color = await showWbBackgroundColorDialog(
      context,
      initialColor: _customColor.isEmpty
          ? const Color(0xFFFFFFFF)
          : WbColorUtils.fromHex(
              _customColor,
              fallback: const Color(0xFFFFFFFF),
            ),
    );
    if (!mounted || color == null) {
      return;
    }
    setState(() => _customColor = WbColorUtils.toHex(color));
  }

  Future<void> _pickPatternColor() async {
    final Color? color = await showWbBackgroundColorDialog(
      context,
      title: '图案颜色',
      initialColor: _patternColor.isEmpty
          ? const Color(0xFFD0D5DD)
          : WbColorUtils.fromHex(
              _patternColor,
              fallback: const Color(0xFFD0D5DD),
            ),
    );
    if (!mounted || color == null) {
      return;
    }
    setState(() => _patternColor = WbColorUtils.toHex(color));
  }

  Future<void> _pickImage() async {
    final String? path = await WindowsWindowPlugin().openImageFile();
    if (!mounted || path == null || path.isEmpty) {
      return;
    }
    setState(() => _imagePath = path);
  }

  /// 组装完整背景对象（镜像 `WbThemeState.backgroundJsonOf` 的存储形态）。
  Map<String, dynamic> _buildBackground() {
    if (_customColor.isNotEmpty) {
      final Color color = WbColorUtils.fromHex(
        _customColor,
        fallback: const Color(0xFFFFFFFF),
      );
      return <String, dynamic>{
        'id': 'custom',
        'name': '自定义背景',
        'pattern': 'solid',
        'baseColor': _customColor,
        'patternColor': '',
        'spacing': 0,
        'dark': !WbColorUtils.isLight(color),
        'custom': true,
        if (_imagePath.isNotEmpty) 'imagePath': _imagePath,
      };
    }
    final WbBackgroundPreset preset =
        WbBackgroundService.presetById(_presetId) ??
            WbBackgroundService.builtinPresets.first;
    final Map<String, dynamic> json = preset.toBackgroundJson();
    if (preset.type != 'solid') {
      if (_spacing > 0) {
        json['spacing'] = _spacing;
      }
      if (_patternColor.isNotEmpty) {
        json['patternColor'] = _patternColor;
      }
    }
    if (_opacity < 1) {
      json['opacity'] = _opacity;
    }
    if (_imagePath.isNotEmpty) {
      json['imagePath'] = _imagePath;
    }
    return json;
  }

  void _apply({required bool all}) {
    Navigator.of(context).pop(
      WbPageBackgroundEditResult(
        background: _buildBackground(),
        applyToAll: all,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('page-bg-dialog'),
      title: const Text('页面背景'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              BackgroundPicker(
                presets: WbBackgroundService.builtinPresets,
                selectedPresetId: _presetId,
                customColor: _customColor,
                onPresetSelected: _onPresetSelected,
                onPickCustomColor: _pickCustomColor,
                followTheme: false,
                spacing: _spacing,
                onSpacingChanged: (int value) =>
                    setState(() => _spacing = value),
                patternColor: _patternColor,
                onPickPatternColor: _pickPatternColor,
                opacity: _opacity,
                onOpacityChanged: (double value) =>
                    setState(() => _opacity = value),
                onApplyToCurrentPage: () => _apply(all: false),
                onApplyToAllPages: () => _apply(all: true),
                applyHint: '「应用到当前页」写入本页背景；「应用到全部页」写入全部页面。'
                    '图案间距 0 / 图案色空串表示跟随预设。',
              ),
              const Divider(height: 28),
              _buildImageTile(context),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('page-bg-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 背景图片入口（问题 2）：选择 / 更换 / 清除。
  Widget _buildImageTile(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '背景图片',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Icon(LinearIcons.image, size: 18, color: colors.icon),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _imagePath.isEmpty ? '未选择（平铺封面显示，叠加于底色之上）' : _imagePath,
                key: const ValueKey<String>('page-bg-image-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const ValueKey<String>('page-bg-image-pick'),
              onPressed: _pickImage,
              child: Text(_imagePath.isEmpty ? '选择图片' : '更换图片'),
            ),
            if (_imagePath.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey<String>('page-bg-image-clear'),
                onPressed: () => setState(() => _imagePath = ''),
                child: const Text('清除'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
