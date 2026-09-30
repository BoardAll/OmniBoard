/// 参与者面板（编辑页 endDrawer 挂载；W1 协作层 / T1.8）。
///
/// - 列表：参与者（userId + 角色 + 「我」标记），随 `board:participants`
///   增量实时更新；掉线重连期间不移除（§5.9 防闪烁）；
/// - 状态行：连接状态（连接中 / 已连接 / 重连中 / 未连接）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../../services/realtime_service.dart';

/// 参与者面板（Drawer 形态；`Scaffold.endDrawer` 挂载）。
class WbParticipantsPanel extends StatelessWidget {
  /// 创建面板。
  const WbParticipantsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final WbRealtimeService realtime = context.watch<WbRealtimeService>();
    final WbThemeColors colors = context.wbColors;
    final List<WbCollabParticipant> participants = realtime.participants;
    return Drawer(
      key: const Key('wb-participants-panel'),
      backgroundColor: colors.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(context, participants.length),
            _statusLine(context, realtime),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: participants.isEmpty
                  ? _EmptyHint(status: realtime.status)
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: participants.length,
                      itemBuilder: (BuildContext context, int index) {
                        final WbCollabParticipant participant = participants[index];
                        final bool isSelf =
                            realtime.userId != null && participant.userId == realtime.userId;
                        final bool selfReconnecting =
                            isSelf && realtime.status == WbRealtimeStatus.reconnecting;
                        return ListTile(
                          dense: true,
                          leading: WbAvatar(name: participant.userId, size: WbAvatarSize.s),
                          title: Text(
                            isSelf ? '${participant.userId}（我）' : participant.userId,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_roleLabel(participant.role)),
                          trailing: selfReconnecting
                              ? WbText('重连中', variant: WbTextVariant.caption, color: colors.icon)
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, int count) {
    final WbThemeColors colors = context.wbColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: <Widget>[
          Icon(LinearIcons.members, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          const WbText('参与者', variant: WbTextVariant.title),
          const SizedBox(width: 6),
          WbText('($count)', variant: WbTextVariant.caption),
          const Spacer(),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(LinearIcons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _statusLine(BuildContext context, WbRealtimeService realtime) {
    final WbThemeColors colors = context.wbColors;
    final String text = switch (realtime.status) {
      WbRealtimeStatus.idle => '协作服务未启用（单机模式）',
      WbRealtimeStatus.connecting => '正在连接协作服务…',
      WbRealtimeStatus.connected => '已连接 · ${realtime.participants.length} 人在线',
      WbRealtimeStatus.reconnecting => '网络中断，正在重连…',
      WbRealtimeStatus.disconnected => realtime.lastError == null
          ? '未连接协作服务（单机模式）'
          : '未连接协作服务：${realtime.lastError!.message}',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: realtime.status == WbRealtimeStatus.connected ? colors.primary : colors.icon,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: WbText(
              text,
              variant: WbTextVariant.caption,
              color: colors.icon,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态提示（无参与者 / 未连接）。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.status});

  final WbRealtimeStatus status;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final String hint = switch (status) {
      WbRealtimeStatus.idle || WbRealtimeStatus.disconnected => '未连接到协作服务，其他人上线后会显示在这里',
      WbRealtimeStatus.connecting || WbRealtimeStatus.reconnecting => '正在连接…',
      WbRealtimeStatus.connected => '等待其他参与者加入…',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LinearIcons.members, size: 32, color: colors.icon),
            const SizedBox(height: 8),
            const WbText('暂无其他参与者', variant: WbTextVariant.label),
            const SizedBox(height: 4),
            WbText(
              hint,
              variant: WbTextVariant.caption,
              color: colors.icon,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 角色中文名（§5.1 角色枚举；未知值原样展示）。
String _roleLabel(String role) => switch (role) {
      'Host' => '主持人',
      'CoHost' => '联席主持人',
      'Presenter' => '演示者',
      'Participant' => '参与者',
      'Viewer' => '观看者',
      'Guest' => '访客',
      _ => role.isEmpty ? '成员' : role,
    };
