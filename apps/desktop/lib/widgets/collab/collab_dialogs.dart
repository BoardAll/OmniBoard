/// 互动白板协同对话框（加入房间 / 房间信息与退出；交互改造）。
///
/// - [showWbCollabJoinDialog]：输入房间号，确认返回去空格后的房间号；
///   取消 / 空输入返回 null。两端输入相同房间号即以该房间为同步通道；
/// - [showWbCollabRoomDialog]：展示房间号 / 服务器地址 / 状态与人数；
///   「退出互动白板」返回 true（由挂载方执行 stop），关闭返回 null。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_theme/theme.dart';

import '../../services/sync_service.dart';

/// 加入对话框：返回房间号；取消返回 null。
///
/// [serverHint] 为当前生效的协作服务器地址（展示用，来自设置面板）。
/// [initialRoom] 预填房间号（重试场景复用上次输入）。
Future<String?> showWbCollabJoinDialog(
  BuildContext context, {
  required String serverHint,
  String initialRoom = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _WbCollabJoinDialog(serverHint: serverHint, initialRoom: initialRoom),
  );
}

/// 房间信息对话框：返回 true = 用户要求退出互动白板；其余返回 null。
Future<bool?> showWbCollabRoomDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => const _WbCollabRoomDialog(),
  );
}

/// 加入对话框（房间号输入 + 服务器地址提示）。
class _WbCollabJoinDialog extends StatefulWidget {
  const _WbCollabJoinDialog({
    required this.serverHint,
    required this.initialRoom,
  });

  /// 当前协作服务器地址（提示文案）。
  final String serverHint;

  /// 预填房间号。
  final String initialRoom;

  @override
  State<_WbCollabJoinDialog> createState() => _WbCollabJoinDialogState();
}

class _WbCollabJoinDialogState extends State<_WbCollabJoinDialog> {
  late final TextEditingController _roomController;

  @override
  void initState() {
    super.initState();
    _roomController = TextEditingController(text: widget.initialRoom);
  }

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  bool get _valid => _roomController.text.trim().isNotEmpty;

  void _confirm() {
    final String room = _roomController.text.trim();
    if (room.isEmpty) {
      return;
    }
    Navigator.of(context).pop(room);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      key: const ValueKey<String>('wb-collab-join-dialog'),
      title: const Text('加入互动白板'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('wb-collab-room-field'),
              controller: _roomController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '房间号'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _confirm(),
            ),
            const SizedBox(height: 12),
            Text(
              '两端输入相同的房间号即可实时同步；'
              '服务器地址：${widget.serverHint.isEmpty ? '未配置' : widget.serverHint}',
              style: text.bodySmall?.copyWith(color: colors.icon),
            ),
            const SizedBox(height: 4),
            Text(
              '加入后本地内容保持可编辑；退出房间即回到本地模式。',
              style: text.bodySmall?.copyWith(color: colors.icon),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('wb-collab-join-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('wb-collab-join-confirm'),
          style: FilledButton.styleFrom(backgroundColor: colors.primary),
          onPressed: _valid ? _confirm : null,
          child: const Text('加入'),
        ),
      ],
    );
  }
}

/// 房间信息对话框（实时状态 / 人数；提供退出入口）。
class _WbCollabRoomDialog extends StatelessWidget {
  const _WbCollabRoomDialog();

  @override
  Widget build(BuildContext context) {
    final WbCollabService? sync = context.watch<WbCollabService?>();
    final WbThemeColors colors = context.wbColors;
    final TextTheme text = Theme.of(context).textTheme;
    final String room = sync?.boardId ?? '';
    final String endpoint = sync?.endpoint ?? '';
    final String status = sync?.status.label ?? '未挂载';
    final int online = sync?.participantList.length ?? 0;
    final String error = sync?.lastError ?? '';
    final bool offerReconnect = sync?.shouldOfferReconnect ?? false;
    return AlertDialog(
      key: const ValueKey<String>('wb-collab-room-dialog'),
      title: const Text('互动白板'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _InfoRow(label: '房间号', value: room.isEmpty ? '-' : room),
            const SizedBox(height: 8),
            _InfoRow(
              label: '服务器',
              value: endpoint.isEmpty ? '未配置' : endpoint,
            ),
            const SizedBox(height: 8),
            _InfoRow(label: '状态', value: '$status · $online 人在线'),
            if (error.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              _InfoRow(label: '最近错误', value: error),
            ],
            if (offerReconnect) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '连接多次失败（已重连 ${sync?.reconnectCount ?? 0} 次），'
                '可尝试重新连接。',
                style: text.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '两端输入相同房间号即自动同步；退出后回到本地模式（内容保留）。',
              style: text.bodySmall?.copyWith(color: colors.icon),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (offerReconnect)
          OutlinedButton(
            key: const ValueKey<String>('wb-collab-room-reconnect'),
            onPressed: sync == null ? null : () => _reconnect(context, sync),
            child: const Text('重新连接'),
          ),
        TextButton(
          key: const ValueKey<String>('wb-collab-room-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(
          key: const ValueKey<String>('wb-collab-room-leave'),
          style: FilledButton.styleFrom(backgroundColor: colors.primary),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('退出互动白板'),
        ),
      ],
    );
  }

  /// 手动重连（重连预算耗尽后的恢复入口）：disconnect + 同房 start。
  ///
  /// 结果就近轻提示反馈（对话框保持打开，可再次尝试或退出）。
  static Future<void> _reconnect(
    BuildContext context,
    WbCollabService service,
  ) async {
    final bool ok = await service.reconnect();
    if (!context.mounted) {
      return;
    }
    final String reason = service.lastError.trim();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok ? '已重新连接互动白板' : '重连失败：${reason.isEmpty ? '未知错误' : reason}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

/// 信息行（标签 + 值）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: text.bodySmall?.copyWith(color: colors.icon),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: text.bodyMedium,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
