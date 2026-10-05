/// 左侧栏（《左侧栏与页面管理设计》§2 / §3 / §6 / §7）。
///
/// 覆盖 M2.6.1 的侧栏基础：
/// - 展开 / 折叠：`Cmd/Ctrl + \` 或折叠按钮；折叠态呈现 56px 图标轨（§2.2），
///   展开 240px —— 由 [AnimatedContainer] 以 200ms 过渡（§9.4）；
/// - 分区布局：标题 / 页面 / 图层 / AI / 设置（§2.1），页面与图层分区
///   可独立折叠（§10.2，状态为进程内记忆）；
/// - 标题区：白板图标返回列表、标题点击重命名、`▾` 打开白板菜单（§3）；
/// - 页面缩略图手动刷新：刷新按钮经 [ValueNotifier] 注入 [PageManager]
///   与 [LayersPanel]（§4.9）；
/// - 构造保持 `const Sidebar()` 兼容（board_edit_page 以 `SizedBox(width: 240)`
///   挂载，折叠时在该 240 槽位内左对齐呈现图标轨）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../routes.dart';
import '../state/ai_state.dart';
import '../state/board_state.dart';
import '../state/page_state.dart';
import 'canvas/canvas_controller.dart';
import 'layers_panel.dart';
import 'page_background_dialog.dart';
import 'page_manager.dart';

/// 左侧栏。
class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    this.initiallyCollapsed = false,
    this.onOpenAiPanel,
    this.canvasController,
    this.canEdit = true,
    this.onBlockedEdit,
  });

  /// 展开宽度（design §2.3）。
  static const double expandedWidth = 240;

  /// 折叠宽度（design §2.3）。
  static const double collapsedWidth = 56;

  /// 折叠 / 展开动效时长（design §9.4）。
  static const Duration collapseDuration = Duration(milliseconds: 200);

  /// 初始是否折叠（测试可注入；运行期由 `Ctrl + \` 切换）。
  final bool initiallyCollapsed;

  /// AI 分区点击回调。
  ///
  /// 缺省为 null：AI 面板的展开由编辑页控制（board_edit_page 为只读文件），
  /// 此时点击给出提示，待编辑页接入回调后替换为真实展开。
  final VoidCallback? onOpenAiPanel;

  /// 画布控制器（可选，透传给图层面板；编辑页注入后图层与画布同源）。
  final WbCanvasController? canvasController;

  /// 是否允许编辑（M3 只读收窄；false 时新建页面等编辑入口被拦）。
  final bool canEdit;

  /// 编辑被拦时的统一提示回调（宿主弹轻提示；null 时静默）。
  final VoidCallback? onBlockedEdit;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'wb.sidebar');

  /// 手动刷新信号：页面缩略图与图层区共享（design §4.9「手动刷新按钮」）。
  final ValueNotifier<int> _refreshSignal = ValueNotifier<int>(0);

  late bool _collapsed = widget.initiallyCollapsed;
  bool _pagesExpanded = true;
  bool _layersExpanded = true;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _refreshSignal.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ---- 折叠 / 展开（§10.1） ----

  /// 全局键处理：`Cmd/Ctrl + \` 折叠 / 展开（不依赖侧栏焦点）。
  bool _onKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) {
      return false;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool primary = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (primary && event.logicalKey == LogicalKeyboardKey.backslash) {
      _toggleCollapsed();
      return true;
    }
    return false;
  }

  void _toggleCollapsed() {
    if (!mounted) {
      return;
    }
    setState(() => _collapsed = !_collapsed);
  }

  void _expandToLayers() {
    setState(() {
      _collapsed = false;
      _layersExpanded = true;
    });
  }

  void _refreshThumbnails() {
    _refreshSignal.value++;
  }

  /// 编辑守卫（M3 只读收窄）：无编辑权限时经 [onBlockedEdit] 提示并拒绝。
  bool _guardEdit() {
    if (widget.canEdit) {
      return true;
    }
    widget.onBlockedEdit?.call();
    return false;
  }

  /// 新建页面（M3 只读收窄：无编辑权限时拦截）。
  void _addPage(BuildContext context) {
    if (!_guardEdit()) {
      return;
    }
    _maybeRead<WbPageState>(context)?.addPage();
  }

  // ---- 导航（§3 / §7） ----

  void _goHome() {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(WbRoutes.homePath);
      return;
    }
    Navigator.maybeOf(context)?.maybePop();
  }

  void _openSettings() {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router != null) {
      router.push(WbRoutes.settingsPath);
    }
  }

  void _openAiPanel() {
    final VoidCallback? callback = widget.onOpenAiPanel;
    if (callback != null) {
      callback();
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('AI 面板由编辑页右上角按钮展开'),
        duration: Duration(milliseconds: 1500),
      ),
    );
  }

  // ---- 白板菜单（§3.2） ----

  List<PopupMenuEntry<String>> _boardMenuItems(WbThemeColors colors) {
    PopupMenuItem<String> item(
      String value,
      IconData icon,
      String label, {
      bool enabled = true,
    }) {
      return PopupMenuItem<String>(
        value: value,
        enabled: enabled,
        child: Row(
          children: <Widget>[
            Icon(icon, size: 16, color: colors.icon),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    // 未接入的入口按 design §3.2 保留占位并禁用（Wave 4 接入后启用）。
    return <PopupMenuEntry<String>>[
      item('rename', LinearIcons.pen, '重命名'),
      item('duplicate', LinearIcons.duplicate, '复制白板', enabled: false),
      item('folder', LinearIcons.folder, '移动到文件夹', enabled: false),
      item('star', LinearIcons.light, '收藏', enabled: false),
      const PopupMenuDivider(),
      item('members', LinearIcons.members, '协作成员', enabled: false),
      item('share', LinearIcons.share, '分享链接', enabled: false),
      item('permission', LinearIcons.permission, '权限设置', enabled: false),
      const PopupMenuDivider(),
      item('present', LinearIcons.fullscreen, '演示模式', enabled: false),
      item('export', LinearIcons.export, '导出', enabled: false),
      item('print', LinearIcons.print, '打印', enabled: false),
      const PopupMenuDivider(),
      item('delete', LinearIcons.delete, '删除白板', enabled: false),
    ];
  }

  Future<void> _renameBoard(WbBoardState board) async {
    final WbBoard? current = board.board;
    if (current == null) {
      return;
    }
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _BoardRenameDialog(initialName: current.name),
    );
    if (name == null || name.isEmpty || !mounted) {
      return;
    }
    board.rename(name);
  }

  // ---- 工具 ----

  T? _maybeRead<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  T? _maybeWatch<T>(BuildContext context) {
    try {
      return context.watch<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Focus(
      focusNode: _focusNode,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (PointerDownEvent event) => _focusNode.requestFocus(),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AnimatedContainer(
            key: const ValueKey<String>('sidebar-panel'),
            duration: Sidebar.collapseDuration,
            curve: Curves.fastOutSlowIn, // cubic-bezier(0.4, 0, 0.2, 1)，§9.4
            width:
                _collapsed ? Sidebar.collapsedWidth : Sidebar.expandedWidth,
            height: double.infinity,
            color: colors.sidebarBackground,
            child: ClipRect(
              child: Stack(
                children: <Widget>[
                  // 展开态子树（常驻挂载以保留滚动 / 缩略图等状态）。
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: Sidebar.expandedWidth,
                    child: ExcludeFocus(
                      excluding: _collapsed,
                      child: IgnorePointer(
                        ignoring: _collapsed,
                        child: AnimatedOpacity(
                          opacity: _collapsed ? 0 : 1,
                          duration: Sidebar.collapseDuration,
                          curve: Curves.fastOutSlowIn,
                          child: _buildExpanded(context),
                        ),
                      ),
                    ),
                  ),
                  // 折叠态图标轨（§2.2）。
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: Sidebar.collapsedWidth,
                    child: ExcludeFocus(
                      excluding: !_collapsed,
                      child: IgnorePointer(
                        ignoring: !_collapsed,
                        child: AnimatedOpacity(
                          opacity: _collapsed ? 1 : 0,
                          duration: Sidebar.collapseDuration,
                          curve: Curves.fastOutSlowIn,
                          child: _buildRail(context),
                        ),
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

  // ---- 展开态 ----

  Widget _buildExpanded(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Column(
      children: <Widget>[
        _buildHeader(context),
        Divider(height: 1, color: colors.border),
        _SectionHeader(
          id: 'pages',
          icon: LinearIcons.page,
          title: '页面',
          expanded: _pagesExpanded,
          onToggle: () => setState(() => _pagesExpanded = !_pagesExpanded),
          actions: <Widget>[
            IconButton(
              key: const ValueKey<String>('pages-refresh'),
              tooltip: '刷新缩略图',
              icon: Icon(LinearIcons.refresh, size: 14, color: colors.icon),
              onPressed: _refreshThumbnails,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              splashRadius: 12,
            ),
            IconButton(
              key: const ValueKey<String>('pages-add'),
              tooltip: '新建页面',
              icon: Icon(LinearIcons.addPage, size: 14, color: colors.icon),
              onPressed: () => _addPage(context),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              splashRadius: 12,
            ),
          ],
        ),
        if (_pagesExpanded)
          Expanded(
            flex: _layersExpanded ? 3 : 1,
            child: PageManager(
              refreshSignal: _refreshSignal,
              canEdit: widget.canEdit,
              onBlockedEdit: widget.onBlockedEdit,
              onEditBackground: showWbDesktopPageBackgroundDialog,
              previewImageProvider: (String path) => FileImage(File(path)),
            ),
          ),
        Divider(height: 1, color: colors.border),
        _SectionHeader(
          id: 'layers',
          icon: LinearIcons.layers,
          title: '图层',
          expanded: _layersExpanded,
          onToggle: () => setState(() => _layersExpanded = !_layersExpanded),
        ),
        if (_layersExpanded)
          Expanded(
            flex: _pagesExpanded ? 2 : 1,
            child: LayersPanel(
              refreshSignal: _refreshSignal,
              canvasController: widget.canvasController,
              canEdit: widget.canEdit,
              onBlockedEdit: widget.onBlockedEdit,
            ),
          ),
        if (!_pagesExpanded && !_layersExpanded) const Spacer(),
        Divider(height: 1, color: colors.border),
        _buildAiRow(context),
        Divider(height: 1, color: colors.border),
        _buildSettingsRow(context),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 4),
        child: Consumer<WbBoardState>(
          builder: (
            BuildContext context,
            WbBoardState board,
            Widget? child,
          ) {
            final String name = board.board?.name ?? '未打开白板';
            return Row(
              children: <Widget>[
                IconButton(
                  key: const ValueKey<String>('sidebar-home'),
                  tooltip: '返回白板列表',
                  icon: Icon(LinearIcons.board, size: 18, color: colors.icon),
                  onPressed: _goHome,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  splashRadius: 16,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: InkWell(
                    key: const ValueKey<String>('sidebar-board-name'),
                    onTap: () => unawaited(_renameBoard(board)),
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  key: const ValueKey<String>('sidebar-board-menu'),
                  tooltip: '白板菜单',
                  icon: Icon(
                    LinearIcons.sendBackward, // ▾（§3.1 下拉）
                    size: 16,
                    color: colors.icon,
                  ),
                  padding: EdgeInsets.zero,
                  onSelected: (String value) {
                    if (value == 'rename') {
                      unawaited(_renameBoard(board));
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      _boardMenuItems(context.wbColors),
                ),
                IconButton(
                  key: const ValueKey<String>('sidebar-collapse'),
                  tooltip: '折叠侧栏 (Ctrl+\\)',
                  icon: Icon(LinearIcons.back, size: 16, color: colors.icon),
                  onPressed: _toggleCollapsed,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  splashRadius: 16,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildAiRow(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final bool streaming =
        _maybeWatch<WbAiState>(context)?.isStreaming ?? false;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const ValueKey<String>('sidebar-ai'),
        onTap: _openAiPanel,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                Icon(LinearIcons.ai, size: 18, color: colors.icon),
                const SizedBox(width: 8),
                // 文案为「AI」：编辑页 AI 面板标题已占用「AI 助手」，
                // 保持唯一性避免语义重复（tooltip 仍提供完整名称）。
                Tooltip(
                  message: 'AI 助手',
                  child: Text(
                    'AI',
                    style: TextStyle(fontSize: 13, color: colors.icon),
                  ),
                ),
                const Spacer(),
                if (streaming)
                  Container(
                    key: const ValueKey<String>('sidebar-ai-streaming'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsRow(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const ValueKey<String>('sidebar-settings'),
        onTap: _openSettings,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                Icon(LinearIcons.settings, size: 18, color: colors.icon),
                const SizedBox(width: 8),
                Text(
                  '设置',
                  style: TextStyle(fontSize: 13, color: colors.icon),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- 折叠态图标轨（§2.2） ----

  Widget _buildRail(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbPageState? pages = _maybeWatch<WbPageState>(context);
    final List<WbPage> pageList = pages?.pages ?? const <WbPage>[];
    final String currentId = pages?.currentPageId ?? '';
    final bool streaming =
        _maybeWatch<WbAiState>(context)?.isStreaming ?? false;
    return Column(
      children: <Widget>[
        const SizedBox(height: 8),
        _RailItem(
          key: const ValueKey<String>('rail-home'),
          icon: LinearIcons.board,
          tooltip: '白板列表',
          onTap: _goHome,
        ),
        Divider(height: 9, indent: 10, endIndent: 10, color: colors.border),
        Expanded(
          child: ListView.builder(
            key: const ValueKey<String>('rail-pages'),
            padding: EdgeInsets.zero,
            itemCount: pageList.length,
            itemBuilder: (BuildContext context, int index) {
              final WbPage page = pageList[index];
              return _RailItem(
                key: ValueKey<String>('rail-page-${page.id}'),
                icon: LinearIcons.page,
                tooltip: page.name,
                selected: page.id == currentId,
                onTap: () => pages?.select(page.id),
              );
            },
          ),
        ),
        _RailItem(
          key: const ValueKey<String>('rail-add'),
          icon: LinearIcons.addPage,
          tooltip: '新建页面',
          onTap: () => _addPage(context),
        ),
        Divider(height: 9, indent: 10, endIndent: 10, color: colors.border),
        _RailItem(
          key: const ValueKey<String>('rail-layers'),
          icon: LinearIcons.layers,
          tooltip: '图层',
          onTap: _expandToLayers,
        ),
        _RailItem(
          key: const ValueKey<String>('rail-ai'),
          icon: LinearIcons.ai,
          tooltip: 'AI 助手',
          badge: streaming,
          onTap: _openAiPanel,
        ),
        _RailItem(
          key: const ValueKey<String>('rail-settings'),
          icon: LinearIcons.settings,
          tooltip: '设置',
          onTap: _openSettings,
        ),
        Divider(height: 9, indent: 10, endIndent: 10, color: colors.border),
        _RailItem(
          key: const ValueKey<String>('rail-expand'),
          icon: LinearIcons.forward,
          tooltip: '展开侧栏 (Ctrl+\\)',
          onTap: _toggleCollapsed,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 分区标题（§10.2）：图标 + 标题 + 可选操作 + 折叠开关。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.id,
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onToggle,
    this.actions = const <Widget>[],
  });

  final String id;
  final IconData icon;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 6),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 14, color: colors.icon),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colors.icon,
              ),
            ),
            const Spacer(),
            ...actions,
            IconButton(
              key: ValueKey<String>('section-toggle-$id'),
              tooltip: expanded ? '折叠$title分区' : '展开$title分区',
              icon: Icon(
                expanded ? LinearIcons.sendBackward : LinearIcons.forward,
                size: 14,
                color: colors.icon,
              ),
              onPressed: onToggle,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              splashRadius: 12,
            ),
          ],
        ),
      ),
    );
  }
}

/// 折叠态图标轨按钮（§2.2 / §9.5：悬停显示工具提示）。
class _RailItem extends StatelessWidget {
  const _RailItem({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.badge = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Center(
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 40,
          height: 34,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  if (selected)
                    Container(
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  Icon(
                    icon,
                    size: 19,
                    color: selected ? colors.primary : colors.icon,
                  ),
                  if (badge)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          shape: BoxShape.circle,
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
/// 白板重命名对话框。
///
/// 控制器由 State 持有并随对话框元素卸载而释放（理由同页面重命名对话框：
/// pop 之后仍有退出动画帧在使用控制器）。
class _BoardRenameDialog extends StatefulWidget {
  const _BoardRenameDialog({required this.initialName});

  /// 打开对话框时的白板名称。
  final String initialName;

  @override
  State<_BoardRenameDialog> createState() => _BoardRenameDialogState();
}

class _BoardRenameDialogState extends State<_BoardRenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名白板'),
      content: TextField(
        key: const ValueKey<String>('sidebar-board-rename-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '白板名称'),
        onSubmitted: (String value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('sidebar-board-rename-ok'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
