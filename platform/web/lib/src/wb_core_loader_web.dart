/// WASM 核心加载器的 Web 实现（`dart:js_interop` + `package:web`）。
///
/// 加载流程（《Web 端方案设计（Flutter Web + WASM）v1.0》§6.1）：
/// 1. 若全局已有 `window.WbCore`（Emscripten `MODULARIZE=1` 工厂），直接调用；
/// 2. 否则向 `<head>` 注入 `wb_core.js`（`<script>`），等待 load / error；
/// 3. 调用 `WbCore()` 工厂获得 Promise，等待 WASM 实例化完成；
/// 4. 任一步失败（脚本缺失 / 超时 / Promise 拒绝）→ 返回
///    [WbCoreStatus.unavailable]，不抛异常，由上层降级运行（§9.4）。
///
/// 仅 Web 目标编译（条件导入选择），VM 目标使用桩实现
/// （`wb_core_loader_stub.dart`）。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'wb_core_bindings_web.dart';
import 'wb_core_types.dart';

/// WASM 核心加载器（Web 实现）。
class WbCoreLoader {
  /// 创建加载器。
  ///
  /// [scriptUrl] 为 `wb_core.js` 的 URL（相对 index.html 或 CDN 绝对地址）；
  /// [loadTimeout] 同时约束"脚本注入"与"模块实例化"两阶段。
  WbCoreLoader({
    this.scriptUrl = defaultScriptUrl,
    this.loadTimeout = defaultLoadTimeout,
  });

  /// 默认脚本路径（与 `apps/web/web/wb_core.js` 部署约定一致）。
  static const String defaultScriptUrl = 'wb_core.js';

  /// 默认加载超时。
  static const Duration defaultLoadTimeout = Duration(seconds: 15);

  /// 脚本 URL。
  final String scriptUrl;

  /// 加载超时。
  final Duration loadTimeout;

  WbCoreModule? _module;
  WbCoreStatus _status = WbCoreStatus.idle;
  Completer<WbCoreStatus>? _pending;
  bool _scriptInjected = false;
  final StreamController<double> _progress =
      StreamController<double>.broadcast();

  /// 当前加载状态。
  WbCoreStatus get status => _status;

  /// 是否已加载并可用。
  bool get isAvailable => _status.isAvailable;

  /// 已加载的模块（未就绪时为 null）。
  WbCoreModule? get module => _module;

  /// 加载进度（0.0 → 1.0，广播流，可多次监听）。
  Stream<double> get progress => _progress.stream;

  /// 加载 WASM 核心（幂等）。
  ///
  /// 并发调用共享同一次加载；已成功 / 已失败时直接返回缓存状态。
  /// 加载失败不会抛异常，也不会自动重试（需要重试时创建新实例并
  /// 使用新的 `scriptUrl`，或在脚本修复后刷新页面）。
  Future<WbCoreStatus> load() {
    final WbCoreStatus current = _status;
    if (current != WbCoreStatus.idle && current != WbCoreStatus.loading) {
      return Future<WbCoreStatus>.value(current);
    }
    final Completer<WbCoreStatus>? pending = _pending;
    if (pending != null) {
      return pending.future;
    }
    final Completer<WbCoreStatus> completer = Completer<WbCoreStatus>();
    _pending = completer;
    _status = WbCoreStatus.loading;
    unawaited(_runLoad(completer));
    return completer.future;
  }

  /// `ccall` 代理；模块未就绪时返回 null。
  ///
  /// 数字参数可直接传；字符串 / 数组参数请使用 [cwrap] 并指定
  /// `argTypes`（Emscripten `ccall` 需要类型信息做编解码）。
  Future<Object?> call(
    String name, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final WbCoreModule? module = _module;
    if (module == null) {
      return null;
    }
    return _fromJs(module.ccall(name, null, null, _toJsArgs(args)));
  }

  /// 调用返回 `const char*`（UTF-8 字符串 / JSON）的导出函数。
  ///
  /// 与 [call] 不同，本方法按 Dart 参数自动推断 `argTypes`
  /// （`String` → `string`，`bool` → `boolean`，其余 → `number`），
  /// 读出返回指针后经模块 `free` 立即释放。模块未就绪或返回空指针
  /// （0）时返回 null，不抛异常。
  Future<String?> callString(
    String name, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final WbCoreModule? module = _module;
    if (module == null) {
      return null;
    }
    final JSAny? raw =
        module.ccall(name, 'number', _argTypesOf(args), _toJsArgs(args));
    if (raw == null || !raw.typeofEquals('number')) {
      return null;
    }
    final int ptr = (raw as JSNumber).toDartInt;
    if (ptr == 0) {
      return null;
    }
    final String text = module.utf8ToString(ptr);
    module.free(ptr);
    return text;
  }

  /// 调用返回整数的导出函数（`argTypes` 自动推断，同 [callString]）。
  ///
  /// 模块未就绪或返回值非数字时返回 null。
  Future<int?> callInt(
    String name, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final WbCoreModule? module = _module;
    if (module == null) {
      return null;
    }
    final JSAny? raw =
        module.ccall(name, 'number', _argTypesOf(args), _toJsArgs(args));
    if (raw == null || !raw.typeofEquals('number')) {
      return null;
    }
    return (raw as JSNumber).toDartInt;
  }

  /// `cwrap` 代理；模块未就绪时返回 null。
  ///
  /// 返回的 [WbCoreCallable] 可反复调用（内部走 Emscripten `cwrap`
  /// 包装的 JS 函数）。
  WbCoreCallable? cwrap(
    String name, {
    String? returnType,
    List<String> argTypes = const <String>[],
  }) {
    final WbCoreModule? module = _module;
    if (module == null) {
      return null;
    }
    final JSArray<JSString> jsArgTypes =
        argTypes.map((String type) => type.toJS).toList().toJS;
    final JSFunction function = module.cwrap(name, returnType, jsArgTypes);
    return (List<Object?> args) => _fromJs(_applyFunction(function, args));
  }

  /// 释放加载器资源（关闭进度流）。
  void dispose() {
    unawaited(_progress.close());
  }

  Future<void> _runLoad(Completer<WbCoreStatus> completer) async {
    WbCoreStatus result = WbCoreStatus.unavailable;
    try {
      _emitProgress(0.0);

      JSFunction? factory = _lookupFactory();
      if (factory == null) {
        // 注入脚本；wb_core.js 若不定义 window.WbCore
        // （占位脚本 / 资源缺失），注入后进入 unavailable。
        await _injectScript().timeout(loadTimeout);
        _emitProgress(0.5);
        factory = _lookupFactory();
      }

      if (factory != null) {
        _emitProgress(0.7);
        final JSAny? promise = factory.callAsFunction();
        if (promise.instanceOfString('Promise')) {
          final JSAny? moduleValue =
              await (promise as JSPromise<JSAny?>).toDart.timeout(loadTimeout);
          if (moduleValue.instanceOfString('Object')) {
            _module = WbCoreModule.fromModule(moduleValue as JSObject);
            _emitProgress(1.0);
            result = WbCoreStatus.ready;
          }
        }
      }
    } catch (_) {
      // 脚本加载失败 / 超时 / 工厂 Promise 拒绝 → 降级为不可用（不抛出）。
      result = WbCoreStatus.unavailable;
    }

    _status = result;
    _pending = null;
    if (!completer.isCompleted) {
      completer.complete(result);
    }
  }

  /// 查找全局 `window.WbCore` 工厂（Emscripten `EXPORT_NAME`）。
  JSFunction? _lookupFactory() {
    final JSAny? value = globalContext.getProperty<JSAny?>('WbCore'.toJS);
    if (value != null && value.typeofEquals('function')) {
      return value as JSFunction;
    }
    return null;
  }

  /// 向 `<head>` 注入 `wb_core.js`，等待 load / error 事件。
  Future<void> _injectScript() {
    if (_scriptInjected) {
      return Future<void>.value();
    }
    _scriptInjected = true;

    final Completer<void> completer = Completer<void>();
    final web.HTMLScriptElement script =
        web.document.createElement('script') as web.HTMLScriptElement;
    script.src = scriptUrl;
    script.async = true;
    script.addEventListener(
      'load',
      (web.Event _) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }.toJS,
    );
    script.addEventListener(
      'error',
      (web.Event _) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('wb_core.js 加载失败: $scriptUrl'),
          );
        }
      }.toJS,
    );
    web.document.head?.append(script);
    return completer.future;
  }

  JSAny? _applyFunction(JSFunction function, List<Object?> args) {
    // `Function.prototype.apply(thisArg, argsArray)`：thisArg 传 null
    // （cwrap 包装的函数不依赖 this），参数数组整体传入。
    // 注意 `callMethod` 仅支持最多 4 个定长参数，变长参数必须用
    // `callMethodVarArgs`。
    final JSArray<JSAny?> jsArgs = _toJsArgs(args);
    return function
        .callMethodVarArgs<JSAny?>('apply'.toJS, <JSAny?>[null, jsArgs]);
  }

  JSArray<JSAny?> _toJsArgs(List<Object?> args) =>
      args.map(_toJs).toList().toJS;

  /// 依据 Dart 参数类型推断 ccall 的 `argTypes`。
  static JSArray<JSString> _argTypesOf(List<Object?> args) => args
      .map(
        (Object? arg) => switch (arg) {
          final String _ => 'string'.toJS,
          final bool _ => 'boolean'.toJS,
          _ => 'number'.toJS,
        },
      )
      .toList()
      .toJS;

  void _emitProgress(double value) {
    if (!_progress.isClosed) {
      _progress.add(value);
    }
  }
}

/// Dart 值 → JS 值（仅支持可传递的基础类型）。
JSAny? _toJs(Object? value) => switch (value) {
      null => null,
      final String v => v.toJS,
      final int v => v.toJS,
      final double v => v.toJS,
      final bool v => v.toJS,
      _ => throw ArgumentError('不支持的 WASM 参数类型: ${value.runtimeType}'),
    };

/// JS 值 → Dart 值（基础类型自动转换，其余返回不透明 JS 对象）。
Object? _fromJs(JSAny? value) {
  if (value == null) {
    return null;
  }
  if (value.typeofEquals('string')) {
    return (value as JSString).toDart;
  }
  if (value.typeofEquals('number')) {
    final double asDouble = (value as JSNumber).toDartDouble;
    if (asDouble.isFinite) {
      final int asInt = asDouble.toInt();
      if (asInt.toDouble() == asDouble) {
        return asInt;
      }
    }
    return asDouble;
  }
  if (value.typeofEquals('boolean')) {
    return (value as JSBoolean).toDart;
  }
  return value;
}
