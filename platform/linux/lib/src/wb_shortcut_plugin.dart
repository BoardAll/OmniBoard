/// 全局快捷键插件接口与 Linux FFI 实现。
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'wb_ffi_bindings.dart';
import 'wb_native_library.dart';

/// 全局快捷键注册（《Flutter + C++ 工程结构设计》§6.5）。
abstract class WbShortcutPlugin {
  /// 注册全局快捷键。
  ///
  /// [accelerator] 形如 `Ctrl+Shift+J`；修饰键支持 `Ctrl` / `Alt` /
  /// `Shift` / `⌘`（Cmd）/ `Win`（Super），主键为单个字符或功能键名
  /// （`F1`…`F24`、`Space`、`Tab` 等）。键名集合与
  /// `WbAccelerator` 的归一结果一致。
  Future<void> register(String accelerator, String id);

  /// 注销单个快捷键。
  Future<void> unregister(String id);

  /// 注销全部快捷键。
  Future<void> unregisterAll();

  /// 快捷键触发事件流（值为注册时的 [id]）。
  Stream<String> get onTriggered;
}

/// Linux 实现：dart:ffi → `libwhiteboard_linux.so`。
///
/// 原生侧在 X11 / XWayland 会话使用 `XGrabKey`（含 CapsLock / NumLock
/// 变体）抓取全局按键；Wayland 原生会话无全局快捷键协议，注册返回
/// 不支持（《透明批注模式技术方案》§7.4 降级：应用内快捷键）。
///
/// 触发链路：X11 被动 grab → GDK 事件 filter → C 回调 →
/// [NativeCallable.listener]（跨线程安全，转投 Dart 事件循环）→
/// broadcast 流。同一时刻只应存在一个实例。
///
/// 原生库缺失（未打包 / 单元测试环境）时注册 / 注销为 no-op、
/// 触发流保持为空，绝不抛异常。
class LinuxShortcutPlugin implements WbShortcutPlugin {
  /// [library] 供测试注入；缺省自动尝试加载（失败按缺失处理）。
  LinuxShortcutPlugin({WbNativeLibrary? library})
      : _bindings =
            _ShortcutBindings.tryLoad(library ?? WbNativeLibrary.tryLoad()) {
    final _ShortcutBindings? bindings = _bindings;
    if (bindings != null) {
      final NativeCallable<WbStrCallbackNative> callback =
          NativeCallable<WbStrCallbackNative>.listener(_onNativeTrigger);
      _callback = callback;
      bindings.setCallback(callback.nativeFunction);
    }
  }

  final _ShortcutBindings? _bindings;
  NativeCallable<WbStrCallbackNative>? _callback;
  final StreamController<String> _triggered =
      StreamController<String>.broadcast();

  @override
  Stream<String> get onTriggered => _triggered.stream;

  @override
  Future<void> register(String accelerator, String id) async {
    final _ShortcutBindings? bindings = _bindings;
    if (bindings == null) {
      return;
    }
    try {
      final Pointer<Utf8> acceleratorPointer = accelerator.toNativeUtf8();
      final Pointer<Utf8> idPointer = id.toNativeUtf8();
      try {
        bindings.register(acceleratorPointer, idPointer);
      } finally {
        malloc.free(acceleratorPointer);
        malloc.free(idPointer);
      }
    } catch (_) {
      // 降级：忽略原生错误。
    }
  }

  @override
  Future<void> unregister(String id) async {
    final _ShortcutBindings? bindings = _bindings;
    if (bindings == null) {
      return;
    }
    try {
      final Pointer<Utf8> idPointer = id.toNativeUtf8();
      try {
        bindings.unregister(idPointer);
      } finally {
        malloc.free(idPointer);
      }
    } catch (_) {
      // 降级：忽略原生错误。
    }
  }

  @override
  Future<void> unregisterAll() async {
    final _ShortcutBindings? bindings = _bindings;
    if (bindings == null) {
      return;
    }
    try {
      bindings.unregisterAll();
    } catch (_) {
      // 降级：忽略原生错误。
    }
  }

  /// 释放资源：注销全部快捷键、清除原生回调并关闭触发流。
  ///
  /// 顺序保证原生侧先断开回调，再销毁 [NativeCallable]，
  /// 避免原生线程回调已关闭的 NativeCallable。
  Future<void> dispose() async {
    final _ShortcutBindings? bindings = _bindings;
    if (bindings != null) {
      try {
        bindings.unregisterAll();
        bindings.setCallback(nullptr);
      } catch (_) {
        // 降级：忽略原生错误。
      }
    }
    final NativeCallable<WbStrCallbackNative>? callback = _callback;
    _callback = null;
    if (callback != null) {
      callback.close();
    }
    await _triggered.close();
  }

  /// 原生回调（任意线程安全）：同步拷贝 id 后转发到 broadcast 流。
  void _onNativeTrigger(Pointer<Utf8> idPointer) {
    if (idPointer == nullptr) {
      return;
    }
    final String id = idPointer.toDartString();
    if (id.isEmpty || _triggered.isClosed) {
      return;
    }
    _triggered.add(id);
  }
}

/// 快捷键 C API 的符号表；任一符号缺失则整体不可用（静默降级）。
class _ShortcutBindings {
  _ShortcutBindings({
    required this.register,
    required this.unregister,
    required this.unregisterAll,
    required this.setCallback,
  });

  final WbIntStr2Dart register;
  final WbIntStr1Dart unregister;
  final WbInt0Dart unregisterAll;
  final WbSetStrCallbackDart setCallback;

  static _ShortcutBindings? tryLoad(WbNativeLibrary? library) {
    final WbIntStr2Dart? register =
        wbLookupStr2(library, 'wb_linux_shortcut_register');
    final WbIntStr1Dart? unregister =
        wbLookupStr1(library, 'wb_linux_shortcut_unregister');
    final WbInt0Dart? unregisterAll =
        wbLookupInt0(library, 'wb_linux_shortcut_unregister_all');
    final WbSetStrCallbackDart? setCallback =
        wbLookupSetStrCallback(library, 'wb_linux_shortcut_set_callback');
    if (register == null ||
        unregister == null ||
        unregisterAll == null ||
        setCallback == null) {
      return null;
    }
    return _ShortcutBindings(
      register: register,
      unregister: unregister,
      unregisterAll: unregisterAll,
      setCallback: setCallback,
    );
  }
}
