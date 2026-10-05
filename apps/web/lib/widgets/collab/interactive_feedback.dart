/// interactive:* 操作失败反馈（M3 / T3.4）。
///
/// [WbRealtimeService] 的互动操作（举手 / 授权 / 演示 / 移出）统一返回
/// `bool`：服务端为权威，权限拒绝与网络失败均收敛为 `false`（不抛异常）。
/// UI 在此给出统一的轻提示，不阻塞操作流。
library;

import 'package:flutter/material.dart';

/// 显示互动操作失败轻提示（[action] 如「举手」「授权控制」「开始演示」）。
void showWbInteractiveFailure(BuildContext context, String action) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('「$action」操作失败，请检查权限与网络连接')),
  );
}
