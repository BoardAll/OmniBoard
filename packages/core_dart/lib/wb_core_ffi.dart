/// wb_core_ffi.dart — FFI surface over the native wb_core library.
///
/// Task package 2.3 wires the Wave 0 call surface to the full
/// [WbCoreBindings] table (100 exports of `core/include/wb/wb.h`).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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
/// Methods return decoded UTF-8 strings; callers own no native memory.
class WbCoreFfi {
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
  int init([String configJson = '{}']) {
    return withUtf8(configJson, (Pointer<Utf8> p) => bindings.wbInit(p));
  }

  /// Calls `wb_shutdown`.
  void shutdown() => bindings.wbShutdown();

  /// Raw library version string (not a JSON envelope).
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

  // ---- Generic call helpers (string-in / JSON-string-out) ------------------

  /// `const char* f()`
  String call0(WbStr0Dart fn) => takeString(fn());

  /// `const char* f(const char*)`
  String call1(WbStr1Dart fn, String a) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(fn(p)));

  /// `const char* f(const char*, const char*)`
  String call2(WbStr2Dart fn, String a, String b) => withUtf8(
        a,
        (Pointer<Utf8> pa) =>
            withUtf8(b, (Pointer<Utf8> pb) => takeString(fn(pa, pb))),
      );

  /// `const char* f(const char*, const char*, const char*)`
  String call3(WbStr3Dart fn, String a, String b, String c) => withUtf8(
        a,
        (Pointer<Utf8> pa) => withUtf8(
          b,
          (Pointer<Utf8> pb) =>
              withUtf8(c, (Pointer<Utf8> pc) => takeString(fn(pa, pb, pc))),
        ),
      );

  /// `const char* f(int)`
  String callInt(WbStrI1Dart fn, int value) => takeString(fn(value));

  /// `const char* f(const char*, int)`
  String call1Int(WbStrP1I1Dart fn, String a, int value) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(fn(p, value)));

  /// `const char* f(const char*, int, int)`
  String call1Int2(WbStrP1I2Dart fn, String a, int x, int y) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(fn(p, x, y)));

  /// `const char* f(const char*, int, const char*)`
  String call1Int1(WbStrP1I1P1Dart fn, String a, int value, String b) =>
      withUtf8(
        a,
        (Pointer<Utf8> pa) =>
            withUtf8(b, (Pointer<Utf8> pb) => takeString(fn(pa, value, pb))),
      );

  /// `const char* f(const char*, float, float)`
  String call1Float2(WbStrP1F2Dart fn, String a, double x, double y) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(fn(p, x, y)));

  /// `const char* f(float, float, float)`
  String callFloat3(WbStrF3Dart fn, double x, double y, double z) =>
      takeString(fn(x, y, z));

  /// `const char* f(uint64_t)`
  String callHandle(WbStrU1Dart fn, int handle) => takeString(fn(handle));

  /// `const char* f(uint64_t, const char*)`
  String callHandle1(WbStrU1P1Dart fn, int handle, String a) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(fn(handle, p)));

  /// `const char* f(uint64_t, int)`
  String callHandleInt(WbStrU1I1Dart fn, int handle, int value) =>
      takeString(fn(handle, value));

  /// `const char* f(uint64_t, const char*, int, int)`
  String callHandle1Int2(
    WbStrU1P1I2Dart fn,
    int handle,
    String a,
    int x,
    int y,
  ) =>
      withUtf8(a, (Pointer<Utf8> p) => takeString(fn(handle, p, x, y)));
}
