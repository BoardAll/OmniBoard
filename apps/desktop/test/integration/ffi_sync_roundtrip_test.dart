/// T1.6 真实 realtime 往返集成测试（env-gated：`WB_REALTIME_E2E=1`）。
///
/// 链路（《互动白板实时协同设计文档》§8）：
/// 本地 `services/realtime`（node dist/server.js）← C++ 引擎真实
/// socket.io 客户端（connect / join / sendOperation / events）↔ node 探针
/// 作为第二客户端（服务端广播排除发送者，故探针收 `board:ops` 验证发送
/// 方向；探针回发一条 op 验证接收方向经桌面 events drain 回流）。
///
/// 门槛：DLL 缺失（`WB_REQUIRE_CORE_DLL=1` 时直接抛错，契约同
/// ffi_support.dart）+ 未显式 `WB_REALTIME_E2E=1` / node 不可用时跳过。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

import 'support/ffi_support.dart';

/// 探针脚本相对 apps/desktop 的路径。
const String _probeScript = 'test/integration/support/wb_realtime_probe.mjs';

/// 测试专用端口（避开默认 8790 上可能存在的开发实例）。
const String _port = '18790';
const String _endpoint = 'http://127.0.0.1:$_port';

/// 从当前目录向上定位 `services/realtime`（最多 4 层）。
Directory? _resolveRealtimeDir() {
  Directory dir = Directory.current.absolute;
  final String sep = Platform.pathSeparator;
  for (int i = 0; i < 4; i++) {
    final Directory candidate = Directory('${dir.path}${sep}services${sep}realtime');
    if (candidate.existsSync()) {
      return candidate;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  return null;
}

/// node 是否可用（不可用则跳过）。
bool _nodeAvailable() {
  try {
    final ProcessResult result =
        Process.runSync('node', <String>['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 本测试的跳过原因（null = 可运行）。
String? _skipReason() {
  final String? ffiSkip = ffiIntegrationSkipReason();
  if (ffiSkip != null) {
    return ffiSkip;
  }
  if ((Platform.environment['WB_REALTIME_E2E'] ?? '') != '1') {
    return '未设置 WB_REALTIME_E2E=1：跳过真实 realtime 往返集成测试';
  }
  if (!_nodeAvailable()) {
    return 'node 不可用：跳过真实 realtime 往返集成测试';
  }
  final Directory? realtime = _resolveRealtimeDir();
  if (realtime == null) {
    return 'services/realtime 目录未找到：跳过';
  }
  final String sep = Platform.pathSeparator;
  if (!File('${realtime.path}${sep}dist${sep}server.js').existsSync()) {
    return 'services/realtime/dist/server.js 未构建：跳过（先构建 dist）';
  }
  if (!Directory('${realtime.path}${sep}node_modules${sep}socket.io-client')
      .existsSync()) {
    return 'socket.io-client 未安装：跳过';
  }
  return null;
}

/// 轮询 `/healthz` 直到就绪。
Future<bool> _waitHealthz(String endpoint, HttpClient client) async {
  for (int i = 0; i < 60; i++) {
    try {
      final HttpClientRequest request =
          await client.getUrl(Uri.parse('$endpoint/healthz'));
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      if (response.statusCode == 200) {
        return true;
      }
    } catch (_) {
      // 未就绪：继续等待。
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

/// 按行解析进程 stdout 的 JSON 消息（非 JSON 行返回空表忽略）。
Stream<Map<String, dynamic>> _jsonLines(Stream<List<int>> stdout) {
  return stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .map((String line) {
    try {
      final Object? decoded = jsonDecode(line);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  });
}

/// 轮询等待 [predicate] 为真。
Future<bool> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return predicate();
}

void main() {
  final String? skip = _skipReason();

  test(
    '真实 realtime 往返：connect/join → 发送广播 + 对端回发放射接收',
    () async {
      final String? dllPath = resolveWbCoreDll();
      final Directory realtimeDir = _resolveRealtimeDir()!;

      // 1) 本地 realtime 服务。
      final Process server = await Process.start(
        'node',
        <String>['dist/server.js'],
        workingDirectory: realtimeDir.path,
        environment: <String, String>{'PORT': _port},
      );
      addTearDown(server.kill);
      final HttpClient http = HttpClient();
      addTearDown(() => http.close(force: true));
      expect(
        await _waitHealthz(_endpoint, http),
        isTrue,
        reason: 'realtime /healthz 未就绪',
      );

      // 2) 对端探针（第二客户端；广播排除发送者）。
      final String boardId = 'e2e-sync-${DateTime.now().millisecondsSinceEpoch}';
      final Process probe = await Process.start(
        'node',
        <String>[
          File(_probeScript).absolute.path,
          realtimeDir.path,
          _endpoint,
          boardId,
          '25000',
        ],
        workingDirectory: Directory.current.absolute.path,
      );
      addTearDown(probe.kill);
      final Completer<void> probeReady = Completer<void>();
      final Completer<Map<String, dynamic>> probeResult =
          Completer<Map<String, dynamic>>();
      _jsonLines(probe.stdout).listen((Map<String, dynamic> msg) {
        if (msg['ready'] == true && !probeReady.isCompleted) {
          probeReady.complete();
        }
        if (msg.containsKey('ok') && !probeResult.isCompleted) {
          probeResult.complete(msg);
        }
      });
      await probeReady.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => fail('探针 20s 内未能加入房间'),
      );

      // 3) 桌面服务（真实 DLL + 真实 socket.io 客户端）。
      final WbFfiService ffi =
          WbFfiService(candidatePaths: <String>[dllPath!])..initialize();
      expect(ffi.isAvailable, isTrue, reason: 'wb_core.dll 加载失败：${ffi.error}');
      final WbCollabService service = WbCollabService(
        engine: WbFfiCollabEngine(ffi),
        connectTimeout: const Duration(seconds: 15),
      );
      final List<WbCanvasElement> received = <WbCanvasElement>[];
      service.onRemoteElement = received.add;
      addTearDown(() async {
        await service.stop();
        service.dispose();
      });
      final bool started =
          await service.start(boardId: boardId, endpoint: _endpoint);
      expect(
        started,
        isTrue,
        reason: 'start 失败：lastError=${service.lastError}'
            ' transport=${service.lastStatus.transportState}',
      );
      expect(service.status, WbSyncStatus.online);
      expect(service.sessionActor, isNotEmpty);

      // 4) 发送方向：本地落定提交 → 服务端广播 → 探针收到。
      final WbCanvasElement element = WbCanvasElement(
        id: 'e2e-note-${DateTime.now().microsecondsSinceEpoch}',
        type: WbElementKind.note,
        x: 12,
        y: 34,
        width: 160,
        height: 96,
        text: 'T1.6 e2e',
      );
      service.handleCanvasCommit(
        WbCanvasCommitBatch(upserts: <WbCanvasElement>[element]),
      );
      final Map<String, dynamic> result = await probeResult.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail(
          '探针 30s 内未收到 board:ops 广播'
          '（lastError=${service.lastError} pending=${service.pendingCount}）',
        ),
      );
      expect(result['ok'], isTrue, reason: '探针失败：$result');
      final List<dynamic> ops = result['ops'] as List<dynamic>? ?? <dynamic>[];
      Map<String, dynamic>? sentOp;
      for (final Object? raw in ops) {
        if (raw is Map) {
          final Map<String, dynamic> op = Map<String, dynamic>.from(raw);
          if (op['key'] == 'el:${element.id}:data') {
            sentOp = op;
            break;
          }
        }
      }
      expect(sentOp, isNotNull, reason: '广播中未见预期 op：$ops');
      expect(sentOp!['key'], 'el:${element.id}:data');
      final Map<String, dynamic> value =
          Map<String, dynamic>.from(sentOp['value'] as Map);
      expect(value['id'], element.id);
      expect(value['type'], WbElementKind.note);
      expect(sentOp['actor'], service.sessionActor);

      // 5) 接收方向：探针回发 → 桌面 events drain → 画布入口回调。
      final String echoId = result['echoId'] as String? ?? '';
      expect(echoId, isNotEmpty);
      final bool arrived = await _waitUntil(
        () => received.any((WbCanvasElement e) => e.id == echoId),
        timeout: const Duration(seconds: 20),
      );
      expect(
        arrived,
        isTrue,
        reason: '桌面未收到探针回发 op（echoId=$echoId'
            ' 已收=${received.map((WbCanvasElement e) => e.id).toList()}'
            ' lastError=${service.lastError}）',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
