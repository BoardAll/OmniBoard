/// 举手按钮（编辑页 AppBar；M3 / T3.4）。
///
/// 非 Host/CoHost 角色（Viewer～Presenter）且已连接时显示「举手 / 收手」切换：
/// - 服务端为权威（最低 Viewer；Guest 拒绝），本按钮在 Guest / 未加入 /
///   已被移出时不显示；
/// - 点击发送 `interactive:raiseHand` / `interactive:lowerHand`（轻量 ack；
///   成功即本地置位/复位——服务端广播排除发起者自身）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../../services/realtime_service.dart';
import 'interactive_feedback.dart';

/// 举手 / 收手切换按钮。
class WbRaiseHandButton extends StatelessWidget {
  /// 创建按钮。
  const WbRaiseHandButton({super.key});

  @override
  Widget build(BuildContext context) {
    final WbRealtimeService realtime = context.watch<WbRealtimeService>();
    if (!realtime.canRaiseHand) {
      return const SizedBox.shrink();
    }
    final bool raised = realtime.selfHandRaised;
    return IconButton(
      key: const Key('wb-raise-hand-button'),
      tooltip: raised ? '收手' : '举手',
      icon: const Icon(LinearIcons.hand),
      color: raised ? context.wbColors.primary : null,
      onPressed: () => unawaited(_toggle(context, realtime, raised)),
    );
  }

  Future<void> _toggle(BuildContext context, WbRealtimeService realtime, bool raised) async {
    final String action = raised ? '收手' : '举手';
    final bool ok = raised ? await realtime.lowerHand() : await realtime.raiseHand();
    if (!ok && context.mounted) {
      showWbInteractiveFailure(context, action);
    }
  }
}
