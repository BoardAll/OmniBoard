/// Web 窗口插件的非 Web 占位实现。
///
/// Windows / macOS / Linux VM（`flutter test` / 桌面宿主）中浏览器 API
/// 不存在：能力查询全部为 false，所有窗口调用静默完成（no-op），
/// 保证上层代码可跨平台直接调用（公共 API 与 Web 版同名同签名）。
library;

import 'web_window_types.dart';

/// Web 窗口插件（非 Web 环境占位）。
class WebWindowPlugin implements WbWindowPlugin {
  /// 创建插件。
  WebWindowPlugin();

  /// 非 Web 环境：全部能力不可用。
  WebWindowCapabilities get capabilities => WebWindowCapabilities.none;

  /// 全屏是否可用（非 Web 环境恒为 false）。
  bool get supportsFullscreen => capabilities.fullscreen;

  @override
  Future<void> setTransparent(bool transparent) async {
    // 非 Web 环境：no-op。
  }

  @override
  Future<void> setAlwaysOnTop(bool onTop) async {
    // 非 Web 环境：no-op。
  }

  @override
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false}) async {
    // 非 Web 环境：no-op。
  }

  @override
  Future<void> setFullscreen(bool fullscreen) async {
    // 非 Web 环境：no-op。
  }

  @override
  Future<void> setPosition(int x, int y) async {
    // 非 Web 环境：no-op。
  }

  @override
  Future<void> setSize(int width, int height) async {
    // 非 Web 环境：no-op。
  }
}
