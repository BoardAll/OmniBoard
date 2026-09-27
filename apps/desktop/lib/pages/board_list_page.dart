/// 白板列表页（首页）：本地文件 + 最近白板入口 + 新建。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
    // 本地已保存文件列表（持久化；未挂载文件服务时为空）。
    final List<WbRecentBoardEntry> recentFiles =
        context.watch<WbBoardFileService?>()?.recentBoards ??
            const <WbRecentBoardEntry>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的白板'),
        backgroundColor: colors.surface,
        actions: <Widget>[
          IconButton(
            tooltip: '打开本地白板',
            icon: const Icon(LinearIcons.folder),
            onPressed: () => unawaited(_openLocalBoard()),
          ),
          const _EngineStatusChip(),
          IconButton(
            tooltip: '设置',
            icon: const Icon(LinearIcons.settings),
            onPressed: () => context.push(WbRoutes.settingsPath),
          ),
          IconButton(
            tooltip: '退出应用',
            icon: const Icon(LinearIcons.power),
            onPressed: () => unawaited(_exitApp()),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createBoard,
        icon: const Icon(LinearIcons.add),
        label: const Text('新建白板'),
      ),
      body: _recent.isEmpty && recentFiles.isEmpty
          ? const _EmptyState()
          : _buildList(colors, recentFiles),
    );
  }

  Widget _buildList(
    WbThemeColors colors,
    List<WbRecentBoardEntry> recentFiles,
  ) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        if (recentFiles.isNotEmpty) ...<Widget>[
          _sectionHeader('本地文件', colors),
          for (final WbRecentBoardEntry entry in recentFiles)
            _fileCard(entry, colors),
        ],
        if (recentFiles.isNotEmpty && _recent.isNotEmpty)
          const SizedBox(height: 8),
        if (_recent.isNotEmpty) ...<Widget>[
          if (recentFiles.isNotEmpty) _sectionHeader('本次会话', colors),
          for (final WbRecentBoard board in _recent) _boardCard(board, colors),
        ],
      ],
    );
  }

  Widget _sectionHeader(String title, WbThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(color: colors.icon),
      ),
    );
  }

  /// 本地已保存文件卡片（点击 / 「打开」进入编辑页；「移除」清出最近列表）。
  Widget _fileCard(WbRecentBoardEntry entry, WbThemeColors colors) {
    final String name =
        entry.name.isNotEmpty ? entry.name : _fileName(entry.path);
    return Card(
      color: colors.surface,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(LinearIcons.folder, color: colors.primary),
        title: Text(name),
        subtitle: Text(
          _fileSubtitle(entry),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (String value) {
            if (value == 'open') {
              _openFile(entry.path);
            } else if (value == 'remove') {
              _files()?.removeRecentBoard(entry.path);
            }
          },
          itemBuilder: (BuildContext context) =>
              const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(value: 'open', child: Text('打开')),
            PopupMenuItem<String>(value: 'remove', child: Text('从列表移除')),
          ],
        ),
        onTap: () => _openFile(entry.path),
      ),
    );
  }

  /// 本次会话新建白板卡片（原内存列表行为保持不变）。
  Widget _boardCard(WbRecentBoard board, WbThemeColors colors) {
    return Card(
      color: colors.surface,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(LinearIcons.page, color: colors.primary),
        title: Text(board.name),
        subtitle: Text(_relativeTime(board.updatedAt)),
        trailing: PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (String value) {
            if (value == 'open') {
              context.push(WbRoutes.boardPath(board.id));
            } else if (value == 'remove') {
              _removeBoard(board);
            }
          },
          itemBuilder: (BuildContext context) =>
              const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(value: 'open', child: Text('打开')),
            PopupMenuItem<String>(value: 'remove', child: Text('从列表移除')),
          ],
        ),
        onTap: () => context.push(WbRoutes.boardPath(board.id)),
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
    final WbThemeColors colors = context.wbColors;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(LinearIcons.folder, size: 56, color: colors.border),
          const SizedBox(height: 16),
          Text('还没有白板', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '点击右下角「新建白板」开始创作',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.icon),
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
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: available ? '引擎已加载：${ffi.loadedFrom}' : '引擎未加载（演示模式）',
      child: Chip(
        avatar: Icon(
          available ? LinearIcons.cloud : LinearIcons.offline,
          size: 16,
        ),
        label: Text(available ? '引擎就绪' : '演示模式'),
        labelStyle: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: colors.icon),
        side: BorderSide(color: colors.border),
        backgroundColor: colors.surface,
      ),
    );
  }
}
