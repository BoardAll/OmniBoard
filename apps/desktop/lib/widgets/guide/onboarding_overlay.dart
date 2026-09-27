/// 新手引导浮层：分步高亮 + 提示卡片
/// （《用户手册与帮助文档设计》§3 新手引导）。
///
/// - [WbOnboardingOverlay] 为自包含浮层组件，可放入任意 `Stack` 或
///   对话框；步骤数据来自 [WbGuideContent.onboardingSteps]；
/// - [showOnboardingOverlay] 为模态入口（自包含、不依赖路由）；
/// - 交互：下一步 / 上一步 / 跳过 / ✕ 关闭 / 「不再提示」，
///   结果通过 [WbOnboardingResult] 回传（由宿主决定持久化）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'guide_content.dart';
import 'guide_icons.dart';
import 'shortcut_card.dart';

/// 引导结束方式。
enum WbOnboardingOutcome {
  /// 走完全部步骤并点击「完成」。
  completed,

  /// 中途跳过（跳过按钮 / ✕ 关闭）。
  skipped,
}

/// 引导结果（由 [WbOnboardingOverlay.onFinish] 回传）。
class WbOnboardingResult {
  const WbOnboardingResult({
    required this.outcome,
    this.dontShowAgain = false,
    this.lastStepIndex = 0,
  });

  /// 结束方式。
  final WbOnboardingOutcome outcome;

  /// 用户是否勾选「不再提示」。
  final bool dontShowAgain;

  /// 结束时所在步骤下标（从 0 开始）。
  final int lastStepIndex;

  /// 是否完成引导。
  bool get completed => outcome == WbOnboardingOutcome.completed;
}

/// 新手引导浮层（分步高亮 + 提示卡片）。
class WbOnboardingOverlay extends StatefulWidget {
  const WbOnboardingOverlay({
    super.key,
    this.steps = WbGuideContent.onboardingSteps,
    required this.onFinish,
    this.onStepChanged,
  }) : assert(steps.length > 0, '引导至少需要一个步骤');

  /// 引导步骤（默认对齐文档 §3.2 的 7 步）。
  final List<WbGuideStep> steps;

  /// 引导结束时回调（完成 / 跳过各触发一次）。
  final ValueChanged<WbOnboardingResult> onFinish;

  /// 步骤切换回调（下一步 / 上一步后的目标下标）。
  final ValueChanged<int>? onStepChanged;

  @override
  State<WbOnboardingOverlay> createState() => _WbOnboardingOverlayState();
}

class _WbOnboardingOverlayState extends State<WbOnboardingOverlay> {
  int _index = 0;
  bool _dontShowAgain = false;
  bool _finished = false;

  WbGuideStep get _step => widget.steps[_index];

  bool get _isFirst => _index == 0;

  bool get _isLast => _index >= widget.steps.length - 1;

  void _goNext() {
    if (_isLast) {
      _finish(WbOnboardingOutcome.completed);
      return;
    }
    setState(() => _index += 1);
    widget.onStepChanged?.call(_index);
  }

  void _goBack() {
    if (_isFirst) {
      return;
    }
    setState(() => _index -= 1);
    widget.onStepChanged?.call(_index);
  }

  void _skip() => _finish(WbOnboardingOutcome.skipped);

  void _finish(WbOnboardingOutcome outcome) {
    if (_finished) {
      return;
    }
    _finished = true;
    widget.onFinish(WbOnboardingResult(
      outcome: outcome,
      dontShowAgain: _dontShowAgain,
      lastStepIndex: _index,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      // 自包含：宿主可能无 Material 祖先（如对话框 / 纯 Stack），
      // 补一层透明 Material，供 Checkbox 等组件使用。
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          final WbGuideStep step = _step;
          final Rect hole =
              step.anchor.resolve(size.width, size.height);
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey<String>('wb-guide-mask'),
                  painter: _WbGuideMaskPainter(
                    hole: hole,
                    color: const Color(0xB3000000),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: hole,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey<String>('wb-guide-highlight'),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.primary, width: 2),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Align(
                    alignment: _cardAlignment(step.anchor),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 340),
                      child: SingleChildScrollView(
                        child: _StepCard(
                          step: step,
                          index: _index,
                          total: widget.steps.length,
                          dontShowAgain: _dontShowAgain,
                          onDontShowChanged: (bool value) =>
                              setState(() => _dontShowAgain = value),
                          onPrev: _goBack,
                          onNext: _goNext,
                          onSkip: _skip,
                          onClose: _skip,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 根据高亮区域计算提示卡片的对齐位置（尽量远离高亮区）。
Alignment _cardAlignment(WbGuideAnchor anchor) {
  final double cx = anchor.left + anchor.width / 2;
  final double cy = anchor.top + anchor.height / 2;
  final double x = cx > 0.55 ? -1.0 : (cx < 0.45 ? 1.0 : 0.0);
  final double y = cy > 0.55 ? -1.0 : (cy < 0.45 ? 1.0 : 0.0);
  return Alignment(x, y);
}

/// 步骤提示卡片。
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.step,
    required this.index,
    required this.total,
    required this.dontShowAgain,
    required this.onDontShowChanged,
    required this.onPrev,
    required this.onNext,
    required this.onSkip,
    required this.onClose,
  });

  final WbGuideStep step;
  final int index;
  final int total;
  final bool dontShowAgain;
  final ValueChanged<bool> onDontShowChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final VoidCallback onClose;

  bool get _isFirst => index == 0;

  bool get _isLast => index >= total - 1;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Container(
      key: const ValueKey<String>('wb-guide-card'),
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(wbGuideIcon(step.icon), size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${index + 1}/$total',
                key: const ValueKey<String>('wb-guide-progress'),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.icon),
              ),
              SizedBox(
                width: 30,
                height: 30,
                child: IconButton(
                  key: const ValueKey<String>('wb-guide-close'),
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  tooltip: '关闭引导',
                  onPressed: onClose,
                  icon: Icon(LinearIcons.close, color: colors.icon),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              step.message,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.icon),
            ),
          ),
          if (_isLast)
            Container(
              key: const ValueKey<String>('wb-guide-done-extra'),
              margin: const EdgeInsets.only(top: 10, right: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '常用快捷键',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final WbGuideShortcut shortcut
                      in WbGuideContent.highlightShortcuts)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              shortcut.label,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontSize: 11),
                            ),
                          ),
                          WbShortcutKeys(
                            keys: shortcut.resolvedKeys,
                            compact: true,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    '想快速体验？可在白板列表打开示例白板。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.icon,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Checkbox(
                key: const ValueKey<String>('wb-guide-dont-show'),
                value: dontShowAgain,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (bool? value) => onDontShowChanged(value ?? false),
              ),
              const SizedBox(width: 2),
              Text(
                '不再提示',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: colors.icon,
                ),
              ),
              const Spacer(),
              TextButton(
                key: const ValueKey<String>('wb-guide-skip'),
                onPressed: onSkip,
                child: const Text('跳过'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              if (!_isFirst)
                TextButton(
                  key: const ValueKey<String>('wb-guide-prev'),
                  onPressed: onPrev,
                  child: const Text('上一步'),
                ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey<String>('wb-guide-next'),
                onPressed: onNext,
                child: Text(_isLast ? '完成' : '下一步'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 引导遮罩：全屏半透明色块中挖出高亮孔洞。
class _WbGuideMaskPainter extends CustomPainter {
  const _WbGuideMaskPainter({required this.hole, required this.color});

  final Rect hole;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Path mask = Path()..addRect(Offset.zero & size);
    final Path holePath = Path()
      ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(12)));
    final Path combined = Path.combine(PathOperation.difference, mask, holePath);
    canvas.drawPath(combined, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _WbGuideMaskPainter oldDelegate) {
    return oldDelegate.hole != hole || oldDelegate.color != color;
  }
}

/// 以模态弹层展示新手引导（自包含，不依赖路由）。
///
/// 返回引导结果；用户点击「完成」为 [WbOnboardingOutcome.completed]，
/// 「跳过 / ✕」为 [WbOnboardingOutcome.skipped]。
Future<WbOnboardingResult> showOnboardingOverlay(
  BuildContext context, {
  List<WbGuideStep> steps = WbGuideContent.onboardingSteps,
}) {
  return showGeneralDialog<WbOnboardingResult>(
    context: context,
    barrierDismissible: false,
    barrierLabel: '新手引导',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    transitionBuilder: (
      BuildContext ctx,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
    ) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
    pageBuilder: (
      BuildContext ctx,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
    ) {
      return WbOnboardingOverlay(
        steps: steps,
        onFinish: (WbOnboardingResult result) =>
            Navigator.of(ctx).pop(result),
      );
    },
  ).then((WbOnboardingResult? result) {
    return result ??
        const WbOnboardingResult(outcome: WbOnboardingOutcome.skipped);
  });
}
