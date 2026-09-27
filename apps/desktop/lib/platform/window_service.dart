/// 窗口服务：桌面窗口初始化与配置（window_manager 封装）。
library;

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'platform_service.dart';

/// 桌面窗口服务；非桌面平台所有方法 no-op。
///
/// 平台通道缺失（测试环境 / 非桌面）时 [initialize] 静默失败，
/// 不影响应用启动。
class WbWindowService {
  bool _initialized = false;

  /// 窗口是否已成功初始化。
  bool get isInitialized => _initialized;

  /// 初始化窗口：默认尺寸 / 最小尺寸 / 居中 / 显示。
  Future<void> initialize() async {
    if (!WbPlatformService.supportsWindowControls) {
      return;
    }
    try {
      await windowManager.ensureInitialized();
      const WindowOptions options = WindowOptions(
        size: Size(1440, 900),
        minimumSize: Size(960, 640),
        center: true,
        title: 'Whiteboard',
      );
      await windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.show();
        await windowManager.focus();
      });
      // 拦截原生关闭：由应用根组件结合未保存改动询问后决定是否真正关闭。
      await windowManager.setPreventClose(true);
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  /// 设置窗口置顶（透明批注模式使用）。
  Future<void> setAlwaysOnTop(bool value) async {
    if (!_initialized) {
      return;
    }
    await windowManager.setAlwaysOnTop(value);
  }

  /// 设置全屏。
  Future<void> setFullScreen(bool value) async {
    if (!_initialized) {
      return;
    }
    await windowManager.setFullScreen(value);
  }

  /// 应用窗口模式（C1）：黑板模式隐藏标题栏直接全屏，窗口模式恢复常规窗口。
  ///
  /// 平台通道缺失（测试 / 非桌面）时静默降级，不影响其余功能。
  Future<void> applyWindowMode({required bool blackboard}) async {
    if (!WbPlatformService.supportsWindowControls) {
      return;
    }
    try {
      await windowManager.ensureInitialized();
      await windowManager.setFullScreen(blackboard);
      _initialized = true;
    } catch (_) {
      // 通道缺失 / 不可用时静默降级。
    }
  }

  /// 设置窗口标题。
  Future<void> setTitle(String title) async {
    if (!_initialized) {
      return;
    }
    await windowManager.setTitle(title);
  }
}
