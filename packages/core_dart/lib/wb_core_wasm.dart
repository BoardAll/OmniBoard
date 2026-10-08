/// Web 端（WASM）引擎入口。
///
/// 该文件只允许 Flutter Web 构建引用；桌面/移动端使用 `wb_core_ffi.dart`。
/// 引擎以 Emscripten `MODULARIZE=1` + `EXPORT_NAME=WbCore` 构建，
/// 全局工厂 `WbCore()` 返回 Promise<Module>，经 `ccall` 调用导出符号。
///
/// 典型用法（apps/web）：
/// ```dart
/// final WbCoreWasm core = await WbCoreWasm.load();
/// core.init();
/// final int handle = core.callU64('wb_create_board', '{"name":"board"}');
/// ```
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'engine.dart';

/// 全局工厂：`WbCore([moduleOverrides]) => Promise<Module>`。
@JS('WbCore')
external JSPromise<JSObject> _wbCoreFactory([JSObject? moduleOverrides]);

/// Web 端引擎封装：实现平台中立契约 [WbEngineCaller]（与桌面 `WbCoreFfi`
/// 同构），域服务（`services/*`）在两端共用。
///
/// 所有 `wb_*` 返回的 `char*` 都由引擎 malloc，读取后立即通过 `_wb_free`
/// 释放，避免 Web 端内存泄漏。
class WbCoreWasm implements WbEngineCaller {
  WbCoreWasm._(this._module);

  static WbCoreWasm? _instance;
  static Future<WbCoreWasm>? _loading;

  final JSObject _module;

  /// 加载并实例化引擎模块（幂等，多次调用共享同一实例）。
  static Future<WbCoreWasm> load([JSObject? moduleOverrides]) {
    final WbCoreWasm? ready = _instance;
    if (ready != null) {
      return Future<WbCoreWasm>.value(ready);
    }
    return _loading ??= _wbCoreFactory(moduleOverrides).toDart.then(
      (JSObject module) {
        final WbCoreWasm core = WbCoreWasm._(module);
        _instance = core;
        return core;
      },
    );
  }

  /// 从已加载的 Emscripten Module 创建引擎（宿主已自行完成脚本加载 /
  /// 降级判定，如 `platform/web` 的 WbCoreLoader 先探测资源再交入）。
  ///
  /// [module] 为模块对象（`WbCoreLoader.module` / `WbCore()` 工厂产物）；
  /// 参数类型声明为 [Object] 以便宿主经条件导入（分析器按桩解析）调用，
  /// 运行时校验为 JS 对象。
  ///
  /// 同时缓存为全局单例（[isLoaded] / [load] 与之共享同一实例）。
  factory WbCoreWasm.fromModule(Object module) {
    final WbCoreWasm core = WbCoreWasm._(module as JSObject);
    _instance = core;
    return core;
  }

  /// 是否已实例化。
  static bool get isLoaded => _instance != null;

  /// 底层 Emscripten Module 对象（高级用法）。
  JSObject get module => _module;

  // ---- 契约面（[WbEngineCaller]） --------------------------------------

  @override
  int init([String configJson = '{}']) =>
      callIntResult('wb_init', <Object>[configJson]);

  /// 关闭引擎（幂等；`wb_shutdown` 返回 void）。
  @override
  void shutdown() => callVoid('wb_shutdown');

  @override
  String versionString() => callString('wb_version');

  @override
  String call0(String fn) => callString(fn);

  @override
  String call1(String fn, String a) => callString(fn, <Object>[a]);

  @override
  String call2(String fn, String a, String b) => callString(fn, <Object>[a, b]);

  @override
  String call3(String fn, String a, String b, String c) =>
      callString(fn, <Object>[a, b, c]);

  @override
  String callInt(String fn, int value) => callString(fn, <Object>[value]);

  @override
  String call1Int(String fn, String a, int value) =>
      callString(fn, <Object>[a, value]);

  @override
  String call1Int2(String fn, String a, int x, int y) =>
      callString(fn, <Object>[a, x, y]);

  @override
  String call1Int1(String fn, String a, int value, String b) =>
      callString(fn, <Object>[a, value, b]);

  @override
  String call1Float2(String fn, String a, double x, double y) =>
      callString(fn, <Object>[a, x, y]);

  @override
  String callFloat3(String fn, double x, double y, double z) =>
      callString(fn, <Object>[x, y, z]);

  @override
  String callHandle(String fn, int handle) => callString(fn, <Object>[handle]);

  @override
  String callHandle1(String fn, int handle, String a) =>
      callString(fn, <Object>[handle, a]);

  @override
  String callHandleInt(String fn, int handle, int value) =>
      callString(fn, <Object>[handle, value]);

  @override
  String callHandle1Int2(String fn, int handle, String a, int x, int y) =>
      callString(fn, <Object>[handle, a, x, y]);

  /// 调用返回 `uint64_t` 的导出函数（如 `wb_create_board` 返回句柄）。
  @override
  int callU64(String fn, String a) => callIntResult(fn, <Object>[a]);

  /// 调用 `void f(uint64_t)` 的导出函数（如 `wb_destroy_board`）。
  @override
  void callVoidHandle(String fn, int handle) => callVoid(fn, <Object>[handle]);

  // ---- 泛型调用（底层，供高级用法） ------------------------------------

  /// 调用返回 `const char*`（须释放）的导出函数并取出字符串。
  String callString(String fn, [List<Object> args = const <Object>[]]) {
    final JSAny? raw = _invoke(fn, args, 'number');
    final JSNumber? ptr = raw as JSNumber?;
    if (ptr == null || ptr.toDartInt == 0) {
      return '';
    }
    final String text = _utf8ToString(ptr);
    _free(ptr);
    return text;
  }

  /// 调用返回整数的导出函数（原 `callInt`，为避免与
  /// [WbEngineCaller.callInt] 签名冲突而更名）。
  int callIntResult(String fn, [List<Object> args = const <Object>[]]) {
    final JSAny? raw = _invoke(fn, args, 'number');
    return raw is JSNumber ? raw.toDartInt : 0;
  }

  /// 调用返回 void 的导出函数。
  void callVoid(String fn, [List<Object> args = const <Object>[]]) {
    _invoke(fn, args, null);
  }

  JSAny? _invoke(String fn, List<Object> args, String? returnType) {
    final List<JSAny> jsArgs =
        args.map(_marshalArg).toList(growable: false);
    final List<JSAny> argTypes =
        args.map(_argTypeOf).toList(growable: false);
    final JSFunction ccall = _module.getProperty<JSFunction>('ccall'.toJS);
    return ccall.callAsFunction(
      _module,
      fn.toJS,
      returnType?.toJS,
      argTypes.toJS,
      jsArgs.toJS,
    );
  }

  String _utf8ToString(JSNumber ptr) {
    final JSFunction toDartString =
        _module.getProperty<JSFunction>('UTF8ToString'.toJS);
    final JSAny? value = toDartString.callAsFunction(_module, ptr);
    return (value! as JSString).toDart;
  }

  void _free(JSNumber ptr) {
    final JSFunction free = _module.getProperty<JSFunction>('_wb_free'.toJS);
    free.callAsFunction(_module, ptr);
  }

  static JSAny _marshalArg(Object arg) {
    if (arg is String) {
      return arg.toJS;
    }
    if (arg is int) {
      return arg.toJS;
    }
    if (arg is double) {
      return arg.toJS;
    }
    if (arg is bool) {
      return arg.toJS;
    }
    throw ArgumentError.value(arg, 'arg', 'WASM 调用仅支持 String/int/double/bool');
  }

  static JSString _argTypeOf(Object arg) {
    if (arg is String) {
      return 'string'.toJS;
    }
    if (arg is num) {
      return 'number'.toJS;
    }
    if (arg is bool) {
      return 'boolean'.toJS;
    }
    throw ArgumentError.value(
      arg,
      'arg',
      'WASM 调用仅支持 String/int/double/bool',
    );
  }
}
