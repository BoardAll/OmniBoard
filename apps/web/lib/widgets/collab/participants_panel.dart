/// 参与者面板（编辑页 endDrawer 挂载；W1 协作层 / T1.8 + M3 互动 / T3.4）。
///
/// - 列表：参与者（userId + 角色 + 「我」标记），随 `board:participants`
///   增量实时更新；掉线重连期间不移除（§5.9 防闪烁）；
/// - M3 标记：举手（hand）／Host・Presenter 角色徽标高亮／临时写权「可编辑」；
/// - M3 操作（Host/CoHost）：对低级别成员「授权控制」、对已授权者「收回控制」
///   （`interactive:grantControl` / `revokeControl`，轻量 ack；服务端为权威；
///   举手仅作视觉标记，不设「先举手才能授权」前置——与桌面端一致）；
/// - 状态行：连接状态（连接中 / 已连接 / 重连中 / 未连接）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../../services/realtime_service.dart';
import 'interactive_feedback.dart';

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
                        return _buildRow(context, realtime, participants[index]);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, WbRealtimeService realtime, WbCollabParticipant participant) {
    final bool isSelf = realtime.userId != null && participant.userId == realtime.userId;
    final bool selfReconnecting = isSelf && realtime.status == WbRealtimeStatus.reconnecting;
    // M3 管理入口：本地 ≥CoHost 且目标非 Host/CoHost（对齐服务端角色矩阵；
    // 举手仅作视觉标记，不设「先举手才能授权」前置——与桌面端一致）。
    final bool targetManageable = !isSelf && participant.role != 'Host' && participant.role != 'CoHost';
    final bool showGrant = realtime.canManageInteractions &&
        targetManageable &&
        !participant.grantedWrite;
    final bool showRevoke =
        realtime.canManageInteractions && targetManageable && participant.grantedWrite;
    return ListTile(
      dense: true,
      leading: WbAvatar(name: participant.userId, size: WbAvatarSize.s),
      title: Text(
        isSelf ? '${participant.userId}（我）' : participant.userId,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: _subtitle(context, participant),
      trailing: _trailing(
        context,
        participant,
        selfReconnecting: selfReconnecting,
        showGrant: showGrant,
        showRevoke: showRevoke,
        onGrant: () => unawaited(_grant(context, realtime, participant)),
        onRevoke: () => unawaited(_revoke(context, realtime, participant)),
      ),
    );
  }

  /// 角色行：Host/Presenter 徽标高亮；grantedWrite → 「可编辑」标记。
  Widget _subtitle(BuildContext context, WbCollabParticipant participant) {
    final WbThemeColors colors = context.wbColors;
    final Widget roleWidget;
    if (participant.role == 'Host' || participant.role == 'Presenter') {
      final bool isHost = participant.role == 'Host';
      roleWidget = _MiniTag(
        key: Key('wb-role-badge-${participant.userId}'),
        label: _roleLabel(participant.role),
        background: isHost ? colors.primary : colors.primary.withValues(alpha: 0.15),
        foreground: isHost ? WbColorUtils.contrastText(colors.primary) : colors.primary,
      );
    } else {
      roleWidget = Text(_roleLabel(participant.role));
    }
    return Row(
      children: <Widget>[
        Flexible(child: roleWidget),
        if (participant.grantedWrite) ...<Widget>[
          const SizedBox(width: 6),
          _MiniTag(
            key: Key('wb-granted-write-${participant.userId}'),
            label: '可编辑',
            background: colors.primary.withValues(alpha: 0.12),
            foreground: colors.primary,
            icon: LinearIcons.pen,
          ),
        ],
      ],
    );
  }

  Widget _trailing(
    BuildContext context,
    WbCollabParticipant participant, {
    required bool selfReconnecting,
    required bool showGrant,
    required bool showRevoke,
    required VoidCallback onGrant,
    required VoidCallback onRevoke,
  }) {
    final WbThemeColors colors = context.wbColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (participant.handRaised)
          Padding(
            key: Key('wb-hand-raised-${participant.userId}'),
            padding: const EdgeInsets.only(right: 2),
            child: Tooltip(
              message: '已举手',
              child: Icon(LinearIcons.hand, size: 18, color: colors.primary),
            ),
          ),
        if (showGrant)
          _MiniIconButton(
            key: Key('wb-grant-control-${participant.userId}'),
            tooltip: '授权控制',
            icon: LinearIcons.permission,
            onPressed: onGrant,
          ),
        if (showRevoke)
          _MiniIconButton(
            key: Key('wb-revoke-control-${participant.userId}'),
            tooltip: '收回控制',
            icon: LinearIcons.lock,
            onPressed: onRevoke,
          ),
        if (selfReconnecting)
          WbText('重连中', variant: WbTextVariant.caption, color: colors.icon),
      ],
    );
  }

  Future<void> _grant(BuildContext context, WbRealtimeService realtime, WbCollabParticipant participant) async {
    final bool ok = await realtime.grantControl(participant.userId);
    if (!ok && context.mounted) {
      showWbInteractiveFailure(context, '授权控制');
    }
  }

  Future<void> _revoke(BuildContext context, WbRealtimeService realtime, WbCollabParticipant participant) async {
    final bool ok = await realtime.revokeControl(participant.userId);
    if (!ok && context.mounted) {
      showWbInteractiveFailure(context, '收回控制');
    }
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

/// 小号胶囊标记（角色徽标 / 「可编辑」）。
class _MiniTag extends StatelessWidget {
  const _MiniTag({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: WbTypography.caption.copyWith(
              color: foreground,
              fontWeight: WbTypography.weightMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// 小号图标按钮（参与者行内操作；32×32 紧凑约束）。
class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18, color: colors.primary),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: onPressed,
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
