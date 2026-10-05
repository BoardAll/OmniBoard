/// 白板列表页（首页）：空态引导 + 新建白板 + 主题切换。
///
/// 列表为页内内存数据（会话内保留「新建白板」产生的条目），
/// 持久化 / 服务端同步待接入。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../routes.dart';
import '../state/theme_state.dart';
import '../widgets/core_status_chip.dart';

/// 白板条目（列表页内存模型；持久化待接入）。
class WbWebBoard {
  /// 创建条目。
  const WbWebBoard({
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
  /// 创建列表页。
  const BoardListPage({super.key});

  @override
  State<BoardListPage> createState() => _BoardListPageState();
}

class _BoardListPageState extends State<BoardListPage> {
  final List<WbWebBoard> _boards = <WbWebBoard>[];

  void _createBoard() {
    final String id = 'board-${DateTime.now().millisecondsSinceEpoch}';
    final WbWebBoard board = WbWebBoard(
      id: id,
      name: '未命名白板 ${_boards.length + 1}',
      updatedAt: DateTime.now(),
    );
    setState(() => _boards.insert(0, board));
    _openBoard(board);
  }

  void _openBoard(WbWebBoard board) {
    context.push(WbWebRoutes.boardPath(board.id, name: board.name));
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的白板'),
        backgroundColor: colors.surface,
        actions: const <Widget>[
          WbCoreStatusChip(),
          _ThemeMenu(),
          SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createBoard,
        icon: const Icon(LinearIcons.add),
        label: const Text('新建白板'),
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (_boards.isEmpty) {
            return const _EmptyBoardsHint();
          }
          // 响应式：宽屏（≥600）网格，窄屏列表。
          if (constraints.maxWidth >= 600) {
            return _buildGrid();
          }
          return _buildList();
        },
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 360,
        mainAxisExtent: 132,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _boards.length,
      itemBuilder: (BuildContext context, int index) {
        final WbWebBoard board = _boards[index];
        return _BoardCard(board: board, onTap: () => _openBoard(board));
      },
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _boards.length,
      itemBuilder: (BuildContext context, int index) {
        final WbWebBoard board = _boards[index];
        final WbThemeColors colors = context.wbColors;
        return Card(
          color: colors.cardBackground,
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: Icon(LinearIcons.board, color: colors.primary),
            title: Text(board.name),
            subtitle: WbText(
              _relativeTime(board.updatedAt),
              variant: WbTextVariant.caption,
            ),
            onTap: () => _openBoard(board),
          ),
        );
      },
    );
  }
}

/// 空态引导（无白板时）。
class _EmptyBoardsHint extends StatelessWidget {
  const _EmptyBoardsHint();

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Center(
      key: const Key('wb-board-list-empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(LinearIcons.board, size: 40, color: colors.icon),
          const SizedBox(height: 12),
          const WbText('还没有白板', variant: WbTextVariant.title),
          const SizedBox(height: 6),
          WbText(
            '点击右下角「新建白板」开始创作',
            variant: WbTextVariant.caption,
            color: colors.icon,
          ),
        ],
      ),
    );
  }
}

/// 白板卡片（网格视图）。
class _BoardCard extends StatelessWidget {
  const _BoardCard({required this.board, required this.onTap});

  final WbWebBoard board;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Card(
      color: colors.cardBackground,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.cardBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  WbIcon(LinearIcons.board, color: colors.primary),
                  const Spacer(),
                  WbText(
                    _relativeTime(board.updatedAt),
                    variant: WbTextVariant.caption,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                board.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              WbText(
                '点击进入编辑',
                variant: WbTextVariant.caption,
                color: colors.icon,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主题切换菜单（9 个内置主题）。
class _ThemeMenu extends StatelessWidget {
  const _ThemeMenu();

  @override
  Widget build(BuildContext context) {
    final WbWebThemeState theme = context.watch<WbWebThemeState>();
    return PopupMenuButton<String>(
      tooltip: '切换主题',
      icon: const Icon(LinearIcons.palette),
      onSelected: theme.select,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final WbThemeData item in theme.available)
          PopupMenuItem<String>(
            value: item.id,
            child: Row(
              children: <Widget>[
                Icon(
                  item.id == theme.current.id
                      ? LinearIcons.check
                      : LinearIcons.palette,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(item.name),
              ],
            ),
          ),
      ],
    );
  }
}

/// 相对时间描述（刚刚 / N 分钟前 / N 小时前 / N 天前）。
String _relativeTime(DateTime time) {
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
