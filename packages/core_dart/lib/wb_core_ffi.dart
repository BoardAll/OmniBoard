/// wb_core_ffi.dart — FFI surface over the native wb_core library.
///
/// Task package 2.3 wires the Wave 0 call surface to the full
/// [WbCoreBindings] table (109 exports of `core/include/wb/wb.h`).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'engine.dart';
import 'wb_core_bindings.dart';

export 'wb_core_bindings.dart';

/// Loads the platform-specific wb_core dynamic library.
///
/// Resolution order: explicit [overridePath] (tests) → packaged plugin dir →
/// sibling build output (monorepo dev builds).
DynamicLibrary loadWbCore({String? overridePath}) {
  if (overridePath != null) {
    return DynamicLibrary.open(overridePath);
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('wb_core.dll');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libwb_core.dylib');
  }
  return DynamicLibrary.open('libwb_core.so');
}

/// Thin, allocation-safe wrapper around the C ABI.
///
/// Implements the platform-neutral [WbEngineCaller] contract: the domain
/// services (`services/*`) run unchanged on desktop (this class) and Web
/// (`WbCoreWasm`). Generic helpers take the exported symbol name and cache
/// the resolved function pointer on first use. Methods return decoded UTF-8
/// strings; callers own no native memory.
class WbCoreFfi implements WbEngineCaller {
  WbCoreFfi._(this.library) : bindings = WbCoreBindings(library);

  factory WbCoreFfi.load({String? overridePath}) =>
      WbCoreFfi._(loadWbCore(overridePath: overridePath));

  final DynamicLibrary library;
  final WbCoreBindings bindings;

  // ---- Wave 0 contract surface (kept stable) -------------------------------

  WbVersionDart get version => bindings.wbVersion;
  WbCreateBoardDart get createBoard => bindings.wbCreateBoard;
  WbDestroyBoardDart get destroyBoard => bindings.wbDestroyBoard;
  WbBoardGetDart get boardGet => bindings.wbBoardGet;
  WbExecuteCommandDart get executeCommand => bindings.wbExecuteCommand;
  WbExecuteToolDart get executeTool => bindings.wbExecuteTool;
  WbFreeDart get free => bindings.wbFree;

  /// Calls `wb_init`; returns 0 on success (see wb.h).
  @override
  int init([String configJson = '{}']) {
    return withUtf8(configJson, (Pointer<Utf8> p) => bindings.wbInit(p));
  }

  /// Calls `wb_shutdown`.
  @override
  void shutdown() => bindings.wbShutdown();

  /// Raw library version string (not a JSON envelope).
  @override
  String versionString() => takeString(bindings.wbVersion());

  // ---- Memory helpers ------------------------------------------------------

  /// Calls [body] with a UTF-8 allocated copy of [s] and releases it.
  T withUtf8<T>(String s, T Function(Pointer<Utf8>) body) {
    final Pointer<Utf8> p = s.toNativeUtf8();
    try {
      return body(p);
    } finally {
      calloc.free(p);
    }
  }

  /// Decodes an engine-owned `const char*` result and frees it.
  String takeString(Pointer<Utf8> p) {
    if (p == nullptr) {
      return '';
    }
    try {
      return p.toDartString();
    } finally {
      bindings.wbFree(p);
    }
  }

  // ---- Generic call helpers (symbol name in / JSON-string out) -------------
  //
  // 契约面见 `engine.dart`（[WbEngineCaller]）：调用方传导出符号名
  // （如 `wb_element_list`），本类按名惰性解析函数指针并缓存。

  final Map<String, WbStr0Dart> _cacheStr0 = <String, WbStr0Dart>{};
  final Map<String, WbStr1Dart> _cacheStr1 = <String, WbStr1Dart>{};
  final Map<String, WbStr2Dart> _cacheStr2 = <String, WbStr2Dart>{};
  final Map<String, WbStr3Dart> _cacheStr3 = <String, WbStr3Dart>{};
  final Map<String, WbStrI1Dart> _cacheStrI1 = <String, WbStrI1Dart>{};
  final Map<String, WbStrP1I1Dart> _cacheStrP1I1 = <String, WbStrP1I1Dart>{};
  final Map<String, WbStrP1I2Dart> _cacheStrP1I2 = <String, WbStrP1I2Dart>{};
  final Map<String, WbStrP1I1P1Dart> _cacheStrP1I1P1 =
      <String, WbStrP1I1P1Dart>{};
  final Map<String, WbStrP1F2Dart> _cacheStrP1F2 = <String, WbStrP1F2Dart>{};
  final Map<String, WbStrF3Dart> _cacheStrF3 = <String, WbStrF3Dart>{};
  final Map<String, WbStrU1Dart> _cacheStrU1 = <String, WbStrU1Dart>{};
  final Map<String, WbStrU1P1Dart> _cacheStrU1P1 = <String, WbStrU1P1Dart>{};
  final Map<String, WbStrU1I1Dart> _cacheStrU1I1 = <String, WbStrU1I1Dart>{};
  final Map<String, WbStrU1P1I2Dart> _cacheStrU1P1I2 =
      <String, WbStrU1P1I2Dart>{};
  final Map<String, WbU1P1Dart> _cacheU1P1 = <String, WbU1P1Dart>{};
  final Map<String, WbVoidU1Dart> _cacheVoidU1 = <String, WbVoidU1Dart>{};

  WbStr0Dart _fnStr0(String name) => _cacheStr0.putIfAbsent(
      name, () => library.lookupFunction<WbStr0Native, WbStr0Dart>(name));

  WbStr1Dart _fnStr1(String name) => _cacheStr1.putIfAbsent(
      name, () => library.lookupFunction<WbStr1Native, WbStr1Dart>(name));

  WbStr2Dart _fnStr2(String name) => _cacheStr2.putIfAbsent(
      name, () => library.lookupFunction<WbStr2Native, WbStr2Dart>(name));

  WbStr3Dart _fnStr3(String name) => _cacheStr3.putIfAbsent(
      name, () => library.lookupFunction<WbStr3Native, WbStr3Dart>(name));

  WbStrI1Dart _fnStrI1(String name) => _cacheStrI1.putIfAbsent(
      name, () => library.lookupFunction<WbStrI1Native, WbStrI1Dart>(name));

  WbStrP1I1Dart _fnStrP1I1(String name) => _cacheStrP1I1.putIfAbsent(
      name, () => library.lookupFunction<WbStrP1I1Native, WbStrP1I1Dart>(name));

  WbStrP1I2Dart _fnStrP1I2(String name) => _cacheStrP1I2.putIfAbsent(
      name, () => library.lookupFunction<WbStrP1I2Native, WbStrP1I2Dart>(name));

  WbStrP1I1P1Dart _fnStrP1I1P1(String name) => _cacheStrP1I1P1.putIfAbsent(
      name,
      () => library.lookupFunction<WbStrP1I1P1Native, WbStrP1I1P1Dart>(name));

  WbStrP1F2Dart _fnStrP1F2(String name) => _cacheStrP1F2.putIfAbsent(
      name, () => library.lookupFunction<WbStrP1F2Native, WbStrP1F2Dart>(name));

  WbStrF3Dart _fnStrF3(String name) => _cacheStrF3.putIfAbsent(
      name, () => library.lookupFunction<WbStrF3Native, WbStrF3Dart>(name));

  WbStrU1Dart _fnStrU1(String name) => _cacheStrU1.putIfAbsent(
      name, () => library.lookupFunction<WbStrU1Native, WbStrU1Dart>(name));

  WbStrU1P1Dart _fnStrU1P1(String name) => _cacheStrU1P1.putIfAbsent(
      name, () => library.lookupFunction<WbStrU1P1Native, WbStrU1P1Dart>(name));

  WbStrU1I1Dart _fnStrU1I1(String name) => _cacheStrU1I1.putIfAbsent(
      name, () => library.lookupFunction<WbStrU1I1Native, WbStrU1I1Dart>(name));

  WbStrU1P1I2Dart _fnStrU1P1I2(String name) => _cacheStrU1P1I2.putIfAbsent(
      name,
      () => library
          .lookupFunction<WbStrU1P1I2Native, WbStrU1P1I2Dart>(name));

  WbU1P1Dart _fnU1P1(String name) => _cacheU1P1.putIfAbsent(
      name, () => library.lookupFunction<WbU1P1Native, WbU1P1Dart>(name));

  WbVoidU1Dart _fnVoidU1(String name) => _cacheVoidU1.putIfAbsent(
      name, () => library.lookupFunction<WbVoidU1Native, WbVoidU1Dart>(name));

  @override
  String call0(String fn) => takeString(_fnStr0(fn)());

  @override
  String call1(String fn, String a) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(_fnStr1(fn)(p)));

  @override
  String call2(String fn, String a, String b) => withUtf8(
        a,
        (Pointer<Utf8> pa) => withUtf8(
          b,
          (Pointer<Utf8> pb) => takeString(_fnStr2(fn)(pa, pb)),
        ),
      );

  @override
  String call3(String fn, String a, String b, String c) => withUtf8(
        a,
        (Pointer<Utf8> pa) => withUtf8(
          b,
          (Pointer<Utf8> pb) => withUtf8(
            c,
            (Pointer<Utf8> pc) => takeString(_fnStr3(fn)(pa, pb, pc)),
          ),
        ),
      );

  @override
  String callInt(String fn, int value) => takeString(_fnStrI1(fn)(value));

  @override
  String call1Int(String fn, String a, int value) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(_fnStrP1I1(fn)(p, value)));

  @override
  String call1Int2(String fn, String a, int x, int y) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(_fnStrP1I2(fn)(p, x, y)));

  @override
  String call1Int1(String fn, String a, int value, String b) => withUtf8(
        a,
        (Pointer<Utf8> pa) => withUtf8(
          b,
          (Pointer<Utf8> pb) => takeString(_fnStrP1I1P1(fn)(pa, value, pb)),
        ),
      );

  @override
  String call1Float2(String fn, String a, double x, double y) => withUtf8(
      a, (Pointer<Utf8> p) => takeString(_fnStrP1F2(fn)(p, x, y)));

  @override
  String callFloat3(String fn, double x, double y, double z) =>
      takeString(_fnStrF3(fn)(x, y, z));

  @override
  String callHandle(String fn, int handle) => takeString(_fnStrU1(fn)(handle));

  @override
  String callHandle1(String fn, int handle, String a) => withUtf8(
      a, (Pointer<Utf8> p) => takeString(_fnStrU1P1(fn)(handle, p)));

  @override
  String callHandleInt(String fn, int handle, int value) =>
      takeString(_fnStrU1I1(fn)(handle, value));

  @override
  String callHandle1Int2(String fn, int handle, String a, int x, int y) =>
      withUtf8(
        a,
        (Pointer<Utf8> p) => takeString(_fnStrU1P1I2(fn)(handle, p, x, y)),
      );

  @override
  int callU64(String fn, String a) =>
      withUtf8(a, (Pointer<Utf8> p) => _fnU1P1(fn)(p));

  @override
  void callVoidHandle(String fn, int handle) => _fnVoidU1(fn)(handle);
}
