/// 白板列表页（首页）：空态引导 + 新建白板 + 主题切换。
///
/// 列表为页内内存数据（会话内保留「新建白板」产生的条目），
/// 持久化 / 服务端同步待接入。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_cast/cast.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../routes.dart';
import '../services/realtime_service.dart';
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

  /// 首页「白板」入口：继续最近白板，没有则新建；默认不自动开启投屏。
  void _openWhiteboard() {
    if (_boards.isNotEmpty) {
      _openBoard(_boards.first);
      return;
    }
    _createBoard();
  }

  /// 首页「局域网投屏」入口：打开同一套白板并自动开启投屏接收。
  void _openCastBoard() {
    final String id = 'board-cast-${DateTime.now().millisecondsSinceEpoch}';
    final WbWebBoard board = WbWebBoard(
      id: id,
      name: '投屏白板',
      updatedAt: DateTime.now(),
    );
    setState(() => _boards.insert(0, board));
    context.push(WbWebRoutes.boardPath(id, cast: true));
  }

  /// 发送端：输入四位投屏码加入接收端房间，并在白板内展示推流状态。
  Future<void> _joinCastAsSender() async {
    final WbCastController cast = context.read<WbCastController>();
    final bool? joined = await WbCastJoinDialog.show(
      context,
      cast,
      deviceName: '浏览器设备',
      endpoint: kWbRealtimeEndpoint,
    );
    if (!mounted || joined != true) {
      return;
    }
    final String id = 'board-cast-${DateTime.now().millisecondsSinceEpoch}';
    final WbWebBoard board = WbWebBoard(
      id: id,
      name: '投屏发送端',
      updatedAt: DateTime.now(),
    );
    setState(() => _boards.insert(0, board));
    unawaited(context.push(WbWebRoutes.boardPath(id, castSender: true)));
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
          final bool wide = constraints.maxWidth >= 780;
          return Column(
            children: <Widget>[
              // 两个主入口：白板（默认不开启投屏）/ 局域网投屏（自动接收）。
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: _buildEntries(wide),
              ),
              Expanded(
                child: _boards.isEmpty
                    ? const _EmptyBoardsHint()
                    : (constraints.maxWidth >= 600
                        ? _buildGrid()
                        : _buildList()),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 首页双卡片入口（宽屏左右并排，窄屏上下排列）。
  Widget _buildEntries(bool wide) {
    final Widget whiteboard = _HomeEntryCard(
      icon: LinearIcons.board,
      title: '白板',
      subtitle: '打开普通白板；默认不自动开启投屏接收',
      accent: context.wbColors.primary,
      onTap: _openWhiteboard,
    );
    final Widget cast = _HomeEntryCard(
      icon: LinearIcons.cloud,
      title: '局域网投屏',
      subtitle: '打开同一套白板并自动开启接收；投屏码即房间号（发送端需 HTTPS / localhost）',
      accent: const Color(0xFF12B76A),
      onTap: _openCastBoard,
      footer: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => unawaited(_joinCastAsSender()),
          icon: const Icon(Icons.keyboard_alt_outlined, size: 15),
          label: const Text('输入投屏码'),
          style: OutlinedButton.styleFrom(
            foregroundColor: context.wbColors.primary,
            side: BorderSide(
              color: context.wbColors.primary.withValues(alpha: 0.35),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
    if (wide) {
      return SizedBox(
        height: 200,
        child: Row(
          children: <Widget>[
            Expanded(child: whiteboard),
            const SizedBox(width: 16),
            Expanded(child: cast),
          ],
        ),
      );
    }
    return Column(
      children: <Widget>[
        SizedBox(height: 170, child: whiteboard),
        const SizedBox(height: 12),
        SizedBox(height: 190, child: cast),
      ],
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

/// 首页主入口卡片（白板 / 局域网投屏）：悬停变色 + 点击进入。
class _HomeEntryCard extends StatefulWidget {
  const _HomeEntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;
  final Widget? footer;

  @override
  State<_HomeEntryCard> createState() => _HomeEntryCardState();
}

class _HomeEntryCardState extends State<_HomeEntryCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (PointerEnterEvent _) => setState(() => _hovered = true),
      onExit: (PointerExitEvent _) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: _hovered
              ? widget.accent.withValues(alpha: 0.06)
              : colors.cardBackground,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _hovered
                ? widget.accent.withValues(alpha: 0.55)
                : colors.cardBorder,
            width: _hovered ? 1.4 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: widget.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          widget.icon,
                          size: 22,
                          color: widget.accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            color: colors.icon,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.subtitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: colors.icon.withValues(alpha: 0.78),
                    ),
                  ),
                  if (widget.footer != null) ...<Widget>[
                    const Spacer(),
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
