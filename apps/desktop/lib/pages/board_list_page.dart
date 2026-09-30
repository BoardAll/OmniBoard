/// 白板列表页（首页）：本地文件 + 最近白板入口 + 新建。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
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
              child: _recent.isEmpty && recentFiles.isEmpty
                  ? const _EmptyState()
                  : _buildList(colors, recentFiles),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    WbThemeColors colors,
    List<WbRecentBoardEntry> recentFiles,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 88),
      children: <Widget>[
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
