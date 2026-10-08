/// 元素尺寸设置对话框（波次 C：3D / 2D 元素宽高显示与调整）。
///
/// [showElementSizeDialog] 返回 `(宽, 高)`（世界单位）；取消返回 null。
/// 输入校验：空 / 非数字 / 非有限值 / <= 0 时确认按钮禁用。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_theme/theme.dart';

/// 显示元素尺寸设置对话框；确认返回 `(宽, 高)`，取消返回 null。
///
/// [width] / [height] 为当前尺寸（预填输入框，取整显示）。
Future<(double, double)?> showElementSizeDialog(
  BuildContext context, {
  required double width,
  required double height,
}) {
  return showDialog<(double, double)>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _ElementSizeDialog(width: width, height: height),
  );
}

/// 尺寸设置对话框（宽 / 高输入 + 校验 + 确认 / 取消）。
///
/// 控制器由本 State 持有并随对话框元素卸载而释放：`showDialog` 的
/// Future 在 `Navigator.pop` 时即恢复执行，而对话框仍在播放退出动画，
/// 若在 await 之后立刻释放控制器，退出帧中的文本框会引用已销毁对象
/// （与 `page_manager.dart` 重命名对话框同一约定）。
class _ElementSizeDialog extends StatefulWidget {
  const _ElementSizeDialog({required this.width, required this.height});

  /// 初始宽（世界单位）。
  final double width;

  /// 初始高（世界单位）。
  final double height;

  @override
  State<_ElementSizeDialog> createState() => _ElementSizeDialogState();
}

class _ElementSizeDialogState extends State<_ElementSizeDialog> {
  final TextEditingController _widthController = TextEditingController();
  final TextEditingController _heightController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _widthController.text = widget.width.round().toString();
    _heightController.text = widget.height.round().toString();
  }

  @override
  void dispose() {
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  /// 解析输入；空 / 非数字 / 非有限 / <= 0 返回 null。
  static double? _parse(TextEditingController controller) {
    final double? value = double.tryParse(controller.text.trim());
    if (value == null || !value.isFinite || value <= 0) {
      return null;
    }
    return value;
  }

  bool get _valid =>
      _parse(_widthController) != null && _parse(_heightController) != null;

  /// 提交（校验通过时 pop 结果；非法输入不响应）。
  void _confirm() {
    final double? width = _parse(_widthController);
    final double? height = _parse(_heightController);
    if (width == null || height == null) {
      return;
    }
    Navigator.of(context).pop((width, height));
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return AlertDialog(
      key: const ValueKey<String>('wb-size-dialog'),
      title: const Text('尺寸设置'),
      content: SizedBox(
        width: 320,
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('wb-size-width-field'),
                controller: _widthController,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '宽'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _confirm(),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                key: const ValueKey<String>('wb-size-height-field'),
                controller: _heightController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '高'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _confirm(),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('wb-size-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('wb-size-confirm'),
          style: FilledButton.styleFrom(backgroundColor: colors.primary),
          onPressed: _valid ? _confirm : null,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
