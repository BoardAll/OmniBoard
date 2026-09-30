/// 参与者面板（编辑页 endDrawer；T1.7 桌面协作 UI · M1 基础版）。
///
/// - 列表：参与者（id + 角色 + 「我」标记），来源
///   [WbCollabService.participantList]（引擎 room 快照；自标识为 M1
///   末位推断，见 [WbCollabParticipant]）；
/// - 状态行：连接状态（[WbSyncStatus] 五态）；
/// - M1 仅展示：光标 / 选区 / 软锁等 M2 内容不在此实现。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../../services/sync_service.dart';

/// 参与者面板（Drawer 形态；`Scaffold.endDrawer` 挂载）。
class WbParticipantsPanel extends StatelessWidget {
  /// 创建面板。
  const WbParticipantsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final WbCollabService sync = context.watch<WbCollabService>();
    final WbThemeColors colors = context.wbColors;
    final List<WbCollabParticipant> participants = sync.participantList;
    return Drawer(
      key: const Key('wb-participants-panel'),
      backgroundColor: colors.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(context, participants.length),
            _statusLine(context, sync),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: participants.isEmpty
                  ? _EmptyHint(status: sync.status)
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: participants.length,
                      itemBuilder: (BuildContext context, int index) {
                        final WbCollabParticipant participant =
                            participants[index];
                        final WbThemeColors rowColors = context.wbColors;
                        return ListTile(
                          key: ValueKey<String>(
                            'wb-participant-${participant.id}',
                          ),
                          dense: true,
                          leading: WbAvatar(
                            name: participant.id,
                            size: WbAvatarSize.s,
                            backgroundColor: participant.isSelf
                                ? rowColors.primary.withValues(alpha: 0.18)
                                : null,
                          ),
                          title: Text(
                            participant.isSelf
                                ? '${participant.id}（我）'
                                : participant.id,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_roleLabel(participant.role)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 面板头：图标 + 标题 + 计数 + 关闭。
  Widget _header(BuildContext context, int count) {
    final WbThemeColors colors = context.wbColors;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: <Widget>[
          Icon(LinearIcons.members, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Text('参与者', style: text.titleSmall),
          const SizedBox(width: 6),
          Text('($count)', style: text.bodySmall?.copyWith(color: colors.icon)),
          const Spacer(),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(LinearIcons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  /// 状态行：圆点 + 文案（与 [WbSyncStatus] 对齐）。
  Widget _statusLine(BuildContext context, WbCollabService sync) {
    final WbThemeColors colors = context.wbColors;
    final Color dot = switch (sync.status) {
      WbSyncStatus.online || WbSyncStatus.syncing => colors.primary,
      WbSyncStatus.error => Theme.of(context).colorScheme.error,
      WbSyncStatus.offline || WbSyncStatus.connecting => colors.icon,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _statusText(sync),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.icon),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 状态行文案。
  static String _statusText(WbCollabService sync) => switch (sync.status) {
        WbSyncStatus.offline => sync.lastError.isEmpty
            ? '未连接到协作服务（单机模式）'
            : '未连接协作服务：${sync.lastError}',
        WbSyncStatus.connecting =>
          sync.reconnectCount > 0 ? '网络中断，正在重连…' : '正在连接协作服务…',
        WbSyncStatus.online => '已连接 · ${sync.participantList.length} 人在线',
        WbSyncStatus.syncing => sync.pendingCount > 0
            ? '同步中 · ${sync.pendingCount} 条待确认'
            : '同步中',
        WbSyncStatus.error =>
          sync.lastError.isEmpty ? '同步错误' : '同步错误：${sync.lastError}',
      };
}

/// 空态提示（无参与者 / 未连接）。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.status});

  final WbSyncStatus status;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final String hint = switch (status) {
      WbSyncStatus.offline => '未连接到协作服务，其他人上线后会显示在这里',
      WbSyncStatus.connecting => '正在连接…',
      WbSyncStatus.online || WbSyncStatus.syncing => '等待其他参与者加入…',
      WbSyncStatus.error => '同步错误，暂时无法获取参与者',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LinearIcons.members, size: 32, color: colors.icon),
            const SizedBox(height: 8),
            Text('暂无其他参与者', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              hint,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.icon),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 角色中文名（协同设计文档角色枚举；未知值原样展示）。
String _roleLabel(String role) => switch (role) {
      'Host' => '主持人',
      'CoHost' => '联席主持人',
      'Presenter' => '演示者',
      'Participant' => '参与者',
      'Viewer' => '观看者',
      'Guest' => '访客',
      _ => role.isEmpty ? '成员' : role,
    };
