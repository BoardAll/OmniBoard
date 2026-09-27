/// 托盘插件接口与 Linux FFI 实现。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'wb_ffi_bindings.dart';
import 'wb_native_library.dart';

/// 托盘菜单项类型。
enum WbTrayMenuItemType {
  /// 普通可点击项。
  normal,

  /// 分隔线（[WbTrayMenuItem.id] 可为空）。
  separator,

  /// 复选项（原生侧渲染勾选标记，状态由应用维护）。
  checkbox,
}

/// 托盘菜单项。
class WbTrayMenuItem {
  const WbTrayMenuItem({
    required this.id,
    this.label = '',
    this.type = WbTrayMenuItemType.normal,
    this.enabled = true,
    this.checked = false,
  });

  /// 稳定 id（点击事件回传）。
  final String id;

  /// 显示文本。
  final String label;

  /// 类型。
  final WbTrayMenuItemType type;

  /// 是否可用。
  final bool enabled;

  /// 复选项是否勾选。
  final bool checked;

  /// 序列化为菜单 JSON 协议元素（Dart 侧 `jsonEncode` 后传原生）。
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'label': label,
        'type': type.name,
        'enabled': enabled,
        'checked': checked,
      };
}

/// 系统托盘（《Flutter + C++ 工程结构设计》§6.5）。
abstract class WbTrayPlugin {
  /// 设置托盘图标（主题图标名或绝对路径）。
  Future<void> setIcon(String iconPath);

  /// 设置悬停提示。
  Future<void> setTooltip(String tooltip);

  /// 设置右键菜单（整体替换）。
  Future<void> setMenu(List<WbTrayMenuItem> items);

  /// 菜单项点击事件流（值为 [WbTrayMenuItem.id]）。
  Stream<String> get onMenuItemClicked;
}

/// Linux 实现：dart:ffi → `libwhiteboard_linux.so`。
///
/// 原生侧经 StatusNotifierItem / AppIndicator（libappindicator3）实现；
/// 构建时缺少 appindicator 或 json-glib 依赖时对应能力返回不支持
/// （Dart 侧静默降级）。菜单以 JSON 字符串传递（协议见
/// [WbTrayMenuItem.toMap]），点击回调用 [NativeCallable.listener]
/// 跨线程安全转发到 broadcast 流。同一时刻只应存在一个实例。
///
/// 原生库缺失（未打包 / 单元测试环境）时全部方法为 no-op、
/// 点击流保持为空，绝不抛异常。
class LinuxTrayPlugin implements WbTrayPlugin {
  /// [library] 供测试注入；缺省自动尝试加载（失败按缺失处理）。
  LinuxTrayPlugin({WbNativeLibrary? library})
      : _bindings = _TrayBindings.tryLoad(library ?? WbNativeLibrary.tryLoad()) {
    final _TrayBindings? bindings = _bindings;
    if (bindings != null) {
      final NativeCallable<WbStrCallbackNative> callback =
          NativeCallable<WbStrCallbackNative>.listener(_onNativeClick);
      _callback = callback;
      bindings.setCallback(callback.nativeFunction);
    }
  }

  final _TrayBindings? _bindings;
  NativeCallable<WbStrCallbackNative>? _callback;
  final StreamController<String> _clicked = StreamController<String>.broadcast();

  @override
  Stream<String> get onMenuItemClicked => _clicked.stream;

  @override
  Future<void> setIcon(String iconPath) async {
    _invokeString((_TrayBindings bindings, Pointer<Utf8> value) {
      bindings.setIcon(value);
    }, iconPath);
  }

  @override
  Future<void> setTooltip(String tooltip) async {
    _invokeString((_TrayBindings bindings, Pointer<Utf8> value) {
      bindings.setTooltip(value);
    }, tooltip);
  }

  @override
  Future<void> setMenu(List<WbTrayMenuItem> items) async {
    final _TrayBindings? bindings = _bindings;
    if (bindings == null) {
      return;
    }
    try {
      final String json = jsonEncode(
        items.map((WbTrayMenuItem item) => item.toMap()).toList(growable: false),
      );
      final Pointer<Utf8> jsonPointer = json.toNativeUtf8();
      try {
        bindings.setMenu(jsonPointer);
      } finally {
        malloc.free(jsonPointer);
      }
    } catch (_) {
      // 降级：忽略原生错误。
    }
  }

  /// 释放资源：清除原生回调并关闭点击流。
  Future<void> dispose() async {
    final _TrayBindings? bindings = _bindings;
    if (bindings != null) {
      try {
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
    await _clicked.close();
  }

  /// 以字符串参数执行一次原生调用（库缺失时为 no-op）。
  void _invokeString(
    void Function(_TrayBindings bindings, Pointer<Utf8> value) call,
    String value,
  ) {
    final _TrayBindings? bindings = _bindings;
    if (bindings == null) {
      return;
    }
    try {
      final Pointer<Utf8> pointer = value.toNativeUtf8();
      try {
        call(bindings, pointer);
      } finally {
        malloc.free(pointer);
      }
    } catch (_) {
      // 降级：忽略原生错误。
    }
  }

  /// 原生回调（任意线程安全）：同步拷贝 id 后转发到 broadcast 流。
  void _onNativeClick(Pointer<Utf8> idPointer) {
    if (idPointer == nullptr) {
      return;
    }
    final String id = idPointer.toDartString();
    if (id.isEmpty || _clicked.isClosed) {
      return;
    }
    _clicked.add(id);
  }
}

/// 托盘 C API 的符号表；任一符号缺失则整体不可用（静默降级）。
class _TrayBindings {
  _TrayBindings({
    required this.setIcon,
    required this.setTooltip,
    required this.setMenu,
    required this.setCallback,
  });

  final WbIntStr1Dart setIcon;
  final WbIntStr1Dart setTooltip;
  final WbIntStr1Dart setMenu;
  final WbSetStrCallbackDart setCallback;

  static _TrayBindings? tryLoad(WbNativeLibrary? library) {
    final WbIntStr1Dart? setIcon =
        wbLookupStr1(library, 'wb_linux_tray_set_icon');
    final WbIntStr1Dart? setTooltip =
        wbLookupStr1(library, 'wb_linux_tray_set_tooltip');
    final WbIntStr1Dart? setMenu =
        wbLookupStr1(library, 'wb_linux_tray_set_menu');
    final WbSetStrCallbackDart? setCallback =
        wbLookupSetStrCallback(library, 'wb_linux_tray_set_callback');
    if (setIcon == null ||
        setTooltip == null ||
        setMenu == null ||
        setCallback == null) {
      return null;
    }
    return _TrayBindings(
      setIcon: setIcon,
      setTooltip: setTooltip,
      setMenu: setMenu,
      setCallback: setCallback,
    );
  }
}
