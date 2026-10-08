/// 核心状态指示 chip（列表页 / 编辑页共用）。
///
/// 展示 [WbCoreStatus] 的中文状态与提示：idle（待命）/ loading（加载中）/
/// ready（就绪）/ unavailable（不可用 → 演示画布）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

import '../services/wb_core_service.dart';

/// 核心状态指示 chip。
class WbCoreStatusChip extends StatelessWidget {
  /// 创建 chip。
  const WbCoreStatusChip({super.key});

  @override
  Widget build(BuildContext context) {
    final WbCoreService core = context.watch<WbCoreService>();
    final WbThemeColors colors = context.wbColors;
    final WbCoreStatus status = core.status;
    final String label = switch (status) {
      WbCoreStatus.ready => '引擎就绪',
      WbCoreStatus.loading => '引擎加载中',
      WbCoreStatus.idle => '引擎待命',
      WbCoreStatus.unavailable => '演示画布',
    };
    final String tooltip = switch (status) {
      WbCoreStatus.ready => 'WASM 核心已加载：ccall / cwrap 可用',
      WbCoreStatus.loading => '正在加载 wb_core.js / wb_core.wasm…',
      WbCoreStatus.idle => 'WASM 核心尚未加载（进入编辑页时按需加载）',
      WbCoreStatus.unavailable => 'WASM 核心不可用（加载失败或资源缺失），当前为内置演示画布',
    };
    return Tooltip(
      message: tooltip,
      child: Chip(
        avatar: Icon(
          status == WbCoreStatus.ready
              ? LinearIcons.cloud
              : LinearIcons.offline,
          size: 16,
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
}
