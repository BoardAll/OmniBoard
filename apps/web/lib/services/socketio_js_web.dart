/// Socket.IO 官方 JS 客户端桥（Web 实现，dart:js_interop；T0.2 POC）。
///
/// 职责：
/// - 动态脚本加载器：幂等注入 `{endpoint}/socket.io/socket.io.min.js`
///   （socket.io@4 服务端自动提供，零 npm 依赖、版本随服务端）；
/// - externals 包装全局 `io()` 与 socket API（connect/disconnect/on/off/
///   emit/volatile emit/engine.transport.name/连接状态）；
/// - [WbSocketIoBridge] 实现（传输抽象，供 realtime_service 注入）。
///
/// 仅允许在 Web（dart2js/DDC）下编译；VM 平台使用 socketio_js_stub.dart。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'socketio_js_types.dart';

// ---------------------------------------------------------------------------
// 动态脚本加载器
// ---------------------------------------------------------------------------

/// 已发起（或已完成）的脚本加载（endpoint → Future），并发调用共享同一 Future。
final Map<String, Future<void>> _loads = <String, Future<void>>{};

/// 动态加载官方 socket.io JS 客户端（幂等）。
///
/// 全局 `io` 已为函数时直接返回；否则注入
/// `<script src="{endpoint}/socket.io/socket.io.min.js">` 并等待其加载完成。
/// 失败（网络错误 / 超时 / 全局 `io()` 未就绪）抛出 [WbSocketIoLoadException]；
/// 失败后再次调用会重试（不复用失败结果）。
Future<void> loadSocketIoClient(String endpoint, {Duration timeout = const Duration(seconds: 10)}) {
  if (_hasIoFactory()) {
    return Future<void>.value();
  }
  return _loads.putIfAbsent(endpoint, () => _loadScript(endpoint, timeout));
}

Future<void> _loadScript(String endpoint, Duration timeout) async {
  try {
    await _injectScript(endpoint).timeout(timeout);
  } on WbSocketIoLoadException {
    _forgetLoad(endpoint);
    rethrow;
  } catch (error) {
    _forgetLoad(endpoint);
    throw WbSocketIoLoadException(endpoint: endpoint, message: '脚本加载失败或超时', cause: error);
  }
  if (!_hasIoFactory()) {
    _forgetLoad(endpoint);
    throw WbSocketIoLoadException(endpoint: endpoint, message: '脚本已注入但全局 io() 未就绪');
  }
}

/// 从加载缓存移除（失败后允许再次调用重试）；对已失效的旧 Future 调用
/// ignore()，保证即使无人 await 也不会上报 unhandled error。
void _forgetLoad(String endpoint) {
  final cached = _loads.remove(endpoint);
  cached?.ignore();
}

/// 注入 `<script src="{endpoint}/socket.io/socket.io.min.js">` 并等待 load/error。
Future<void> _injectScript(String endpoint) {
  final String scriptUri = '${_normalizeEndpoint(endpoint)}/socket.io/socket.io.min.js';
  final completer = Completer<void>();
  final script = _jsDocument.createElement('script');
  script.setAttribute('src', scriptUri);
  script.addEventListener('load', (([JSAny? _]) {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }).toJS);
  script.addEventListener('error', (([JSAny? _]) {
    if (!completer.isCompleted) {
      completer.completeError(WbSocketIoLoadException(endpoint: endpoint, message: '无法加载客户端脚本 $scriptUri'));
    }
  }).toJS);
  final WbJsElement? head = _jsDocument.head;
  if (head == null) {
    completer.completeError(WbSocketIoLoadException(endpoint: endpoint, message: 'document.head 不可用'));
  } else {
    head.appendChild(script);
  }
  return completer.future;
}

/// 全局 `io`（socket.io 客户端工厂）是否已就绪。
bool _hasIoFactory() {
  final JSAny? value = globalContext.getProperty<JSAny?>('io'.toJS);
  return value.typeofEquals('function');
}

String _normalizeEndpoint(String endpoint) {
  var value = endpoint.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

// ---------------------------------------------------------------------------
// dart:js_interop externals
// ---------------------------------------------------------------------------

@JS('document')
external WbJsDocument get _jsDocument;

/// 最小 DOM Document 包装（仅脚本注入所需成员）。
@JS()
extension type WbJsDocument._(JSObject _) implements JSObject {
  /// 创建元素（`document.createElement`）。
  external WbJsElement createElement(String tagName);

  /// `document.head`。
  external WbJsElement? get head;
}

/// 最小 DOM Element 包装（仅脚本注入所需成员）。
@JS()
extension type WbJsElement._(JSObject _) implements JSObject {
  /// 设置属性（`element.setAttribute`）。
  external void setAttribute(String qualifiedName, String value);

  /// 注册事件监听（`element.addEventListener`）。
  external void addEventListener(String type, JSFunction<Function> listener);

  /// 追加子元素（`element.appendChild`）。
  external void appendChild(WbJsElement child);
}

/// 全局 `io(url, options)` 工厂（客户端脚本加载完成后可用）。
@JS('io')
external WbJsSocket _io(String url, [JSAny? options]);

/// Socket.IO 客户端 Socket（`io(url, opts)` 返回值）。
@JS()
extension type WbJsSocket._(JSObject _) implements JSObject {
  /// 底层 Manager（`socket.io`，构造即有）。
  external WbJsManager get io;

  /// 会话 id（连接建立前为 undefined → null）。
  external String? get id;

  /// 是否已连接。
  external bool get connected;

  /// volatile 发送包装（`socket.volatile`；不可用时为 undefined → null）。
  external WbJsVolatile? get volatile;

  /// 发起连接。
  external void connect();

  /// 断开连接。
  external void disconnect();

  /// 注册事件监听。
  external void on(String event, JSFunction<Function> handler);

  /// 移除事件监听。
  external void off(String event, JSFunction<Function> handler);
}

/// socket.io `volatile` 包装（底层传输不可写时消息直接丢弃）。
@JS()
extension type WbJsVolatile._(JSObject _) implements JSObject {}

/// Socket.IO 底层 Manager（`socket.io`）。
@JS()
extension type WbJsManager._(JSObject _) implements JSObject {
  /// 底层 Engine.IO Engine（连接发起前为 undefined → null）。
  external WbJsEngine? get engine;
}

/// Engine.IO Engine。
@JS()
extension type WbJsEngine._(JSObject _) implements JSObject {
  /// 当前传输（未连接时为 undefined → null）。
  external WbJsTransport? get transport;
}

/// Engine.IO Transport。
@JS()
extension type WbJsTransport._(JSObject _) implements JSObject {
  /// 传输名（如 `websocket` / `polling`）。
  external String get name;
}

/// 变参调用 `target.emit(event, ...args)`（可携带 ack 回调作为最后一个参数）。
void _jsEmit(JSObject target, String event, List<JSAny?> args) {
  target.callMethodVarArgs<JSAny?>('emit'.toJS, <JSAny?>[event.toJS, ...args]);
}

// ---------------------------------------------------------------------------
// WbSocketIoBridge 实现
// ---------------------------------------------------------------------------

/// 创建基于官方 JS 客户端的桥实例（需先 [loadSocketIoClient] 成功）。
WbSocketIoBridge createWbSocketIoBridge() => _WbJsSocketIoBridge();

class _WbJsSocketIoBridge implements WbSocketIoBridge {
  WbJsSocket? _socket;
  WbSocketIoConnectionState _state = WbSocketIoConnectionState.idle;
  final Map<String, List<JSFunction<Function>>> _handlers = <String, List<JSFunction<Function>>>{};
  WbSocketIoConnectedCallback? _onConnected;
  WbSocketIoDisconnectedCallback? _onDisconnected;
  WbSocketIoConnectErrorCallback? _onConnectError;

  @override
  WbSocketIoConnectionState get state => _state;

  @override
  bool get isConnected => _socket?.connected ?? false;

  @override
  String? get socketId => _socket?.id;

  @override
  String? get engineTransportName => _socket?.io.engine?.transport?.name;

  @override
  bool get supportsVolatile {
    final socket = _socket;
    return socket != null && socket.volatile != null;
  }

  @override
  void connect(String url, WbSocketIoConnectOptions options) {
    final existing = _socket;
    if (existing != null) {
      // 已创建过 socket：沿用原生语义（重连 / 无操作），不重复注册内部事件。
      _state = WbSocketIoConnectionState.connecting;
      existing.connect();
      return;
    }
    final optionsJs = <String, Object?>{
      'auth': options.auth,
      'reconnection': options.reconnection,
      'forceNew': options.forceNew,
      // 先注册回调，再显式发起连接（时序可控）。
      'autoConnect': false,
      if (options.transports != null) 'transports': options.transports,
    }.jsify();
    final socket = _io(url, optionsJs);
    _socket = socket;
    _state = WbSocketIoConnectionState.connecting;
    _bindLifecycleEvents(socket);
    socket.connect();
  }

  @override
  void on(String event, WbSocketIoEventHandler handler) {
    final socket = _requireSocket('on');
    final JSFunction<Function> jsHandler = (([JSAny? first, JSAny? second]) {
      if (second != null) {
        // 多实参事件（仅 `board:ops` 的 `(ops, meta)` 两参发射）：按
        // 2 元素列表透传；单实参事件（其余全部）保持原载荷形状不变。
        handler(<Object?>[first.dartify(), second.dartify()]);
      } else {
        handler(first.dartify());
      }
    }).toJS;
    (_handlers[event] ??= <JSFunction<Function>>[]).add(jsHandler);
    socket.on(event, jsHandler);
  }

  @override
  void off([String? event]) {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    if (event != null) {
      final handlers = _handlers.remove(event);
      if (handlers != null) {
        for (final handler in handlers) {
          socket.off(event, handler);
        }
      }
      return;
    }
    for (final entry in _handlers.entries) {
      for (final handler in entry.value) {
        socket.off(entry.key, handler);
      }
    }
    _handlers.clear();
  }

  @override
  void emit(String event, [Object? payload]) {
    final socket = _requireSocket('emit');
    _jsEmit(socket, event, <JSAny?>[if (payload != null) payload.jsify()]);
  }

  @override
  Future<Object?> emitWithAck(String event, [Object? payload]) {
    final socket = _requireSocket('emitWithAck');
    final completer = Completer<Object?>();
    final JSFunction<Function> ackHandler = (([JSAny? ackPayload]) {
      if (!completer.isCompleted) {
        completer.complete(ackPayload.dartify());
      }
    }).toJS;
    _jsEmit(socket, event, <JSAny?>[if (payload != null) payload.jsify(), ackHandler]);
    return completer.future;
  }

  @override
  void volatileEmit(String event, [Object? payload]) {
    final socket = _requireSocket('volatileEmit');
    final volatile = socket.volatile;
    if (volatile == null) {
      throw StateError('当前 socket.io 客户端不支持 volatile 发送');
    }
    _jsEmit(volatile, event, <JSAny?>[if (payload != null) payload.jsify()]);
  }

  @override
  void disconnect() {
    _socket?.disconnect();
  }

  @override
  void onConnected(WbSocketIoConnectedCallback callback) {
    _onConnected = callback;
  }

  @override
  void onDisconnected(WbSocketIoDisconnectedCallback callback) {
    _onDisconnected = callback;
  }

  @override
  void onConnectError(WbSocketIoConnectErrorCallback callback) {
    _onConnectError = callback;
  }

  WbJsSocket _requireSocket(String operation) {
    final socket = _socket;
    if (socket == null) {
      throw StateError('WbSocketIoBridge.$operation 需在 connect 之后调用');
    }
    return socket;
  }

  // 注意（DDC 兼容性，T0.2 实测）：所有 JS→Dart 事件回调均使用「可选位置参数」
  // 签名（如 `([JSAny? _]) {...}`）。socket.io 部分事件以 0 个实参调用（典型：
  // connect），而 DDC 运行时严格校验实参个数：声明 1 个必需参数却收到 0 个实参
  // 时会抛 NoSuchMethodError 并中断回调链（表现为连接成功但事件回调全部丢失）。

  void _bindLifecycleEvents(WbJsSocket socket) {
    socket.on('connect', (([JSAny? _]) {
      _state = WbSocketIoConnectionState.connected;
      _onConnected?.call(socket.id ?? '', engineTransportName);
    }).toJS);
    socket.on('disconnect', (([JSAny? reason]) {
      _state = WbSocketIoConnectionState.disconnected;
      final text = reason.dartify();
      _onDisconnected?.call(text is String ? text : 'unknown');
    }).toJS);
    socket.on('connect_error', (([JSAny? error]) {
      _state = WbSocketIoConnectionState.connectError;
      _onConnectError?.call(_parseConnectError(error));
    }).toJS);
  }

  WbSocketIoConnectError _parseConnectError(JSAny? error) {
    if (error is! JSObject) {
      final raw = error.dartify();
      return WbSocketIoConnectError(message: raw == null ? 'connect_error' : raw.toString());
    }
    var message = 'connect_error';
    final messageDart = error.getProperty<JSAny?>('message'.toJS).dartify();
    if (messageDart is String && messageDart.isNotEmpty) {
      message = messageDart;
    }
    String? code;
    final data = error.getProperty<JSAny?>('data'.toJS);
    if (data is JSObject) {
      final codeDart = data.getProperty<JSAny?>('code'.toJS).dartify();
      if (codeDart is String && codeDart.isNotEmpty) {
        code = codeDart;
      }
    }
    return WbSocketIoConnectError(message: message, code: code);
  }
}
