/// Linux 平台插件的 dart:ffi 绑定：函数类型、状态码与符号查找辅助。
///
/// 与原生头文件 `linux/include/window_plugin.h` 一一对应，修改需同步。
/// 所有原生函数使用统一 `int` 状态码（[WbStatus]，与 C 宏
/// `WB_OK` / `WB_ERR_UNSUPPORTED` / `WB_ERR_FAILED` 一致）。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'wb_native_library.dart';

/// 原生调用状态码（与 C 头 `window_plugin.h` 一致）。
abstract final class WbStatus {
  /// 调用成功（C 宏 `WB_OK`）。
  static const int ok = 0;

  /// 当前后端不支持该能力，例如 Wayland 下的全局快捷键
  /// （C 宏 `WB_ERR_UNSUPPORTED`）。
  static const int unsupported = 1;

  /// 调用失败，例如主窗口未找到、X 请求被拒
  /// （C 宏 `WB_ERR_FAILED`）。
  static const int failed = 2;
}

// ---------------------------------------------------------------------------
// 通用调用形态（Native / Dart 成对）。
// ---------------------------------------------------------------------------

/// `int f()`
typedef WbInt0Native = Int32 Function();
typedef WbInt0Dart = int Function();

/// `int f(int)`
typedef WbInt1Native = Int32 Function(Int32);
typedef WbInt1Dart = int Function(int);

/// `int f(int, int)`
typedef WbInt2Native = Int32 Function(Int32, Int32);
typedef WbInt2Dart = int Function(int, int);

/// `int f(const char*)`
typedef WbIntStr1Native = Int32 Function(Pointer<Utf8>);
typedef WbIntStr1Dart = int Function(Pointer<Utf8>);

/// `int f(const char*, const char*)`
typedef WbIntStr2Native = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef WbIntStr2Dart = int Function(Pointer<Utf8>, Pointer<Utf8>);

/// 原生字符串事件回调：`void (*)(const char* id)`。
typedef WbStrCallbackNative = Void Function(Pointer<Utf8>);
typedef WbStrCallbackDart = void Function(Pointer<Utf8>);

/// 注册 / 清除原生字符串回调：`void f(void (*callback)(const char*))`。
typedef WbSetStrCallbackNative = Void Function(
    Pointer<NativeFunction<WbStrCallbackNative>>);
typedef WbSetStrCallbackDart = void Function(
    Pointer<NativeFunction<WbStrCallbackNative>>);

/// 屏幕捕获：`int f(int id, unsigned char** out_bytes, int* out_len,
/// int* out_w, int* out_h, int* out_stride)`。
typedef WbCaptureDisplayNative = Int32 Function(
  Int32,
  Pointer<Pointer<Uint8>>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef WbCaptureDisplayDart = int Function(
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
);

/// 释放捕获缓冲：`void f(unsigned char* bytes)`。
typedef WbCaptureFreeNative = Void Function(Pointer<Uint8>);
typedef WbCaptureFreeDart = void Function(Pointer<Uint8>);

// ---------------------------------------------------------------------------
// 符号查找辅助。
//
// Dart 泛型无法把「Dart 函数类型」直接传给 DynamicLibrary.lookup（其要求
// NativeType），asFunction 又要求编译期已实例化的函数类型；因此按调用形态
// 提供 8 个具体实例化的查找函数，内部均以具体 typedef 调用标准
// [DynamicLibrary.lookupFunction]（<Native, Dart> 成对），保证 CFE 与
// Dart VM 均能完成实例化。
// ---------------------------------------------------------------------------

/// 查找 `int f()` 形态符号；库缺失或符号不存在时返回 null（不抛异常）。
WbInt0Dart? wbLookupInt0(WbNativeLibrary? library, String symbol) {
  if (library == null) {
    return null;
  }
  try {
    return library.library.lookupFunction<WbInt0Native, WbInt0Dart>(symbol);
  } catch (_) {
    return null;
  }
}

/// 查找 `int f(int)` 形态符号；库缺失或符号不存在时返回 null（不抛异常）。
WbInt1Dart? wbLookupInt1(WbNativeLibrary? library, String symbol) {
  if (library == null) {
    return null;
  }
  try {
    return library.library.lookupFunction<WbInt1Native, WbInt1Dart>(symbol);
  } catch (_) {
    return null;
  }
}

/// 查找 `int f(int, int)` 形态符号；库缺失或符号不存在时返回 null。
WbInt2Dart? wbLookupInt2(WbNativeLibrary? library, String symbol) {
  if (library == null) {
    return null;
  }
  try {
    return library.library.lookupFunction<WbInt2Native, WbInt2Dart>(symbol);
  } catch (_) {
    return null;
  }
}

/// 查找 `int f(const char*)` 形态符号；库缺失或符号不存在时返回 null。
WbIntStr1Dart? wbLookupStr1(WbNativeLibrary? library, String symbol) {
  if (library == null) {
    return null;
  }
  try {
    return library.library
        .lookupFunction<WbIntStr1Native, WbIntStr1Dart>(symbol);
  } catch (_) {
    return null;
  }
}

/// 查找 `int f(const char*, const char*)` 形态符号；失败返回 null。
WbIntStr2Dart? wbLookupStr2(WbNativeLibrary? library, String symbol) {
  if (library == null) {
    return null;
  }
  try {
    return library.library
        .lookupFunction<WbIntStr2Native, WbIntStr2Dart>(symbol);
  } catch (_) {
    return null;
  }
}

/// 查找 `void f(void (*)(const char*))` 回调注册形态符号；失败返回 null。
WbSetStrCallbackDart? wbLookupSetStrCallback(
    WbNativeLibrary? library, String symbol) {
  if (library == null) {
    return null;
  }
  try {
    return library.library
        .lookupFunction<WbSetStrCallbackNative, WbSetStrCallbackDart>(symbol);
  } catch (_) {
    return null;
  }
}

/// 查找屏幕捕获 `int f(int, uchar**, int*, int*, int*, int*)` 形态符号；
/// 失败返回 null。
WbCaptureDisplayDart? wbLookupCaptureDisplay(
    WbNativeLibrary? library, String symbol) {
  if (library == null) {
    return null;
  }
  try {
    return library.library
        .lookupFunction<WbCaptureDisplayNative, WbCaptureDisplayDart>(symbol);
  } catch (_) {
    return null;
  }
}

/// 查找捕获缓冲释放 `void f(unsigned char*)` 形态符号；失败返回 null。
WbCaptureFreeDart? wbLookupCaptureFree(
    WbNativeLibrary? library, String symbol) {
  if (library == null) {
    return null;
  }
  try {
    return library.library
        .lookupFunction<WbCaptureFreeNative, WbCaptureFreeDart>(symbol);
  } catch (_) {
    return null;
  }
}
