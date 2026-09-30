/// 参与者面板入口按钮（编辑页 AppBar；W1 协作层 / T1.8）。
///
/// 成员图标 + 在线人数徽标（>0 时显示）；点击由页面打开 endDrawer
/// （[WbParticipantsPanel]）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../../services/realtime_service.dart';

/// 参与者入口按钮。
class WbParticipantsButton extends StatelessWidget {
  /// 创建按钮；[onPressed] 由页面提供（打开参与者面板）。
  const WbParticipantsButton({super.key, required this.onPressed});

  /// 点击回调。
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final WbRealtimeService realtime = context.watch<WbRealtimeService>();
    final int online = realtime.participants.length;
    const Widget icon = Icon(LinearIcons.members);
    return IconButton(
      key: const Key('wb-participants-button'),
      tooltip: '参与者',
      onPressed: onPressed,
      icon: online > 0
          ? WbBadge.count(online, maxCount: 9, color: context.wbColors.primary, child: icon)
          : icon,
    );
  }
}
