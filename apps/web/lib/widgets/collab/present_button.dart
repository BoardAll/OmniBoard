/// 演示模式入口按钮（编辑页 AppBar；M3 / T3.4）。
///
/// CoHost+ 且已连接时显示：
/// - 房间处于 present → 「结束演示」发送 `interactive:stopPresent`；
/// - 否则 → 「开始演示」发送 `interactive:startPresent`（presenterId = 发起者）。
///
/// 服务端广播 `interactive:modeChanged` 排除发起者自身，ack 成功后本端做
/// 确定性本地更新（幂等；其他成员经广播感知）。模式 chip 见
/// `collab_status_chip.dart` 的 `WbPresentModeChip`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../../services/realtime_service.dart';
import 'interactive_feedback.dart';

/// 开始 / 结束演示切换按钮。
class WbPresentButton extends StatelessWidget {
  /// 创建按钮。
  const WbPresentButton({super.key});

  @override
  Widget build(BuildContext context) {
    final WbRealtimeService realtime = context.watch<WbRealtimeService>();
    if (!realtime.canManageInteractions) {
      return const SizedBox.shrink();
    }
    final bool presenting = realtime.isPresenting;
    return IconButton(
      key: const Key('wb-present-button'),
      tooltip: presenting ? '结束演示' : '开始演示',
      icon: Icon(presenting ? LinearIcons.stop : LinearIcons.visible),
      color: presenting ? context.wbColors.primary : null,
      onPressed: () => unawaited(_toggle(context, realtime, presenting)),
    );
  }

  Future<void> _toggle(BuildContext context, WbRealtimeService realtime, bool presenting) async {
    final String action = presenting ? '结束演示' : '开始演示';
    final bool ok = presenting ? await realtime.stopPresent() : await realtime.startPresent();
    if (!ok && context.mounted) {
      showWbInteractiveFailure(context, action);
    }
  }
}
