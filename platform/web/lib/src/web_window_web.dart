/// Web 窗口插件实现（Fullscreen API；其余能力 no-op）。
///
/// 浏览器差异说明（《Web 端方案设计（Flutter Web + WASM）》§2.1、§16）：
/// - 全屏：`document.documentElement.requestFullscreen()` /
///   `document.exitFullscreen()`；请求必须处于用户手势中，被拒绝时静默
///   降级（no-op）。Safari 15+、iOS Safari 行为略有差异（部分版本只
///   支持带前缀 API），Promise 拒绝同样被吞掉。
/// - 透明 / 置顶 / 穿透 / 位置 / 尺寸：浏览器不允许页面控制系统窗口，
///   一律 no-op；能力查询见 [WebWindowCapabilities.browser]。
///
/// 仅 Web 目标编译（条件导入选择），VM 目标使用占位实现
/// （`web_window_stub.dart`）。
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_window_types.dart';

/// Web 窗口插件（浏览器环境）。
class WebWindowPlugin implements WbWindowPlugin {
  /// 创建插件。
  WebWindowPlugin();

  /// 浏览器能力：仅全屏可用。
  WebWindowCapabilities get capabilities => WebWindowCapabilities.browser;

  /// 全屏是否可用。
  bool get supportsFullscreen => capabilities.fullscreen;

  @override
  Future<void> setTransparent(bool transparent) async {
    // 浏览器不支持窗口级透明（CSS 透明只影响页面自身绘制）：no-op。
  }

  @override
  Future<void> setAlwaysOnTop(bool onTop) async {
    // 浏览器不支持窗口级置顶（窗口层级由操作系统/浏览器管理）：no-op。
  }

  @override
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false}) async {
    // 浏览器不支持系统级鼠标穿透（pointer-events 只影响页面内元素，
    // 不会把事件转发给下层应用）：no-op。
  }

  @override
  Future<void> setFullscreen(bool fullscreen) async {
    try {
      if (fullscreen) {
        final web.Element? root = web.document.documentElement;
        if (root == null) {
          return;
        }
        await root.requestFullscreen().toDart;
      } else if (web.document.fullscreenElement != null) {
        await web.document.exitFullscreen().toDart;
      }
    } catch (_) {
      // 非用户手势 / 权限被拒绝（如 iframe 未授权）时静默降级。
    }
  }

  @override
  Future<void> setPosition(int x, int y) async {
    // 浏览器窗口位置不可由页面控制：no-op。
  }

  @override
  Future<void> setSize(int width, int height) async {
    // 浏览器窗口尺寸不可由页面控制：no-op。
  }
}
