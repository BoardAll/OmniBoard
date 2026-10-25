/// 白板列表页（首页）：本地文件 + 最近白板入口 + 新建。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_cast/cast.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../routes.dart';
import '../services/app_exit_service.dart';
import '../services/board_file_service.dart';
import '../services/ffi_service.dart';
import '../services/settings_store.dart';

/// 本次会话新建的白板条目（内存；保存到文件后进入「本地文件」列表）。
class WbRecentBoard {
  const WbRecentBoard({
    required this.id,
    required this.name,
    required this.updatedAt,
  });

  /// 白板 id。
  final String id;

  /// 白板名称。
  final String name;

  /// 最近打开时间。
  final DateTime updatedAt;
}

/// 白板列表页。
class BoardListPage extends StatefulWidget {
  const BoardListPage({super.key});

  @override
  State<BoardListPage> createState() => _BoardListPageState();
}

class _BoardListPageState extends State<BoardListPage> {
  final List<WbRecentBoard> _recent = <WbRecentBoard>[];

  void _createBoard() {
    final String id = 'board-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _recent.insert(
        0,
        WbRecentBoard(
          id: id,
          name: '未命名白板 ${_recent.length + 1}',
          updatedAt: DateTime.now(),
        ),
      );
    });
    context.push(WbRoutes.boardPath(id));
  }

  void _removeBoard(WbRecentBoard board) {
    setState(() => _recent.remove(board));
  }

  /// 首页「白板」入口：继续最近白板（本次会话 / 本地文件），没有则新建。
  void _openWhiteboard() {
    if (_recent.isNotEmpty) {
      context.push(WbRoutes.boardPath(_recent.first.id));
      return;
    }
    final List<WbRecentBoardEntry> files = _files()?.recentBoards ??
        const <WbRecentBoardEntry>[];
    if (files.isNotEmpty) {
      _openFile(files.first.path);
      return;
    }
    _createBoard();
  }

  /// 首页「局域网投屏」入口：打开同一套白板并自动开启投屏接收。
  void _openCastBoard() {
    final String id = 'board-cast-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _recent.insert(
        0,
        WbRecentBoard(id: id, name: '投屏白板', updatedAt: DateTime.now()),
      );
    });
    context.push(WbRoutes.boardPath(id, cast: true));
  }

  /// 发送端：输入四位投屏码后加入接收端房间，并在白板内展示发送状态。
  Future<void> _joinCastAsSender() async {
    final WbCastController cast = context.read<WbCastController>();
    final String configured =
        (context.read<WbSettingsStore?>()?.syncServerUrl ?? '').trim();
    final String host = Platform.localHostname.trim();
    final bool? joined = await WbCastJoinDialog.show(
      context,
      cast,
      deviceName: host.isEmpty ? 'Windows 设备' : host,
      endpoint: configured.isEmpty ? WbCastConfig.defaultEndpoint : configured,
    );
    if (!mounted || joined != true) {
      return;
    }
    final String id = 'board-cast-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _recent.insert(
        0,
        WbRecentBoard(id: id, name: '投屏发送端', updatedAt: DateTime.now()),
      );
    });
    unawaited(context.push(WbRoutes.boardPath(id, castSender: true)));
  }

  /// 文件服务（可空：未挂载 Provider 时打开入口给出轻提示）。
  WbBoardFileService? _files() => context.read<WbBoardFileService?>();

  /// AppBar「退出应用」：未保存改动先弹三选（与窗口 X 同一编排）。
  Future<void> _exitApp() async {
    await context.read<WbAppExitService>().requestExit(context);
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// AppBar「打开本地白板」：弹文件对话框选文件后进入编辑页（经路由 extra）。
  Future<void> _openLocalBoard() async {
    final WbBoardFileService? files = _files();
    if (files == null) {
      _snack('打开不可用（文件服务未挂载）');
      return;
    }
    final String? path = await files.openFilePicker();
    if (!mounted || path == null || path.isEmpty) {
      return;
    }
    _openFile(path);
  }

  /// 打开本地文件：失效路径给出提示并移出最近列表；有效路径进入编辑页。
  void _openFile(String path) {
    if (!File(path).existsSync()) {
      _files()?.removeRecentBoard(path);
      _snack('文件不存在，已从最近列表移除：$path');
      return;
    }
    final String id = 'board-file-${DateTime.now().millisecondsSinceEpoch}';
    context.push(
      WbRoutes.boardPath(id),
      extra: WbBoardOpenRequest(path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final MiuixThemeData miuix =
        MiuixThemeData.of(Theme.of(context).brightness);
    // 本地已保存文件列表（持久化；未挂载文件服务时为空）。
    final List<WbRecentBoardEntry> recentFiles =
        context.watch<WbBoardFileService?>()?.recentBoards ??
            const <WbRecentBoardEntry>[];
    return MiuixTheme(
      data: miuix,
      child: Scaffold(
        backgroundColor: colors.canvas,
        floatingActionButton: MiuixFloatingActionButton(
          onPressed: _createBoard,
          child: MiuixContentColor(
            color: miuix.colors.onPrimary,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  MiuixIcon(icon: LinearIcons.add),
                  SizedBox(width: 8),
                  MiuixText('新建白板'),
                ],
              ),
            ),
          ),
        ),
        body: Column(
          children: <Widget>[
            MiuixSmallTopAppBar(
              title: '我的白板',
              color: colors.surface,
              actions: <Widget>[
                Tooltip(
                  message: '打开本地白板',
                  child: MiuixIconButton(
                    onPressed: () => unawaited(_openLocalBoard()),
                    child: const MiuixIcon(icon: LinearIcons.folder),
                  ),
                ),
                const _EngineStatusChip(),
                Tooltip(
                  message: '设置',
                  child: MiuixIconButton(
                    onPressed: () => context.push(WbRoutes.settingsPath),
                    child: const MiuixIcon(icon: LinearIcons.settings),
                  ),
                ),
                Tooltip(
                  message: '退出应用',
                  child: MiuixIconButton(
                    onPressed: () => unawaited(_exitApp()),
                    child: const MiuixIcon(icon: LinearIcons.power),
                  ),
                ),
              ],
            ),
            Expanded(
              child: _buildContent(colors, recentFiles),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    WbThemeColors colors,
    List<WbRecentBoardEntry> recentFiles,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 88),
      children: <Widget>[
        // 两个主入口：白板（默认不开启投屏）/ 局域网投屏（自动开启接收）。
        _buildEntries(colors),
        const SizedBox(height: 22),
        if (recentFiles.isEmpty && _recent.isEmpty)
          const SizedBox(height: 240, child: _EmptyState())
        else ...<Widget>[
          if (recentFiles.isNotEmpty) ...<Widget>[
            _sectionHeader('本地文件'),
            for (final WbRecentBoardEntry entry in recentFiles)
              _fileCard(entry, colors),
          ],
          if (recentFiles.isNotEmpty && _recent.isNotEmpty)
            const SizedBox(height: 8),
          if (_recent.isNotEmpty) ...<Widget>[
            if (recentFiles.isNotEmpty) _sectionHeader('本次会话'),
            for (final WbRecentBoard board in _recent) _boardCard(board, colors),
          ],
        ],
      ],
    );
  }

  /// 首页双卡片入口（宽屏左右并排，窄屏上下排列）。
  Widget _buildEntries(WbThemeColors colors) {
    final Widget whiteboard = _HomeEntryCard(
      icon: const MiuixIcon(icon: LinearIcons.page),
      title: '白板',
      subtitle: '打开普通白板；默认不自动开启投屏接收',
      accent: colors.primary,
      onTap: _openWhiteboard,
    );
    final Widget cast = _HomeEntryCard(
      icon: const MiuixIcon(icon: LinearIcons.cloud),
      title: '局域网投屏',
      subtitle: '打开同一套白板，自动开启接收；投屏码即房间号',
      accent: const Color(0xFF12B76A),
      onTap: _openCastBoard,
      footer: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => unawaited(_joinCastAsSender()),
          icon: const Icon(Icons.keyboard_alt_outlined, size: 15),
          label: const Text('输入投屏码'),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.primary,
            side: BorderSide(color: colors.primary.withValues(alpha: 0.35)),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 780) {
          // 方块卡片：固定宽高，避免被拉伸成横条。
          return Row(
            children: <Widget>[
              SizedBox(width: 340, height: 220, child: whiteboard),
              const SizedBox(width: 16),
              SizedBox(width: 340, height: 220, child: cast),
            ],
          );
        }
        return Column(
          children: <Widget>[
            SizedBox(height: 200, child: whiteboard),
            const SizedBox(height: 12),
            SizedBox(height: 220, child: cast),
          ],
        );
      },
    );
  }

  Widget _sectionHeader(String title) {
    final MiuixThemeData theme = MiuixTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: MiuixText(
        title,
        style: theme.textStyles.subtitle.copyWith(
          color: theme.colors.onSurfaceVariantSummary,
        ),
      ),
    );
  }

  /// 本地已保存文件卡片（点击 / 「打开」进入编辑页；「移除」清出最近列表）。
  Widget _fileCard(WbRecentBoardEntry entry, WbThemeColors colors) {
    final String name =
        entry.name.isNotEmpty ? entry.name : _fileName(entry.path);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MiuixCard(
        colors: MiuixCardColors(
          color: colors.surface,
          contentColor: MiuixTheme.of(context).colors.onSurface,
        ),
        child: MiuixBasicComponent(
          title: name,
          summary: _fileSubtitle(entry),
          startAction: MiuixIcon(
            icon: LinearIcons.folder,
            tint: colors.primary,
          ),
          onClick: () => _openFile(entry.path),
          endActions: <Widget>[
            MiuixWindowIconCascadingDropdownMenu(
              entry: MiuixDropdownEntry(
                items: <MiuixDropdownItem>[
                  MiuixDropdownItem(
                    text: '打开',
                    onClick: () => _openFile(entry.path),
                  ),
                  MiuixDropdownItem(
                    text: '从列表移除',
                    onClick: () => _files()?.removeRecentBoard(entry.path),
                  ),
                ],
              ),
              child: const MiuixIcon(icon: LinearIcons.more),
            ),
          ],
        ),
      ),
    );
  }

  /// 本次会话新建白板卡片（原内存列表行为保持不变）。
  Widget _boardCard(WbRecentBoard board, WbThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MiuixCard(
        colors: MiuixCardColors(
          color: colors.surface,
          contentColor: MiuixTheme.of(context).colors.onSurface,
        ),
        child: MiuixBasicComponent(
          title: board.name,
          summary: _relativeTime(board.updatedAt),
          startAction: MiuixIcon(
            icon: LinearIcons.page,
            tint: colors.primary,
          ),
          onClick: () => context.push(WbRoutes.boardPath(board.id)),
          endActions: <Widget>[
            MiuixWindowIconCascadingDropdownMenu(
              entry: MiuixDropdownEntry(
                items: <MiuixDropdownItem>[
                  MiuixDropdownItem(
                    text: '打开',
                    onClick: () =>
                        context.push(WbRoutes.boardPath(board.id)),
                  ),
                  MiuixDropdownItem(
                    text: '从列表移除',
                    onClick: () => _removeBoard(board),
                  ),
                ],
              ),
              child: const MiuixIcon(icon: LinearIcons.more),
            ),
          ],
        ),
      ),
    );
  }

  static String _fileName(String path) {
    final int index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? path : path.substring(index + 1);
  }

  static String _fileSubtitle(WbRecentBoardEntry entry) {
    final DateTime? time = DateTime.tryParse(entry.updatedAt);
    if (time == null) {
      return entry.path;
    }
    return '${_relativeTime(time)} · ${entry.path}';
  }

  static String _relativeTime(DateTime time) {
    final Duration diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) {
      return '刚刚';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes} 分钟前';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours} 小时前';
    }
    return '${diff.inDays} 天前';
  }
}

/// 首页主入口方块卡片（白板 / 局域网投屏）。
class _HomeEntryCard extends StatefulWidget {
  const _HomeEntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
    this.footer,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;
  final Widget? footer;

  @override
  State<_HomeEntryCard> createState() => _HomeEntryCardState();
}

class _HomeEntryCardState extends State<_HomeEntryCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (PointerEnterEvent _) => setState(() => _hover = true),
      onExit: (PointerExitEvent _) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: _hover ? colors.hover : colors.elevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _hover
                ? widget.accent.withValues(alpha: 0.55)
                : colors.cardBorder,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: _hover ? 0.12 : 0.06),
              blurRadius: _hover ? 22 : 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: widget.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(child: widget.icon),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.arrow_outward_rounded,
                        size: 16,
                        color: colors.icon.withValues(alpha: 0.35),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    widget.title,
                    style: TextStyle(
                      color: colors.icon,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.icon.withValues(alpha: 0.58),
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  if (widget.footer != null) ...<Widget>[
                    const SizedBox(height: 12),
                    widget.footer!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final MiuixThemeData theme = MiuixTheme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          MiuixIcon(
            icon: LinearIcons.folder,
            size: 56,
            tint: theme.colors.onSurfaceVariantSummary,
          ),
          const SizedBox(height: 16),
          MiuixText(
            '还没有白板',
            style: theme.textStyles.title3,
          ),
          const SizedBox(height: 8),
          MiuixText(
            '点击右下角「新建白板」开始创作',
            style: theme.textStyles.body2.copyWith(
              color: theme.colors.onSurfaceVariantSummary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 引擎状态指示（已加载 / 演示模式）。
class _EngineStatusChip extends StatelessWidget {
  const _EngineStatusChip();

  @override
  Widget build(BuildContext context) {
    final WbFfiService ffi = context.read<WbFfiService>();
    final bool available = ffi.isAvailable;
    final MiuixThemeData theme = MiuixTheme.of(context);
    return Tooltip(
      message: available ? '引擎已加载：${ffi.loadedFrom}' : '引擎未加载（演示模式）',
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: ShapeDecoration(
          color: theme.colors.surfaceContainer,
          shape: const MiuixSquircleBorder(cornerRadius: 12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MiuixIcon(
              icon: available ? LinearIcons.cloud : LinearIcons.offline,
              size: 16,
              tint: theme.colors.onSurfaceVariantSummary,
            ),
            const SizedBox(width: 6),
            MiuixText(
              available ? '引擎就绪' : '演示模式',
              style: theme.textStyles.footnote1.copyWith(
                color: theme.colors.onSurfaceVariantSummary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
