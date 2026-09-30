/// 协作连接状态 chip（编辑页 AppBar 常驻；T1.7 桌面协作 UI）。
///
/// [WbSyncStatus] 五态映射：
/// - `offline`：灰色「离线」（单机 / 未连接，本地编辑零阻塞）；
/// - `connecting`（含传输重连）：「连接中」；
/// - `online`：「已连接」；
/// - `syncing`：「同步中」（pending 增量上传 / 下行应用）；
/// - `error`：「同步错误」（红色 + 悬停错误详情）。
///
/// 悬停提示携带端点 / 在线人数 / 延迟 / 待确认 / 错误详情等指标。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../../services/sync_service.dart';

/// 协作连接状态 chip。
class WbSyncStatusChip extends StatelessWidget {
  /// 创建 chip。
  const WbSyncStatusChip({super.key});

  @override
  Widget build(BuildContext context) {
    final WbCollabService sync = context.watch<WbCollabService>();
    final WbThemeColors colors = context.wbColors;
    final WbSyncStatus status = sync.status;
    final IconData icon = switch (status) {
      WbSyncStatus.offline => LinearIcons.offline,
      WbSyncStatus.connecting => LinearIcons.sync,
      WbSyncStatus.online => LinearIcons.cloud,
      WbSyncStatus.syncing => LinearIcons.sync,
      WbSyncStatus.error => LinearIcons.error,
    };
    final Color accent = switch (status) {
      WbSyncStatus.online || WbSyncStatus.syncing => colors.primary,
      WbSyncStatus.error => Theme.of(context).colorScheme.error,
      WbSyncStatus.offline || WbSyncStatus.connecting => colors.icon,
    };
    return Tooltip(
      key: const Key('wb-sync-status-chip'),
      message: _tooltip(sync),
      child: Chip(
        avatar: Icon(icon, size: 16, color: accent),
        label: Text(status.label),
        labelStyle:
            Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.icon),
        side: BorderSide(color: colors.border),
        backgroundColor: colors.surface,
      ),
    );
  }

  /// 悬停提示：按状态组合端点 / 在线人数 / 延迟 / 待确认 / 错误详情。
  String _tooltip(WbCollabService sync) {
    final String latency =
        sync.latencyMs > 0 ? ' · 延迟 ${sync.latencyMs}ms' : '';
    return switch (sync.status) {
      WbSyncStatus.offline => '协作服务未连接（单机模式）：${sync.endpoint}',
      WbSyncStatus.connecting => sync.reconnectCount > 0
          ? '连接中断，正在重连（第 ${sync.reconnectCount} 次）…'
          : '正在连接协作服务…（${sync.endpoint}）',
      WbSyncStatus.online =>
        '协作服务已连接 · ${sync.participantList.length} 人在线$latency',
      WbSyncStatus.syncing => '正在同步增量'
          '${sync.pendingCount > 0 ? ' · ${sync.pendingCount} 条待确认' : ''}'
          '$latency',
      WbSyncStatus.error => sync.lastError.isEmpty
          ? '同步错误（详见协作设置）'
          : '同步错误：${sync.lastError}',
    };
  }
}
