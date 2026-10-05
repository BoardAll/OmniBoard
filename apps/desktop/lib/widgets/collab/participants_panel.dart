/// 参与者面板（Drawer 形态；`Scaffold.endDrawer` 挂载）。
///
/// - 列表：参与者（id + 角色 + 「我」标记 + M3 标记：演示中 / 已举手 /
///   已授权），来源 [WbCollabService.participantList]（引擎 room 快照；
///   自标识为 M1 末位推断，见 [WbCollabParticipant]）；
/// - 行内操作（M3）：他人条目「跟随 / 停止跟随」（经 [WbFollowController]；
///   未挂载时降级为直接发 `interactive:follow`）；CoHost+ 对低级别成员的
///   「授权控制 / 收回控制」与「移除成员」（经 [WbCollabService]，服务端
///   校验兜底）；
/// - 房间操作区（M3 底部）：非 CoHost+ 自身的「举手 / 收手」；CoHost+ 与
///   演示者的「开始演示 / 结束演示」；演示中展示「演示中 · 演示者」署名行；
/// - 状态行：连接状态（[WbSyncStatus] 五态）；M1 展示语义保持不变。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../../services/sync_service.dart';
import '../../state/follow_controller.dart';

/// 参与者面板（Drawer 形态；`Scaffold.endDrawer` 挂载）。
class WbParticipantsPanel extends StatelessWidget {
  /// 创建面板。
  const WbParticipantsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final WbCollabService sync = context.watch<WbCollabService>();
    final WbFollowController? follow = _maybeFollow(context);
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
                        return _ParticipantRow(
                          participant: participants[index],
                          sync: sync,
                          follow: follow,
                        );
                      },
                    ),
            ),
            _roomActions(context, sync),
          ],
        ),
      ),
    );
  }

  /// 容错读取跟随控制器（无该 Provider 的嵌入 / 测试场景返回 null，
  /// 跟随按钮降级为直接发请求）。
  WbFollowController? _maybeFollow(BuildContext context) {
    try {
      return context.watch<WbFollowController>();
    } on ProviderNotFoundException {
      return null;
    }
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

  /// 房间操作区（M3）：自身「举手 / 收手」（非 CoHost+）与
  /// 「开始演示 / 结束演示」（CoHost+；演示者亦可结束演示）；
  /// 演示中附「演示中 · 演示者」署名行。
  Widget _roomActions(BuildContext context, WbCollabService sync) {
    final bool showHand = sync.canRaiseHand || sync.selfHandRaised;
    final bool showPresent = sync.canManageInteractions ||
        (sync.presentMode && sync.isPresenterOrHigher);
    final bool showPresentInfo = sync.presentMode;
    if (!showHand && !showPresent && !showPresentInfo) {
      return const SizedBox.shrink();
    }
    final WbThemeColors colors = context.wbColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Divider(height: 1, color: colors.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (showPresentInfo)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        LinearIcons.visible,
                        size: 14,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '演示中 · ${_shortId(sync.presenterId)}',
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              if (showHand)
                OutlinedButton.icon(
                  key: const Key('wb-panel-hand-toggle'),
                  icon: const Icon(LinearIcons.hand, size: 18),
                  label: Text(sync.selfHandRaised ? '收手' : '举手'),
                  onPressed: () {
                    if (sync.selfHandRaised) {
                      sync.lowerHand();
                    } else {
                      sync.raiseHand();
                    }
                  },
                ),
              if (showHand && showPresent) const SizedBox(height: 8),
              if (showPresent)
                FilledButton.icon(
                  key: const Key('wb-panel-present-toggle'),
                  icon: Icon(
                    sync.presentMode ? LinearIcons.stop : LinearIcons.power,
                    size: 18,
                  ),
                  label: Text(sync.presentMode ? '结束演示' : '开始演示'),
                  onPressed: () {
                    if (sync.presentMode) {
                      sync.stopPresent();
                    } else {
                      sync.startPresent();
                    }
                  },
                ),
            ],
          ),
        ),
      ],
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

/// 参与者行：id + 角色 + M3 标记 + 行内操作（跟随 / 授权 / 移除）。
class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({
    required this.participant,
    required this.sync,
    required this.follow,
  });

  final WbCollabParticipant participant;
  final WbCollabService sync;
  final WbFollowController? follow;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return ListTile(
      key: ValueKey<String>('wb-participant-${participant.id}'),
      dense: true,
      leading: WbAvatar(
        name: participant.id,
        size: WbAvatarSize.s,
        backgroundColor: participant.isSelf
            ? colors.primary.withValues(alpha: 0.18)
            : null,
      ),
      title: Text(
        participant.isSelf ? '${participant.id}（我）' : participant.id,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: _subtitle(context),
      trailing: _trailing(context),
    );
  }

  /// 副标题：角色 + M3 标记（演示中 / 已举手 / 已授权）。
  ///
  /// 面板为窄 Drawer（默认 304px）且 trailing 可能并列 3 个操作按钮，
  /// 副标题可用宽度约 90px；用 [Wrap] 允许标记折行，避免 Row 溢出。
  Widget _subtitle(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final bool isPresenter = sync.presentMode &&
        sync.presenterId.isNotEmpty &&
        sync.presenterId == participant.id;
    final bool hasMarks =
        isPresenter || participant.handRaised || participant.grantedWrite;
    if (!hasMarks) {
      return Text(_roleLabel(participant.role));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          _roleLabel(participant.role),
          overflow: TextOverflow.ellipsis,
        ),
        if (isPresenter)
          _mark(context, LinearIcons.visible, '演示中', colors.primary),
        if (participant.handRaised)
          _mark(context, LinearIcons.hand, '已举手', colors.primary),
        if (participant.grantedWrite)
          _mark(context, LinearIcons.permission, '已授权', colors.icon),
      ],
    );
  }

  /// 行内操作（M3；他人条目）。
  ///
  /// - 「跟随 / 停止跟随」（经 [WbFollowController]；未挂载时直发请求）；
  /// - CoHost+ 对低级别成员：「授权控制 / 收回控制」「移除成员」
  ///   （服务端校验兜底，UI 按 [WbCollabService] 前置收窄）。
  Widget? _trailing(BuildContext context) {
    if (participant.isSelf) {
      return null; // 自身操作在面板底部「房间操作区」。
    }
    final bool following = follow?.followingUserId == participant.id;
    final List<Widget> actions = <Widget>[
      _action(
        key: 'wb-participant-follow-${participant.id}',
        icon: following ? LinearIcons.close : LinearIcons.visible,
        tooltip: following ? '停止跟随' : '跟随',
        onTap: () {
          if (following) {
            follow?.stopFollow();
            return;
          }
          final WbFollowController? controller = follow;
          if (controller != null) {
            controller.startFollow(participant.id);
          } else {
            sync.follow(participant.id); // 降级：无跟随管理器直发请求。
          }
        },
      ),
    ];
    if (sync.canGrantControlParticipant(participant.id, participant.role)) {
      actions.add(
        _action(
          key: 'wb-participant-grant-${participant.id}',
          icon: participant.grantedWrite
              ? LinearIcons.lock
              : LinearIcons.permission,
          tooltip: participant.grantedWrite ? '收回控制' : '授权控制',
          onTap: () {
            if (participant.grantedWrite) {
              sync.revokeControl(participant.id);
            } else {
              sync.grantControl(participant.id);
            }
          },
        ),
      );
    }
    if (sync.canRemoveParticipant(participant.id, participant.role)) {
      actions.add(
        _action(
          key: 'wb-participant-remove-${participant.id}',
          icon: LinearIcons.delete,
          tooltip: '移除成员',
          color: Theme.of(context).colorScheme.error,
          onTap: () => sync.removeUser(participant.id),
        ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: actions);
  }

  /// 行内小图标按钮。
  Widget _action({
    required String key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    return IconButton(
      key: Key(key),
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      color: color,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      onPressed: onTap,
    );
  }

  /// 标记（小图标 + 文本）。
  Widget _mark(
    BuildContext context,
    IconData icon,
    String label,
    Color color,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 2),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: color, fontSize: 11),
        ),
      ],
    );
  }
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

/// 短 id（尾 8 位；空串返回「未知」）。
String _shortId(String id) {
  if (id.isEmpty) {
    return '未知';
  }
  return id.length <= 8 ? id : id.substring(id.length - 8);
}
