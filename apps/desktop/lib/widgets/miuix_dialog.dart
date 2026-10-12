/// Miuix 风格的通用对话框外壳：标题 / 说明 / 自定义内容 + 底部按钮行。
///
/// 通过 [showWbMiuixDialog] 以普通路由弹出（Navigator.pop 返回结果），
/// 替代 Material `AlertDialog`；按钮 key 透传，便于测试定位。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// 对话框底部按钮。
class WbDialogAction {
  const WbDialogAction({
    required this.label,
    required this.onPressed,
    this.key,
    this.primary = false,
  });

  final String label;

  /// 为 null 时按钮禁用。
  final VoidCallback? onPressed;
  final Key? key;

  /// 主操作（强调色）。
  final bool primary;
}

/// 以路由弹出 Miuix 对话框；[builder] 返回 [WbMiuixDialog]。
Future<T?> showWbMiuixDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0x00000000),
    builder: (BuildContext dialogContext) => _WbMiuixDialogScope(
      dismissible: barrierDismissible,
      child: Builder(builder: builder),
    ),
  );
}

class _WbMiuixDialogScope extends InheritedWidget {
  const _WbMiuixDialogScope({required this.dismissible, required super.child});

  final bool dismissible;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WbMiuixDialogScope>()?.dismissible ?? true;

  @override
  bool updateShouldNotify(_WbMiuixDialogScope oldWidget) =>
      oldWidget.dismissible != dismissible;
}

/// Miuix 对话框内容。放在 [showWbMiuixDialog] 的 builder 中使用。
class WbMiuixDialog extends StatelessWidget {
  const WbMiuixDialog({
    super.key,
    this.title,
    this.summary,
    this.content,
    this.actions = const <WbDialogAction>[],
    this.width,
  });

  final String? title;
  final String? summary;
  final Widget? content;
  final List<WbDialogAction> actions;

  /// 内容区宽度；null 时由 Miuix 默认宽度决定。
  final double? width;

  @override
  Widget build(BuildContext context) {
    final bool dismissible = _WbMiuixDialogScope.of(context);
    return MiuixTheme(
      data: MiuixThemeData.of(Theme.of(context).brightness),
      child: MiuixPopupScope(
        establishRoot: true,
        child: Stack(
          children: <Widget>[
            MiuixOverlayDialog(
              show: true,
              renderInRootScaffold: false,
              title: title,
              summary: summary,
              onDismissRequest:
                  dismissible ? () => Navigator.of(context).maybePop() : null,
              content: Material(
                type: MaterialType.transparency,
                child: SizedBox(
                  width: width,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (content != null) content!,
                      if (content != null && actions.isNotEmpty)
                        const SizedBox(height: 16),
                      if (actions.isNotEmpty) _actionsRow(context),
                    ],
                  ),
                ),
              ),
            ),
            const MiuixPopupHost(),
          ],
        ),
      ),
    );
  }

  Widget _actionsRow(BuildContext context) {
    const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 12, vertical: 6);
    return Row(
      children: <Widget>[
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: Builder(
              builder: (BuildContext context) {
                final WbDialogAction action = actions[i];
                return MiuixButton(
                  key: action.key,
                  onPressed: action.onPressed,
                  minHeight: 40,
                  cornerRadius: 14,
                  insideMargin: padding,
                  colors: action.primary
                      ? MiuixButtonDefaults.buttonColorsPrimary(context)
                      : null,
                  child: MiuixText(action.label, maxLines: 1),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

/// Miuix 对话框内的单行输入框装饰（填充底色、无边框）。
InputDecoration wbMiuixFieldDecoration(BuildContext context, {String? label, String? hint}) {
  final MiuixThemeData theme = MiuixTheme.of(context);
  return InputDecoration(
    isDense: true,
    filled: true,
    labelText: label,
    hintText: hint,
    fillColor: theme.colors.secondaryContainer,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
  );
}
