/// Socket.IO 桥 VM 桩测试（T0.2 POC）：非 Web 平台安全降级契约。
///
/// 纯 Dart（VM）路径不加载 JS：`loadSocketIoClient` 以
/// [WbSocketIoLoadException] 失败；桩桥以 `UnsupportedPlatform` 错误回调
/// 收敛连接，其余操作安全降级——保证 `realtime_service` 的传输抽象在
/// 测试环境可注入、不抛意外异常。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web/services/socketio_js.dart';

void main() {
  test('loadSocketIoClient 在 VM 下以 WbSocketIoLoadException 失败', () async {
    await expectLater(
      loadSocketIoClient('http://127.0.0.1:8790'),
      throwsA(
        isA<WbSocketIoLoadException>()
            .having((WbSocketIoLoadException e) => e.endpoint, 'endpoint', 'http://127.0.0.1:8790')
            .having((WbSocketIoLoadException e) => e.message, 'message', contains('仅支持 Web')),
      ),
    );
  });

  test('桩桥 connect：UnsupportedPlatform 错误回调 + 状态收敛', () async {
    final bridge = createWbSocketIoBridge();
    expect(bridge.state, WbSocketIoConnectionState.idle);
    expect(bridge.supportsVolatile, isFalse);

    final errorFuture = Completer<WbSocketIoConnectError>();
    bridge.onConnectError((WbSocketIoConnectError error) {
      if (!errorFuture.isCompleted) {
        errorFuture.complete(error);
      }
    });
    bridge.connect('http://127.0.0.1:8790/board', const WbSocketIoConnectOptions());

    final error = await errorFuture.future;
    expect(error.code, 'UnsupportedPlatform');
    expect(error.message, contains('非 Web 平台'));
    expect(bridge.state, WbSocketIoConnectionState.connectError);
    expect(bridge.isConnected, isFalse);
    expect(bridge.socketId, isNull);
    expect(bridge.engineTransportName, isNull);
  });

  test('桩桥 emitWithAck 以 UnsupportedError 失败；其余操作 no-op', () async {
    final bridge = createWbSocketIoBridge();
    await expectLater(bridge.emitWithAck('board:ping'), throwsA(isA<UnsupportedError>()));
    // 以下调用不应抛异常（安全降级）。
    bridge.on('board:session', (Object? _) {});
    bridge.off();
    bridge.emit('board:ping');
    bridge.volatileEmit('board:ping');
    bridge.onConnected((String socketId, String? transport) {});
    bridge.onDisconnected((String reason) {});
    bridge.disconnect();
    expect(bridge.state, WbSocketIoConnectionState.idle);
  });
}
