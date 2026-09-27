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
/// final int handle = core.createBoard('{"name":"board"}');
/// ```
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// 全局工厂：`WbCore([moduleOverrides]) => Promise<Module>`。
@JS('WbCore')
external JSPromise<JSObject> _wbCoreFactory([JSObject? moduleOverrides]);

/// Web 端引擎封装：与 [WbCoreFfi] 契约面保持一致的最小实现。
///
/// 所有 `wb_*` 返回的 `char*` 都由引擎 malloc，读取后立即通过 `_wb_free`
/// 释放，避免 Web 端内存泄漏。
class WbCoreWasm {
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

  /// 是否已实例化。
  static bool get isLoaded => _instance != null;

  /// 底层 Emscripten Module 对象（高级用法）。
  JSObject get module => _module;

  // ---- 契约面（与 WbCoreFfi 一致） -----------------------------------

  String init() => callString('wb_init');

  String shutdown() => callString('wb_shutdown');

  String versionString() => callString('wb_version');

  /// 创建画板，返回引擎句柄（0 表示失败）。
  int createBoard(String boardJson) =>
      callInt('wb_create_board', <Object>[boardJson]);

  void destroyBoard(int handle) =>
      callVoid('wb_destroy_board', <Object>[handle]);

  String boardGet(int handle) =>
      callString('wb_board_get', <Object>[handle]);

  String executeCommand(int handle, String commandJson) =>
      callString('wb_execute_command', <Object>[handle, commandJson]);

  String executeTool(int handle, String toolId, String argsJson) =>
      callString('wb_execute_tool', <Object>[handle, toolId, argsJson]);

  // ---- 泛型调用 -------------------------------------------------------

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

  /// 调用返回整数的导出函数。
  int callInt(String fn, [List<Object> args = const <Object>[]]) {
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
