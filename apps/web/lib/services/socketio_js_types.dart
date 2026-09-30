/// Socket.IO 传输桥：接口与数据模型（平台无关，VM 安全；T0.2 POC）。
///
/// 设计依据（《互动白板实时协同设计文档》§2.2 / §8.4）：
/// - Web 端使用官方 socket.io JS 客户端，经 dart:js_interop 桥接入；
/// - 客户端脚本动态从服务端加载：`{endpoint}/socket.io/socket.io.min.js`
///   （socket.io@4 服务端自动提供该文件，零 npm 依赖、版本随服务端）；
/// - `realtime_service` 注入本接口（传输抽象）：VM（纯 Dart）测试不加载 JS，
///   仅浏览器路径走 js_interop 实现（socketio_js_web.dart）。
library;

/// Socket.IO 连接状态（桥视角的粗粒度状态机）。
enum WbSocketIoConnectionState {
  /// 尚未调用 [WbSocketIoBridge.connect]。
  idle,

  /// 连接进行中（含自动重连尝试）。
  connecting,

  /// 已建立连接。
  connected,

  /// 已断开（可能正在自动重连）。
  disconnected,

  /// 连接失败（含鉴权拒连）；是否重试由 `reconnection` 选项决定。
  connectError,
}

/// 连接错误（对应 JS 侧 `connect_error` 事件参数；含鉴权拒连）。
class WbSocketIoConnectError {
  /// 创建连接错误。
  const WbSocketIoConnectError({required this.message, this.code});

  /// 人类可读错误信息（如 `Unauthorized: invalid or expired token`）。
  final String message;

  /// 服务端错误码（`err.data.code`，如 `Unauthorized`）；无则为 null。
  final String? code;

  @override
  String toString() => code == null
      ? 'WbSocketIoConnectError($message)'
      : 'WbSocketIoConnectError($code: $message)';
}

/// 连接选项（映射为 socket.io 客户端 `io(url, opts)` 选项的子集）。
///
/// 桥内部固定追加 `autoConnect: false` 并在 [WbSocketIoBridge.connect] 内显式
/// 调用 `socket.connect()`，保证“先注册回调、后发起连接”的时序可控。
class WbSocketIoConnectOptions {
  /// 创建连接选项。
  const WbSocketIoConnectOptions({
    this.auth = const <String, Object?>{},
    this.transports,
    this.reconnection = true,
    this.forceNew = true,
  });

  /// 握手认证载荷（`handshake.auth`），如 `{token, boardId, clientVersion}`。
  final Map<String, Object?> auth;

  /// 传输方式白名单：
  /// - null：socket.io 默认（polling 起步，自动升级 websocket）；
  /// - `['websocket']`：直连 WebSocket（无升级阶段）；
  /// - `['polling']`：仅 HTTP long-polling（降级对照）。
  final List<String>? transports;

  /// 是否自动重连（默认 true）。
  final bool reconnection;

  /// 是否强制新建底层 Manager（默认 true，避免多桥实例复用同一连接）。
  final bool forceNew;
}

/// 事件回调：`payload` 为 `dartify` 后的值（Map/List/String/num/bool/null）。
typedef WbSocketIoEventHandler = void Function(Object? payload);

/// 连接成功回调：`socketId` 为本次会话 socket id；`transport` 为连接时刻传输名。
typedef WbSocketIoConnectedCallback = void Function(String socketId, String? transport);

/// 断开回调：`reason` 为 socket.io 断开原因（如 `io server disconnect`）。
typedef WbSocketIoDisconnectedCallback = void Function(String reason);

/// 连接错误回调。
typedef WbSocketIoConnectErrorCallback = void Function(WbSocketIoConnectError error);

/// Socket.IO 传输桥（供 `realtime_service` 注入使用的最小抽象）。
///
/// 实现：
/// - Web：dart:js_interop 桥接官方 JS 客户端（socketio_js_web.dart）；
/// - VM/原生：桩实现（socketio_js_stub.dart），不加载 JS、连接以
///   `UnsupportedPlatform` 错误回调失败。
///
/// 时序约定：
/// - [connect] 非阻塞；结果经 [onConnected] / [onConnectError] 回调或
///   [state] / [isConnected] 轮询感知；
/// - [on]/[off] 在本桥 [connect] 之后调用（socket 对象此时已创建）；
/// - 连接级回调 [onConnected]/[onDisconnected]/[onConnectError] 后注册覆盖先注册。
abstract interface class WbSocketIoBridge {
  /// 当前连接状态。
  WbSocketIoConnectionState get state;

  /// 是否已连接（与 JS 侧 `socket.connected` 一致）。
  bool get isConnected;

  /// 当前会话 socket id（未连接时为 null）。
  String? get socketId;

  /// 当前底层传输名（`socket.io.engine.transport.name`，如 `websocket`/`polling`；
  /// 未知为 null）。默认传输下连接建立后为 `polling`，自动升级后为 `websocket`。
  String? get engineTransportName;

  /// `socket.volatile` 是否可用（存在且可读）。
  bool get supportsVolatile;

  /// 发起连接（非阻塞；重复调用沿用原生 socket.connect() 语义）。
  void connect(String url, WbSocketIoConnectOptions options);

  /// 注册事件监听（同一事件可注册多个回调）。
  void on(String event, WbSocketIoEventHandler handler);

  /// 移除事件监听：[event] 为 null 时移除本桥注册的全部监听。
  void off([String? event]);

  /// 发送事件（fire-and-forget；payload 为 null 时不附加数据参数）。
  void emit(String event, [Object? payload]);

  /// 发送事件并等待服务端 ack（返回 `ack(...)` 载荷 dartify 后的值）。
  Future<Object?> emitWithAck(String event, [Object? payload]);

  /// volatile 发送（socket.io volatile 语义：底层传输不可写时直接丢弃）。
  void volatileEmit(String event, [Object? payload]);

  /// 断开连接（幂等）。
  void disconnect();

  /// 连接成功回调（后注册覆盖先注册）。
  void onConnected(WbSocketIoConnectedCallback callback);

  /// 断开回调（后注册覆盖先注册）。
  void onDisconnected(WbSocketIoDisconnectedCallback callback);

  /// 连接错误回调（后注册覆盖先注册）。
  void onConnectError(WbSocketIoConnectErrorCallback callback);
}

/// 客户端脚本加载失败（网络错误 / 超时 / 全局 `io()` 未就绪）。
class WbSocketIoLoadException implements Exception {
  /// 创建加载异常。
  const WbSocketIoLoadException({required this.endpoint, required this.message, this.cause});

  /// 加载脚本所用的服务端 endpoint。
  final String endpoint;

  /// 失败原因。
  final String message;

  /// 底层错误（如 TimeoutException）；无则为 null。
  final Object? cause;

  @override
  String toString() => 'WbSocketIoLoadException($endpoint: $message)';
}
