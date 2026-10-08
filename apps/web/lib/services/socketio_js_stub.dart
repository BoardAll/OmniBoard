/// Socket.IO 传输桥桩实现（非 Web 平台；T0.2 POC）。
///
/// VM（纯 Dart）与原生平台不加载 JS：
/// - [loadSocketIoClient] 以 [WbSocketIoLoadException] 失败（调用方据此降级）；
/// - 桥的 [WbSocketIoBridge.connect] 触发一次 `UnsupportedPlatform` 错误回调，
///   其余操作安全降级（no-op / 明确的 UnsupportedError）。
library;

import 'dart:async';

import 'socketio_js_types.dart';

/// 非 Web 平台：不加载（也不支持）Socket.IO JS 客户端。
Future<void> loadSocketIoClient(String endpoint, {Duration timeout = const Duration(seconds: 10)}) {
  return Future<void>.error(
    WbSocketIoLoadException(
      endpoint: endpoint,
      message: 'Socket.IO JS 桥仅支持 Web 平台（当前为 VM/原生环境）',
    ),
  );
}

/// 创建 VM 桩桥（永不建立连接）。
WbSocketIoBridge createWbSocketIoBridge() => _WbStubSocketIoBridge();

class _WbStubSocketIoBridge implements WbSocketIoBridge {
  WbSocketIoConnectionState _state = WbSocketIoConnectionState.idle;
  WbSocketIoConnectErrorCallback? _onConnectError;

  @override
  WbSocketIoConnectionState get state => _state;

  @override
  bool get isConnected => false;

  @override
  String? get socketId => null;

  @override
  String? get engineTransportName => null;

  @override
  bool get supportsVolatile => false;

  @override
  void connect(String url, WbSocketIoConnectOptions options) {
    _state = WbSocketIoConnectionState.connectError;
    final callback = _onConnectError;
    if (callback != null) {
      scheduleMicrotask(() {
        callback(
          const WbSocketIoConnectError(
            message: '非 Web 平台不支持 Socket.IO JS 桥',
            code: 'UnsupportedPlatform',
          ),
        );
      });
    }
  }

  @override
  void on(String event, WbSocketIoEventHandler handler) {}

  @override
  void off([String? event]) {}

  @override
  void emit(String event, [Object? payload]) {}

  @override
  Future<Object?> emitWithAck(String event, [Object? payload]) {
    return Future<Object?>.error(UnsupportedError('非 Web 平台不支持 Socket.IO JS 桥（emitWithAck）'));
  }

  @override
  void volatileEmit(String event, [Object? payload]) {}

  @override
  void disconnect() {
    if (_state != WbSocketIoConnectionState.idle) {
      _state = WbSocketIoConnectionState.disconnected;
    }
  }

  @override
  void onConnected(WbSocketIoConnectedCallback callback) {}

  @override
  void onDisconnected(WbSocketIoDisconnectedCallback callback) {}

  @override
  void onConnectError(WbSocketIoConnectErrorCallback callback) {
    _onConnectError = callback;
  }
}
