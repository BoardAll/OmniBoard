/// 退出透明批注模式的三选项弹窗（《透明批注模式技术方案》§5.4）。
///
/// 交互：`[保存到白板] / [丢弃] / [继续保留]` 纵向排列；保存中禁用全部
/// 选项并显示进度；保存失败时展示错误文案，弹窗保持可见以便重试。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_theme/theme.dart';

import 'annotation_controller.dart';

/// 退出弹窗（自带全屏遮罩，挂载于覆盖层 Stack 的顶层）。
class WbAnnotationExitDialog extends StatelessWidget {
  const WbAnnotationExitDialog({
    super.key,
    required this.onChoice,
    this.strokeCount = 0,
    this.saving = false,
    this.errorText = '',
  });

  /// 用户选择某个选项后回调（由控制器编排后续动作）。
  final ValueChanged<WbAnnotationExitChoice> onChoice;

  /// 当前批注笔迹数量（提示“当前有 N 条批注”）。
  final int strokeCount;

  /// 是否正在执行“保存到白板”。
  final bool saving;

  /// 保存失败等错误文案（空串表示无错误）。
  final String errorText;

  /// 弹窗主体 key。
  static const ValueKey<String> dialogKey =
      ValueKey<String>('annotation-exit-dialog');

  /// 指定选项按钮的 key。
  static ValueKey<String> choiceKey(WbAnnotationExitChoice choice) =>
      ValueKey<String>('annotation-exit-${choice.name}');

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Material(
      color: Colors.black38,
      child: Center(
        child: Material(
          key: dialogKey,
          color: colors.cardBackground,
          elevation: 12,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 320,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.cardBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '退出透明批注模式',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colors.toolbarIcon,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  strokeCount > 0
                      ? '批注内容如何处理？（当前 $strokeCount 条批注）'
                      : '批注内容如何处理？',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.toolbarIcon.withValues(alpha: 0.8),
                  ),
                ),
                if (errorText.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    errorText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.red,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                for (final WbAnnotationExitChoice choice
                    in WbAnnotationExitChoice.values) ...<Widget>[
                  _ChoiceButton(
                    key: choiceKey(choice),
                    label: choice.label,
                    description: choice.description,
                    primary: choice == WbAnnotationExitChoice.saveToBoard,
                    busy:
                        saving && choice == WbAnnotationExitChoice.saveToBoard,
                    onTap: saving ? null : () => onChoice(choice),
                  ),
                  if (choice != WbAnnotationExitChoice.values.last)
                    const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个选项按钮（全宽；“保存到白板”为主按钮风格）。
class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    super.key,
    required this.label,
    required this.description,
    required this.primary,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool primary;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    final double alpha = onTap == null ? 0.4 : 1;
    final Color titleColor = primary ? colors.toolbarActive : colors.toolbarIcon;
    return Opacity(
      opacity: alpha,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: primary
                ? colors.toolbarActive.withValues(alpha: 0.12)
                : colors.cardHover.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: primary ? colors.toolbarActive : colors.cardBorder,
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: titleColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.toolbarIcon.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.toolbarActive,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
