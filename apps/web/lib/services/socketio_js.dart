/// Socket.IO 传输桥统一入口（Web 应用侧；T0.2 POC）。
///
/// - Web：dart:js_interop 动态加载 `{endpoint}/socket.io/socket.io.min.js`
///   并桥接官方 JS 客户端（socketio_js_web.dart）；
/// - VM/原生：桩实现（socketio_js_stub.dart），不加载 JS、测试安全。
///
/// 典型用法（浏览器路径）：
/// ```dart
/// await loadSocketIoClient(endpoint);
/// final bridge = createWbSocketIoBridge();
/// bridge.onConnected((id, transport) => debugPrint('connected $id ($transport)'));
/// bridge.on('board:session', (payload) => debugPrint('session: $payload'));
/// bridge.connect('$endpoint/board', const WbSocketIoConnectOptions(auth: {'boardId': boardId}));
/// final ack = await bridge.emitWithAck('board:join', {'boardId': boardId});
/// ```
library;

import 'socketio_js_stub.dart' if (dart.library.js_interop) 'socketio_js_web.dart' as impl;
import 'socketio_js_types.dart';

export 'socketio_js_types.dart';

/// 动态加载官方 socket.io JS 客户端（幂等；实现见平台文件）。
///
/// [endpoint] 为 realtime 服务地址（如 `http://127.0.0.1:8790`）。
/// 加载失败抛出 [WbSocketIoLoadException]；失败后再次调用会重试。
Future<void> loadSocketIoClient(String endpoint, {Duration timeout = const Duration(seconds: 10)}) =>
    impl.loadSocketIoClient(endpoint, timeout: timeout);

/// 创建 Socket.IO 桥实例（实现见平台文件；需先 [loadSocketIoClient] 成功）。
WbSocketIoBridge createWbSocketIoBridge() => impl.createWbSocketIoBridge();
