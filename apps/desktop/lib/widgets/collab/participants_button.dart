/// 参与者入口按钮（编辑页 AppBar；打开 endDrawer 参与者面板；T1.7）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../../services/sync_service.dart';

/// 参与者入口按钮（在线人数徽标；点击由挂载方打开面板）。
class WbParticipantsButton extends StatelessWidget {
  /// 创建按钮。
  const WbParticipantsButton({super.key, required this.onPressed});

  /// 点击回调（挂载方打开参与者面板，如 `ScaffoldState.openEndDrawer`）。
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final WbCollabService sync = context.watch<WbCollabService>();
    final WbThemeColors colors = context.wbColors;
    final int online = sync.participantList.length;
    const Widget icon = Icon(LinearIcons.members);
    return IconButton(
      key: const Key('wb-participants-button'),
      tooltip: '参与者',
      onPressed: onPressed,
      icon: online > 0
          ? WbBadge.count(
              online,
              maxCount: 9,
              color: colors.primary,
              child: icon,
            )
          : icon,
    );
  }
}
