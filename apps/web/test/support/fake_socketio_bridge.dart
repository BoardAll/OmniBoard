/// 测试用假 Socket.IO 桥（T1.8）：记录调用、手动触发事件与生命周期。
///
/// 供 `realtime_service_test.dart` / `collab_widget_test.dart` 注入使用；
/// 非 `_test.dart` 后缀，不会被 `flutter test` 当作用例文件执行。
library;

import 'package:whiteboard_web/services/socketio_js.dart';

/// `emitWithAck` 调用记录。
typedef FakeAckCall = ({String event, Object? payload});

/// `emit` / `volatileEmit` 调用记录。
typedef FakeEmitCall = ({String event, Object? payload});

/// 假桥：不触达网络，所有行为由测试代码手动驱动。
///
/// - [connect] 仅记录并进入 `connecting`，连接结果由 [fireConnected] /
///   [fireConnectError] 触发；
/// - [on] 注册的事件由 [fireEvent] 分发；
/// - [emitWithAck] 默认立即返回 [ackResponse]（`{'ok': true}`），可用
///   [ackHandler] 覆盖（如挂起的 Future 模拟 ack 超时）。
class FakeSocketIoBridge implements WbSocketIoBridge {
  /// 每次 [connect] 的调用记录。
  final List<({String url, WbSocketIoConnectOptions options})> connectCalls =
      <({String url, WbSocketIoConnectOptions options})>[];

  /// 每次 [emitWithAck] 的调用记录。
  final List<FakeAckCall> ackCalls = <FakeAckCall>[];

  /// 每次 [emit] 的调用记录。
  final List<FakeEmitCall> emits = <FakeEmitCall>[];

  /// 每次 [volatileEmit] 的调用记录。
  final List<FakeEmitCall> volatileEmits = <FakeEmitCall>[];

  /// 每次 [off] 的调用记录（含事件名，null 表示全量移除）。
  final List<String?> offCalls = <String?>[];

  /// [disconnect] 调用次数。
  int disconnectCalls = 0;

  /// `emitWithAck` 的默认 ack 载荷（未设置 [ackHandler] 时返回）。
  Object? ackResponse = const <String, Object?>{'ok': true};

  /// 自定义 ack 行为（优先于 [ackResponse]；可返回挂起 Future 模拟超时）。
  Future<Object?> Function(String event, Object? payload)? ackHandler;

  WbSocketIoConnectionState _state = WbSocketIoConnectionState.idle;
  bool _connected = false;
  String? _socketId;
  String? _transport;
  WbSocketIoConnectedCallback? _onConnected;
  WbSocketIoDisconnectedCallback? _onDisconnected;
  WbSocketIoConnectErrorCallback? _onConnectError;
  final Map<String, List<WbSocketIoEventHandler>> _handlers =
      <String, List<WbSocketIoEventHandler>>{};

  @override
  WbSocketIoConnectionState get state => _state;

  @override
  bool get isConnected => _connected;

  @override
  String? get socketId => _socketId;

  @override
  String? get engineTransportName => _transport;

  @override
  bool get supportsVolatile => false;

  @override
  void connect(String url, WbSocketIoConnectOptions options) {
    connectCalls.add((url: url, options: options));
    _state = WbSocketIoConnectionState.connecting;
  }

  @override
  void on(String event, WbSocketIoEventHandler handler) {
    _handlers.putIfAbsent(event, () => <WbSocketIoEventHandler>[]).add(handler);
  }

  @override
  void off([String? event]) {
    offCalls.add(event);
    if (event == null) {
      _handlers.clear();
    } else {
      _handlers.remove(event);
    }
  }

  @override
  void emit(String event, [Object? payload]) {
    emits.add((event: event, payload: payload));
  }

  @override
  Future<Object?> emitWithAck(String event, [Object? payload]) {
    ackCalls.add((event: event, payload: payload));
    final Future<Object?> Function(String, Object?)? handler = ackHandler;
    if (handler != null) {
      return handler(event, payload);
    }
    return Future<Object?>.value(ackResponse);
  }

  @override
  void volatileEmit(String event, [Object? payload]) {
    volatileEmits.add((event: event, payload: payload));
  }

  @override
  void disconnect() {
    disconnectCalls += 1;
    _connected = false;
    _socketId = null;
    _state = WbSocketIoConnectionState.disconnected;
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

  // -------------------------------------------------------------------------
  // 手动触发（测试驱动）
  // -------------------------------------------------------------------------

  /// 触发连接成功（状态 → `connected`）。
  void fireConnected({String socketId = 'sock-1', String? transport = 'websocket'}) {
    _state = WbSocketIoConnectionState.connected;
    _connected = true;
    _socketId = socketId;
    _transport = transport;
    _onConnected?.call(socketId, transport);
  }

  /// 触发断开（状态 → `disconnected`）。
  void fireDisconnected([String reason = 'transport close']) {
    _state = WbSocketIoConnectionState.disconnected;
    _connected = false;
    _socketId = null;
    _onDisconnected?.call(reason);
  }

  /// 触发连接错误（状态 → `connectError`）。
  void fireConnectError(WbSocketIoConnectError error) {
    _state = WbSocketIoConnectionState.connectError;
    _onConnectError?.call(error);
  }

  /// 触发服务端事件（分发给已注册的全部回调）。
  void fireEvent(String event, Object? payload) {
    final List<WbSocketIoEventHandler>? handlers = _handlers[event];
    if (handlers == null) {
      return;
    }
    for (final WbSocketIoEventHandler handler in List<WbSocketIoEventHandler>.of(handlers)) {
      handler(payload);
    }
  }

  /// 某事件已注册的回调数量。
  int handlerCount(String event) => _handlers[event]?.length ?? 0;
}
