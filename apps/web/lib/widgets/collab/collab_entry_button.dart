/// 互动白板入口按钮（编辑页 AppBar；交互对齐桌面端：默认本地，按需入房）。
///
/// 交互约定：
/// - 白板启动默认**本地**（不自动加入协同房间）；
/// - 需要协同时点击本入口 → 输入房间号 → 以房间号为同步通道加入；
///   两端输入相同房间号即自动同步；
/// - 未入房显示「互动白板」按钮；在房 / 连接中 / 失败待处理显示状态
///   chip（点击打开房间信息 / 退出）。点击行为由挂载方注入（[onPressed]）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';

import '../../services/realtime_service.dart';
import 'collab_status_chip.dart';

/// 互动白板入口按钮（未入房：文字按钮；在房：状态 chip 即入口）。
class WbCollabEntryButton extends StatelessWidget {
  /// 创建入口按钮。
  const WbCollabEntryButton({super.key, required this.onPressed});

  /// 点击回调（挂载方决定弹「加入房间」还是「房间信息」对话框）。
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final WbRealtimeService realtime = context.watch<WbRealtimeService>();
    if (realtime.boardId != null) {
      // 在房 / 连接中 / 失败待处理：状态 chip 即入口（点击查看房间 / 退出）。
      return InkWell(
        key: const Key('wb-collab-entry'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: const WbCollabStatusChip(),
      );
    }
    return TextButton.icon(
      key: const Key('wb-collab-entry'),
      onPressed: onPressed,
      icon: const Icon(LinearIcons.cloud, size: 18),
      label: const Text('互动白板'),
    );
  }
}
