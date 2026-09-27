/// 统一窗口插件接口与 Linux FFI 实现。
library;

import 'wb_ffi_bindings.dart';
import 'wb_native_library.dart';

/// 平台窗口能力（《Flutter + C++ 工程结构设计》§6.5）。
///
/// 四个平台提供同名接口与语义；调用方（桌面应用）按平台选择实现。
abstract class WbWindowPlugin {
  /// 窗口背景是否透明（透明批注覆盖层模式，见《透明批注模式技术方案》§3）。
  Future<void> setTransparent(bool transparent);

  /// 是否始终置顶。
  Future<void> setAlwaysOnTop(bool onTop);

  /// 是否忽略鼠标事件（点击穿透）。
  ///
  /// [forward] 为 true 时仍接收鼠标移动消息（用于悬停高亮），
  /// 点击事件继续穿透到下层窗口。Linux 无对应机制，实现忽略该参数。
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false});

  /// 全屏切换。
  Future<void> setFullscreen(bool fullscreen);

  /// 移动窗口到屏幕坐标（逻辑像素）。
  Future<void> setPosition(int x, int y);

  /// 调整窗口尺寸（逻辑像素）。
  Future<void> setSize(int width, int height);
}

/// Linux 实现：dart:ffi → `libwhiteboard_linux.so` 的扁平 C API。
///
/// X11 / Wayland 差异（《透明批注模式技术方案》§7.3 / §7.4）：
///
///   - X11 / XWayland：全部能力经 GDK / X11 生效（窗口透明需运行中的
///     合成器支持；置顶为 `_NET_WM_STATE_ABOVE`；穿透为 XShape 输入区域）；
///   - Wayland：透明 / 置顶 / 位置尺寸为 best-effort（合成器可忽略请求），
///     点击穿透经 wl_compositor input region（部分合成器不支持）。
///
/// 原生库缺失（未打包 / 单元测试环境）时全部方法静默 no-op，绝不抛异常。
class LinuxWindowPlugin implements WbWindowPlugin {
  /// [library] 供测试注入；缺省自动尝试加载（失败按缺失处理）。
  LinuxWindowPlugin({WbNativeLibrary? library})
      : _bindings =
            _WindowBindings.tryLoad(library ?? WbNativeLibrary.tryLoad());

  final _WindowBindings? _bindings;

  @override
  Future<void> setTransparent(bool transparent) async {
    _guard(() => _bindings?.setTransparent(transparent ? 1 : 0));
  }

  @override
  Future<void> setAlwaysOnTop(bool onTop) async {
    _guard(() => _bindings?.setAlwaysOnTop(onTop ? 1 : 0));
  }

  @override
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false}) async {
    _guard(
      () => _bindings?.setIgnoreMouseEvents(ignore ? 1 : 0, forward ? 1 : 0),
    );
  }

  @override
  Future<void> setFullscreen(bool fullscreen) async {
    _guard(() => _bindings?.setFullscreen(fullscreen ? 1 : 0));
  }

  @override
  Future<void> setPosition(int x, int y) async {
    _guard(() => _bindings?.setPosition(x, y));
  }

  @override
  Future<void> setSize(int width, int height) async {
    _guard(() => _bindings?.setSize(width, height));
  }

  /// 执行一次原生调用：库缺失（[_bindings] 为 null）时为 no-op，
  /// 原生调用抛异常时静默降级（绝不向调用方抛异常）。
  void _guard(void Function() call) {
    try {
      call();
    } catch (_) {
      // 降级：忽略原生错误。
    }
  }
}

/// 窗口 C API 的符号表；任一符号缺失则整体不可用（静默降级）。
class _WindowBindings {
  _WindowBindings({
    required this.setTransparent,
    required this.setAlwaysOnTop,
    required this.setIgnoreMouseEvents,
    required this.setFullscreen,
    required this.setPosition,
    required this.setSize,
  });

  final WbInt1Dart setTransparent;
  final WbInt1Dart setAlwaysOnTop;
  final WbInt2Dart setIgnoreMouseEvents;
  final WbInt1Dart setFullscreen;
  final WbInt2Dart setPosition;
  final WbInt2Dart setSize;

  static _WindowBindings? tryLoad(WbNativeLibrary? library) {
    final WbInt1Dart? setTransparent =
        wbLookupInt1(library, 'wb_linux_window_set_transparent');
    final WbInt1Dart? setAlwaysOnTop =
        wbLookupInt1(library, 'wb_linux_window_set_always_on_top');
    final WbInt2Dart? setIgnoreMouseEvents =
        wbLookupInt2(library, 'wb_linux_window_set_ignore_mouse_events');
    final WbInt1Dart? setFullscreen =
        wbLookupInt1(library, 'wb_linux_window_set_fullscreen');
    final WbInt2Dart? setPosition =
        wbLookupInt2(library, 'wb_linux_window_set_position');
    final WbInt2Dart? setSize =
        wbLookupInt2(library, 'wb_linux_window_set_size');
    if (setTransparent == null ||
        setAlwaysOnTop == null ||
        setIgnoreMouseEvents == null ||
        setFullscreen == null ||
        setPosition == null ||
        setSize == null) {
      return null;
    }
    return _WindowBindings(
      setTransparent: setTransparent,
      setAlwaysOnTop: setAlwaysOnTop,
      setIgnoreMouseEvents: setIgnoreMouseEvents,
      setFullscreen: setFullscreen,
      setPosition: setPosition,
      setSize: setSize,
    );
  }
}
