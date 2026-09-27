/// 全窗编辑器工作区（第三轮问题 2）：三区布局基础组件。
///
/// 参考 WPS 文档式交互：流程图 / 表格 / 思维导图在独立编辑页中全窗显示——
/// 左侧图形库 / 操作面板、中间最大化画布、右侧属性面板；顶部可选工具条行。
/// 页面 AppBar 已提供标题与取消 / 保存入口，本工作区不重复标题栏。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_theme/theme.dart';

/// 全窗编辑器工作区：顶部工具条（可选）+ 主体（通常为 [WbEditorPanes]）。
class WbEditorWorkspace extends StatelessWidget {
  /// 创建全窗工作区。
  const WbEditorWorkspace({super.key, this.toolbar, required this.child});

  /// 顶部工具条行（可选）。
  final Widget? toolbar;

  /// 主体内容（通常为 [WbEditorPanes]）。
  final Widget child;

  /// 左侧面板宽度（图形库 / 操作面板）。
  static const double leftPanelWidth = 176;

  /// 右侧面板宽度（属性面板）。
  static const double rightPanelWidth = 240;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Widget? toolbar = this.toolbar;
    return ColoredBox(
      color: colors.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (toolbar != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: toolbar,
            ),
            Divider(height: 1, thickness: 1, color: colors.cardBorder),
          ],
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 三区布局行：左面板（固定宽）/ 中间最大化画布 / 右面板（固定宽）。
///
/// 面板内容自行决定滚动策略（左图形库用 [ListView]、右属性用
/// [SingleChildScrollView]），中间区域直接吃满剩余空间。
class WbEditorPanes extends StatelessWidget {
  /// 创建三区布局。
  const WbEditorPanes({
    super.key,
    required this.left,
    required this.center,
    required this.right,
  });

  /// 左面板内容。
  final Widget left;

  /// 中间画布内容（最大化）。
  final Widget center;

  /// 右面板内容。
  final Widget right;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: WbEditorWorkspace.leftPanelWidth, child: left),
        VerticalDivider(width: 1, thickness: 1, color: colors.cardBorder),
        Expanded(child: center),
        VerticalDivider(width: 1, thickness: 1, color: colors.cardBorder),
        SizedBox(width: WbEditorWorkspace.rightPanelWidth, child: right),
      ],
    );
  }
}
