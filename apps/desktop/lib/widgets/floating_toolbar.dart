/// 底部浮动主工具栏：声明式配置（[WbMainToolbar]）+ 响应式溢出折叠 +
/// 撤销 / 重做 / 更多 + 快捷键角标 + 上下文工具栏切换。
///
/// 行为对齐《可扩展工具栏设计 v1.0》：
/// - §3.1：9 类绘图工具（选择 / 抓手 / 画笔 / 荧光笔 / 橡皮擦 / 便签 /
///   文本 / 形状 / 图片），快捷键角标仅作提示、不注册全局快捷键；
/// - §3.4：撤销 / 重做接线到 [WbBoardState]；
/// - §4：有选中对象时切换为上下文工具栏（[WbContextToolbar]），无选中
///   恢复默认工具集（"工具栏区切换"布局，浮层布局见 [showWbContextToolbar]）；
/// - §5：更多 → 设置、快捷键；
/// - §17.2：溢出条目折叠入"更多"菜单，点击空白处收起（PopupMenu 默认）；
/// - §18：高度 40 / 按钮 32 / 图标 20 / 圆角 / 出现 120ms / 消失 100ms。
///
/// 画布联动偏差：画布控制器（`WbCanvasController`）由 `CanvasView` 内部
/// 持有、对工具栏不可达；本组件维护自身选择状态并输出 [onToolChanged] /
/// [onCommand] 回调，由宿主接线到画布（见实现报告偏差清单）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../state/board_state.dart';
import '../state/selection_state.dart';
import 'toolbar/color_picker_popover.dart';
import 'toolbar/context_toolbar.dart';
import 'toolbar/toolbar_config.dart';
import 'toolbar/toolbar_item.dart';

/// 底部浮动工具栏。
///
/// 全部参数可选、带默认值：`const FloatingToolbar()` 保持既有调用方式可用。
class FloatingToolbar extends StatefulWidget {
  const FloatingToolbar({
    super.key,
    this.initialTool = WbToolbarToolIds.select,
    this.activeTool,
    this.onToolChanged,
    this.onCommand,
    this.onUndo,
    this.onRedo,
    this.contextTarget,
    this.contextTypeResolver,
    this.showContextToolbar = true,
    this.onPendingStyleChanged,
  });

  /// 初始高亮工具（未受控模式下使用）。
  final String initialTool;

  /// 受控高亮工具（非 null 时组件不再自管选择态）。
  final String? activeTool;

  /// 工具切换回调（宿主接线到画布；当前画布控制器不可达，见文件头偏差）。
  final ValueChanged<String>? onToolChanged;

  /// 统一命令回调（"更多 → 设置 / 快捷键"与上下文命令出口）。
  final ValueChanged<WbToolbarCommand>? onCommand;

  /// 撤销回调（null 时回落 [WbBoardState.undo]，兼容旧调用）。
  final VoidCallback? onUndo;

  /// 重做回调（null 时回落 [WbBoardState.redo]，兼容旧调用）。
  final VoidCallback? onRedo;

  /// 上下文目标覆盖：非 null 时直接使用（不读取选区 Provider；
  /// 测试与嵌入场景用）。null 时从 [WbSelectionState] 解析。
  final WbContextTarget? contextTarget;

  /// 单元素类型解析器（id → 上下文类型；null → 单选显示通用集）。
  final WbContextTypeResolver? contextTypeResolver;

  /// 是否启用"有选中 → 上下文工具栏"切换。
  final bool showContextToolbar;

  /// 上下文工具栏进入 / 退出"选色再点表面"待应用状态的回调。
  final ValueChanged<WbPendingStyle?>? onPendingStyleChanged;

  @override
  State<FloatingToolbar> createState() => _FloatingToolbarState();
}

class _FloatingToolbarState extends State<FloatingToolbar> {
  late String _active = widget.initialTool;

  /// 当前高亮工具（受控优先）。
  String get _resolvedActive => widget.activeTool ?? _active;

  /// 选中工具：受控模式下只回调；否则先更新本地高亮。
  void _selectTool(String id) {
    if (widget.activeTool == null && _active != id) {
      setState(() => _active = id);
    }
    widget.onToolChanged?.call(id);
  }

  /// 组首标记（组间渲染额外间距）。
  bool _startsGroup(String id) {
    for (final WbToolbarGroup group in WbMainToolbar.groups) {
      if (group.items.isNotEmpty && group.items.first.id == id) {
        return true;
      }
    }
    return false;
  }

  // ---- Provider 容错读取（演示模式 / 无 Provider 不崩溃）----------------------

  WbSelectionState? _maybeSelection(BuildContext context) {
    try {
      return context.watch<WbSelectionState>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  WbBoardState? _maybeBoard(BuildContext context) {
    try {
      return context.watch<WbBoardState>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// 解析上下文目标（显式覆盖 → 选区 Provider → 无选中）。
  WbContextTarget _resolveTarget(BuildContext context) {
    final WbContextTarget? override = widget.contextTarget;
    if (override != null) {
      return override;
    }
    final WbSelectionState? selection = _maybeSelection(context);
    if (selection == null || selection.isEmpty) {
      return const WbContextTarget(type: WbContextTargetType.none, count: 0);
    }
    return WbContextTarget.fromSelection(
      selection.ids,
      resolver: widget.contextTypeResolver,
    );
  }

  // ---- 构建 ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbContextTarget target = _resolveTarget(context);
    final bool contextMode = widget.showContextToolbar &&
        target.type != WbContextTargetType.none &&
        !target.isEmpty;

    final Widget content = contextMode
        ? WbContextToolbar(
            key: const ValueKey<String>('wb-toolbar-context-content'),
            target: target,
            selfDecorated: false,
            onCommand: widget.onCommand,
            onPendingChanged: widget.onPendingStyleChanged,
          )
        : _buildMainContent(context);

    return Container(
      key: const ValueKey<String>('wb-floating-toolbar'),
      height: WbToolbarMetrics.barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: wbToolbarSurfaceDecoration(colors),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 120),
        reverseDuration: const Duration(milliseconds: 100),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(
          key: ValueKey<String>(contextMode ? 'wb-context' : 'wb-main'),
          child: content,
        ),
      ),
    );
  }

  /// 主工具行：9 类工具 + 固定尾部（撤销 / 重做 / 更多）。
  Widget _buildMainContent(BuildContext context) {
    final WbBoardState? board = _maybeBoard(context);
    final String active = _resolvedActive;

    final List<WbToolbarItemEntry> entries = <WbToolbarItemEntry>[
      for (final WbToolbarItem item in WbMainToolbar.tools)
        WbToolbarItemEntry(
          id: item.id,
          label: item.label,
          icon: item.icon,
          shortcut: item.shortcut,
          active: item.id == active,
          startsGroup: _startsGroup(item.id),
          onTap: () => _selectTool(item.id),
        ),
    ];

    return WbToolbarRow(
      items: entries,
      // 容器已含 8+8 水平内边距（LayoutBuilder 约束已扣除），预算传 0。
      padding: 0,
      fixedExtent:
          WbToolbarMetrics.separatorExtent + 3 * WbToolbarMetrics.itemExtent,
      fixedBuilder: (
        BuildContext context,
        List<WbToolbarItemEntry> hidden,
      ) {
        return <Widget>[
          _fixedButton(
            key: const ValueKey<String>('wb-toolbar-edit.undo'),
            icon: LinearIcons.undo,
            tooltip: '撤销',
            enabled: widget.onUndo != null || board != null,
            onTap: () {
              final VoidCallback? undo = widget.onUndo;
              if (undo != null) {
                undo();
              } else {
                board?.undo();
              }
            },
          ),
          _fixedButton(
            key: const ValueKey<String>('wb-toolbar-edit.redo'),
            icon: LinearIcons.redo,
            tooltip: '重做',
            enabled: widget.onRedo != null || board != null,
            onTap: () {
              final VoidCallback? redo = widget.onRedo;
              if (redo != null) {
                redo();
              } else {
                board?.redo();
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: WbToolbarMoreButton(
              buttonKey: const ValueKey<String>('wb-toolbar-more'),
              active: hidden.isNotEmpty,
              items: <WbToolbarMoreMenuEntry>[
                for (final WbToolbarItemEntry entry in hidden)
                  entry.toMenuEntry(),
                WbToolbarMoreMenuEntry(
                  value: WbToolbarToolIds.settings,
                  label: '设置',
                  icon: LinearIcons.settings,
                  keySuffix: WbToolbarToolIds.settings,
                  dividerBefore: hidden.isNotEmpty,
                ),
                const WbToolbarMoreMenuEntry(
                  value: WbToolbarToolIds.shortcuts,
                  label: '快捷键',
                  icon: LinearIcons.grid,
                  keySuffix: WbToolbarToolIds.shortcuts,
                ),
              ],
              onSelected: _handleMoreSelected,
            ),
          ),
        ];
      },
    );
  }

  /// 固定尾部按钮（撤销 / 重做）。
  Widget _fixedButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: WbToolbarIconButton(
        key: key,
        icon: icon,
        tooltip: tooltip,
        enabled: enabled,
        onTap: onTap,
      ),
    );
  }

  /// "更多"菜单分发：折叠条目 → 选择工具；动作 id → 统一命令。
  void _handleMoreSelected(Object value) {
    if (value is WbToolbarItemEntry) {
      value.onTap();
      return;
    }
    if (value is String) {
      final String id = value;
      if (WbMainToolbar.toolById(id) != null) {
        _selectTool(id);
        return;
      }
      widget.onCommand?.call(WbToolbarCommand(id));
    }
  }
}
