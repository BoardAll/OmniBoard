/// 工具栏原子组件：图标按钮（含快捷键角标 / 色点）、分隔线、
/// 响应式溢出行 [WbToolbarRow]、"更多"菜单按钮与共享容器外观。
///
/// 视觉规格对齐《可扩展工具栏设计 v1.0》§18.1：按钮 32×32、图标 20、
/// 间距 4、按钮圆角 8、激活背景主色 12%；
/// 悬停动效 80ms（§18.4）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'toolbar_config.dart';

/// 工具栏按钮渲染数据（由主工具栏 / 上下文工具栏在 build 期组装）。
class WbToolbarItemEntry {
  const WbToolbarItemEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.enabled = true,
    this.tooltip,
    this.shortcut = '',
    this.badgeColor,
    this.startsGroup = false,
    this.keyPrefix = 'wb-toolbar-',
  });

  /// 稳定 id（与配置条目 id 一致）。
  final String id;

  /// 显示名。
  final String label;

  /// 图标。
  final IconData icon;

  /// 点击回调。
  final VoidCallback onTap;

  /// 激活态（当前工具 / 展开态）。
  final bool active;

  /// 是否可用（false 灰显且不响应）。
  final bool enabled;

  /// Tooltip 文本（null 回退 [label]）。
  final String? tooltip;

  /// 快捷键角标（仅显示；空串不显示）。
  final String shortcut;

  /// 右下角色点（颜色类按钮显示当前色）。
  final Color? badgeColor;

  /// 组首标记（渲染时前置分组间距）。
  final bool startsGroup;

  /// 自动化测试 key 前缀（`<prefix><id>`）。
  final String keyPrefix;

  /// 自动化测试 key。
  ValueKey<String> get key => ValueKey<String>('$keyPrefix$id');

  /// 转换为"更多"菜单项。
  WbToolbarMoreMenuEntry toMenuEntry({bool dividerBefore = false}) {
    return WbToolbarMoreMenuEntry(
      value: this,
      label: label,
      icon: icon,
      shortcut: shortcut,
      keySuffix: id,
      dividerBefore: dividerBefore,
      enabled: enabled,
    );
  }

  @override
  String toString() => 'WbToolbarItemEntry($id)';
}

/// 工具栏图标按钮（hover / active / disabled / 角标 / 色点五态）。
class WbToolbarIconButton extends StatelessWidget {
  const WbToolbarIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.active = false,
    this.enabled = true,
    this.shortcut = '',
    this.badgeColor,
    this.iconSize = WbToolbarMetrics.iconSize,
    this.interactive = true,
  });

  /// 图标。
  final IconData icon;

  /// 点击回调（[interactive] 为 false 时忽略，由外层接管命中）。
  final VoidCallback? onTap;

  /// Tooltip 文本。
  final String? tooltip;

  /// 激活态（主色 12% 背景 + 主色图标）。
  final bool active;

  /// 是否可用。
  final bool enabled;

  /// 快捷键角标（空串不显示）。
  final String shortcut;

  /// 右下角色点（颜色按钮）。
  final Color? badgeColor;

  /// 图标尺寸。
  final double iconSize;

  /// 是否参与点击（false 时输出纯视觉块，供 PopupMenuButton 等外层接管）。
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Color foreground = !enabled
        ? colors.toolbarIcon.withValues(alpha: 0.35)
        : (active ? colors.toolbarActive : colors.toolbarIcon);
    final Color badgeBackground = active
        ? colors.toolbarActive.withValues(alpha: 0.12)
        : Colors.transparent;

    final Widget core = AnimatedContainer(
      duration: const Duration(milliseconds: 80),
      width: WbToolbarMetrics.buttonSize,
      height: WbToolbarMetrics.buttonSize,
      decoration: BoxDecoration(
        color: badgeBackground,
        borderRadius: BorderRadius.circular(WbToolbarMetrics.radius),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Icon(icon, size: iconSize, color: foreground),
          if (shortcut.isNotEmpty)
            Positioned(
              right: 3,
              bottom: 1,
              child: Text(
                shortcut,
                style: TextStyle(
                  fontSize: 9,
                  height: 1,
                  letterSpacing: 0.2,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? colors.toolbarActive
                      : colors.toolbarIcon.withValues(alpha: 0.55),
                ),
              ),
            ),
          if (badgeColor != null)
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: badgeColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.elevated, width: 1),
                ),
              ),
            ),
        ],
      ),
    );

    Widget button = core;
    if (interactive) {
      button = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(WbToolbarMetrics.radius),
          hoverColor: colors.cardHover,
          onTap: enabled ? onTap : null,
          child: core,
        ),
      );
    }
    final String? message = tooltip;
    if (message == null || message.isEmpty) {
      return button;
    }
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 600),
      child: button,
    );
  }
}

/// 工具栏内的细分隔线（固定区前 / 组间可选）。
class WbToolbarDivider extends StatelessWidget {
  const WbToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 5.5),
      color: colors.cardBorder,
    );
  }
}

/// 响应式工具栏行：按可用宽度折叠尾部条目，固定区始终保留。
///
/// 溢出算法见 [computeWbToolbarVisibleCount]；折叠条目通过
/// [fixedBuilder] 的 `hidden` 参数交给"更多"菜单渲染。
///
/// 注意：[padding] 仅参与预算计算（本组件不施加内边距）；调用方若在
/// 外层容器上施加了水平内边距（LayoutBuilder 的约束已扣除），此处传 0。
class WbToolbarRow extends StatelessWidget {
  const WbToolbarRow({
    super.key,
    required this.items,
    required this.fixedBuilder,
    this.leading = const <Widget>[],
    this.leadingExtent = 0,
    this.fixedExtent,
    this.itemExtent = WbToolbarMetrics.itemExtent,
    this.padding = 0,
  });

  /// 可折叠条目（依序显示前缀）。
  final List<WbToolbarItemEntry> items;

  /// 固定尾部构建器；收到被折叠条目列表（供"更多"菜单）。
  final List<Widget> Function(
    BuildContext context,
    List<WbToolbarItemEntry> hidden,
  ) fixedBuilder;

  /// 前缀固定组件（如上下文类型标签）。
  final List<Widget> leading;

  /// 前缀固定区宽度估算。
  final double leadingExtent;

  /// 尾部固定区宽度估算（null → 分隔线 + 3 条目）。
  final double? fixedExtent;

  /// 单条目占位宽度。
  final double itemExtent;

  /// 容器水平内边距预算（默认 0：外层已扣除）。
  final double padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double resolvedFixedExtent = fixedExtent ??
            WbToolbarMetrics.separatorExtent + 3 * WbToolbarMetrics.itemExtent;
        final int visible = computeWbToolbarVisibleCount(
          maxWidth: constraints.maxWidth,
          padding: padding,
          leadingExtent: leadingExtent,
          fixedExtent: resolvedFixedExtent,
          itemExtent: itemExtent,
          total: items.length,
        );
        final List<WbToolbarItemEntry> shown =
            items.take(visible).toList(growable: false);
        final List<WbToolbarItemEntry> hidden =
            items.skip(visible).toList(growable: false);
        final List<Widget> fixed = fixedBuilder(context, hidden);

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ...leading,
            for (int i = 0; i < shown.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  left: i == 0
                      ? 0
                      : (shown[i].startsGroup
                          ? WbToolbarMetrics.gap + 2
                          : 1),
                  right: 1,
                ),
                child: WbToolbarIconButton(
                  key: shown[i].key,
                  icon: shown[i].icon,
                  tooltip: shown[i].tooltip ?? shown[i].label,
                  active: shown[i].active,
                  enabled: shown[i].enabled,
                  shortcut: shown[i].shortcut,
                  badgeColor: shown[i].badgeColor,
                  onTap: shown[i].onTap,
                ),
              ),
            if (shown.isNotEmpty && fixed.isNotEmpty) const WbToolbarDivider(),
            ...fixed,
          ],
        );
      },
    );
  }
}

/// "更多"菜单项。
class WbToolbarMoreMenuEntry {
  const WbToolbarMoreMenuEntry({
    required this.value,
    required this.label,
    required this.icon,
    this.shortcut = '',
    this.keySuffix = '',
    this.dividerBefore = false,
    this.enabled = true,
  });

  /// 选中时回传的值（[WbToolbarItemEntry] 或字符串动作 id）。
  final Object value;

  /// 显示名。
  final String label;

  /// 行首图标。
  final IconData icon;

  /// 行尾快捷键文本。
  final String shortcut;

  /// 自动化测试 key 后缀（`wb-toolbar-more-item-<suffix>`）。
  final String keySuffix;

  /// 是否在本项前插入分隔线。
  final bool dividerBefore;

  /// 是否可用。
  final bool enabled;

  @override
  String toString() => 'WbToolbarMoreMenuEntry($label)';
}

/// "更多"菜单按钮（溢出入口 / 上下文菜单入口）。
///
/// 点击 `⋯` 展开：折叠条目 + 调用方附加的固定条目（设置 / 快捷键等）；
/// 点击空白处收起（PopupMenu 默认行为，文档 §17.2）。
class WbToolbarMoreButton extends StatelessWidget {
  const WbToolbarMoreButton({
    super.key,
    required this.items,
    required this.onSelected,
    this.active = false,
    this.tooltip = '更多',
    this.buttonKey,
  });

  /// 菜单项（依序）。
  final List<WbToolbarMoreMenuEntry> items;

  /// 选中回调（值为 [WbToolbarMoreMenuEntry.value]）。
  final ValueChanged<Object> onSelected;

  /// 是否存在折叠项（true 时按钮高亮提示）。
  final bool active;

  /// Tooltip。
  final String tooltip;

  /// 按钮测试 key（默认无 key）。
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return PopupMenuButton<Object>(
      key: buttonKey,
      tooltip: '',
      position: PopupMenuPosition.under,
      offset: const Offset(0, -6),
      color: colors.elevated,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.cardBorder),
      ),
      constraints: const BoxConstraints(minWidth: 176, maxWidth: 264),
      itemBuilder: (BuildContext context) {
        return <PopupMenuEntry<Object>>[
          for (final WbToolbarMoreMenuEntry entry in items) ...<PopupMenuEntry<Object>>[
            if (entry.dividerBefore) const PopupMenuDivider(height: 5),
            PopupMenuItem<Object>(
              key: ValueKey<String>(
                'wb-toolbar-more-item-${entry.keySuffix.isEmpty ? entry.label : entry.keySuffix}',
              ),
              value: entry.value,
              height: 36,
              enabled: entry.enabled,
              child: Row(
                children: <Widget>[
                  Icon(entry.icon, size: 16, color: colors.toolbarIcon),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colors.icon),
                    ),
                  ),
                  if (entry.shortcut.isNotEmpty)
                    Text(
                      entry.shortcut,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(
                            color: colors.toolbarIcon.withValues(alpha: 0.6),
                          ),
                    ),
                ],
              ),
            ),
          ],
        ];
      },
      onSelected: onSelected,
      child: WbToolbarIconButton(
        icon: LinearIcons.more,
        tooltip: tooltip,
        active: active,
        interactive: false,
      ),
    );
  }
}

// ---- 共享外观 --------------------------------------------------------------

/// 工具栏 / 弹层共用轻阴影（文档 §18.3：`0 2px 8px rgba(0,0,0,0.08)` 的
/// 近似）。中性黑 8% 属深度效果，非元素色，不随主题 token 变化。
const List<BoxShadow> wbToolbarShadow = <BoxShadow>[
  BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2)),
];

/// 工具栏容器统一外观：工具栏底色（`toolbar.bg`）+ 圆角 + 边框 + 轻阴影。
///
/// 主工具栏 / 上下文工具栏 / 上下文浮层复用；颜色全部来自
/// [WbThemeColors] token（文档 §18.2）。
BoxDecoration wbToolbarSurfaceDecoration(WbThemeColors colors) {
  return BoxDecoration(
    color: colors.toolbarBackground,
    borderRadius: BorderRadius.circular(WbToolbarMetrics.containerRadius),
    border: Border.all(color: colors.cardBorder),
    boxShadow: wbToolbarShadow,
  );
}
