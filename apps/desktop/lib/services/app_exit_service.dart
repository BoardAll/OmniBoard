/// 应用退出编排：主窗口关闭拦截（X / Alt+F4）与「退出应用」按钮共用。
///
/// 窗口管理器已 `setPreventClose(true)` 拦截原生关闭；本服务按未保存状态
/// 决定弹三选询问或真正退出。真正退出走 `setPreventClose(false)` + [close]
/// 标准 WM_CLOSE → DestroyWindow 路径（消息循环运行中完成引擎析构，退出
/// 即时）；不可用 [destroy]（仅 PostQuitMessage，先退消息循环后引擎析构
/// 等待消息泵超时约 40s，观感像卡死）。
library;

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/unsaved_changes_dialog.dart';
import 'board_file_service.dart';

/// 退出编排服务（应用级单例，经 Provider 下发）。
class WbAppExitService {
  WbAppExitService({this.files, this.windowDestroyer});

  /// 白板文件服务（null = 无脏标记，直接退出）。
  final WbBoardFileService? files;

  /// 退出回调（测试注入；缺省 window_manager 标准关闭路径）。
  final Future<void> Function()? windowDestroyer;

  /// 已决定退出（防重入：`close()` 会再次派发 `onWindowClose` 事件）。
  bool _closing = false;

  /// 询问 / 保存流程处理中（防并发请求叠加弹窗）。
  bool _handling = false;

  /// 是否已决定退出（窗口销毁流程已启动）。
  bool get isClosing => _closing;

  /// 退出应用请求（窗口 X / Alt+F4 与「退出应用」按钮共用入口）。
  ///
  /// 返回：已决定退出返回 null；取消 / 保存取消或失败返回对应选择
  /// （可再次请求）。上下文为空 / 未挂载文件服务 / 无脏改动 → 直接销毁
  /// 窗口，避免无法关闭。
  Future<WbUnsavedChoice?> requestExit(BuildContext? context) async {
    if (_closing || _handling) {
      return null;
    }
    _handling = true;
    try {
      final WbBoardFileService? f = files;
      if (f == null || !f.hasUnsavedChanges) {
        await destroyWindow();
        return null;
      }
      if (context == null || !context.mounted) {
        // 无可用上下文（异常窗口期）：直接销毁，避免无法关闭。
        await destroyWindow();
        return null;
      }
      final WbUnsavedChoice choice = await showUnsavedChangesDialog(context);
      switch (choice) {
        case WbUnsavedChoice.cancel:
          return choice;
        case WbUnsavedChoice.discard:
          await destroyWindow();
          return choice;
        case WbUnsavedChoice.save:
          final WbSaveOutcome outcome = await f.save();
          if (outcome.isSaved) {
            await destroyWindow();
          }
          return choice;
      }
    } finally {
      _handling = false;
    }
  }

  /// 真正退出窗口：恢复原生关闭后走标准 `close()` 路径（退出即时）。
  ///
  /// [windowManager.destroy] 仅 `PostQuitMessage`：先退消息循环再析构引擎
  /// （平台任务无法泵送），实测延迟约 40s 才退出，故改用标准关闭路径。
  @visibleForTesting
  Future<void> destroyWindow() async {
    if (_closing) {
      return;
    }
    final Future<void> Function()? destroyer = windowDestroyer;
    if (destroyer != null) {
      _closing = true;
      await destroyer();
      return;
    }
    _closing = true;
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {
      // 通道缺失（测试 / 非桌面）：还原标志，允许后续重试。
      _closing = false;
    }
  }
}
