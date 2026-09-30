/// 协作连接状态 chip（编辑页 AppBar；W1 协作层 / T1.8）。
///
/// 展示 [WbRealtimeStatus] 中文状态：
/// - `idle`：隐藏（协作未启用 → 单机模式，功能零阻塞，§9）；
/// - `connecting` / `connected` / `reconnecting` / `disconnected`：显示对应状态。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../../services/realtime_service.dart';

/// 协作连接状态 chip。
class WbCollabStatusChip extends StatelessWidget {
  /// 创建 chip。
  const WbCollabStatusChip({super.key});

  @override
  Widget build(BuildContext context) {
    final WbRealtimeService realtime = context.watch<WbRealtimeService>();
    final WbRealtimeStatus status = realtime.status;
    if (status == WbRealtimeStatus.idle) {
      return const SizedBox.shrink();
    }
    final WbThemeColors colors = context.wbColors;
    final String label = switch (status) {
      WbRealtimeStatus.idle => '',
      WbRealtimeStatus.connecting => '连接中',
      WbRealtimeStatus.connected => '已连接',
      WbRealtimeStatus.reconnecting => '重连中',
      WbRealtimeStatus.disconnected => '未连接',
    };
    final IconData icon = switch (status) {
      WbRealtimeStatus.idle => LinearIcons.offline,
      WbRealtimeStatus.connecting => LinearIcons.sync,
      WbRealtimeStatus.connected => LinearIcons.members,
      WbRealtimeStatus.reconnecting => LinearIcons.sync,
      WbRealtimeStatus.disconnected => LinearIcons.offline,
    };
    return Tooltip(
      message: _tooltip(realtime),
      child: Chip(
        key: const Key('wb-collab-status-chip'),
        avatar: Icon(
          icon,
          size: 16,
          color: status == WbRealtimeStatus.connected ? colors.primary : colors.icon,
        ),
        label: Text(label),
        labelStyle: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: colors.icon),
        side: BorderSide(color: colors.border),
        backgroundColor: colors.surface,
      ),
    );
  }

  String _tooltip(WbRealtimeService realtime) {
    final String? error = realtime.lastError?.message;
    final String suffix = error == null ? '' : '（$error）';
    return switch (realtime.status) {
      WbRealtimeStatus.idle => '协作服务未启用',
      WbRealtimeStatus.connecting => '正在连接协作服务…',
      WbRealtimeStatus.connected => '协作服务已连接，当前 ${realtime.participants.length} 人在线',
      WbRealtimeStatus.reconnecting => '连接中断，正在重连…$suffix',
      WbRealtimeStatus.disconnected => '协作服务未连接$suffix',
    };
  }
}
