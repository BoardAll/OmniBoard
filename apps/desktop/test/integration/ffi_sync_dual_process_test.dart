/// T1.6 双进程「双开等价」集成测试（env-gated：`WB_REALTIME_E2E=1`）。
///
/// 背景：单进程内 wb_core 的 sync 域是进程级单例
/// （core/src/sync/sync.cpp：one whiteboard session per process），
/// 「双开互见」的自动化等价物是两个进程各持真实引擎：
/// 协调脚本 `support/run_dual_process_ffi_test.mjs` 启动两个
/// `flutter test` 进程（本文件，角色由 WB_DUAL_ROLE 区分）——
/// - 接收端：真实引擎 join → 等 `participants >= 1`（服务端
///   `board:joined` 快照回流即 join 被确认）→ 写就绪信号 → 等待对端
///   op 经服务端广播 + 50ms 轮询回流并由画布入口回调接收；
/// - 发送端：等就绪信号 → 真实引擎落定提交（handleCanvasCommit，
///   crdt.applyLocal → sync.sendOperation）→ 等待本地乐观接受确认
///   （syncedCount ≥ 1、离线队列为空）。端到端到达性由接收端断言，
///   两者都绿则 A 发 B 收经真实服务端全程闭环。
///
/// 环境变量（协调脚本注入）：
/// - `WB_DUAL_ROLE`：receiver / sender；
/// - `WB_DUAL_BOARD` / `WB_DUAL_ELEMENT`：房间与元素 id；
/// - `WB_DUAL_FLAG`：接收端就绪信号文件路径；
/// - `WB_DUAL_ENDPOINT`：realtime 端点（默认 http://127.0.0.1:18792）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

import 'support/ffi_support.dart';

String _env(String key, [String fallback = '']) =>
    Platform.environment[key] ?? fallback;

/// 轮询等待 [predicate] 为真。
Future<bool> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
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

/// 组装真实引擎协同服务（两个角色共用）。
WbCollabService _buildService() {
  final String dllPath = resolveWbCoreDll()!;
  final WbFfiService ffi =
      WbFfiService(candidatePaths: <String>[dllPath])..initialize();
  expect(ffi.isAvailable, isTrue, reason: 'wb_core.dll 加载失败：${ffi.error}');
  return WbCollabService(
    engine: WbFfiCollabEngine(ffi),
    connectTimeout: const Duration(seconds: 15),
  );
}

void main() {
  final String role = _env('WB_DUAL_ROLE');
  final String boardId = _env('WB_DUAL_BOARD', 'wb-dual-board');
  final String elementId = _env('WB_DUAL_ELEMENT', 'wb-dual-element');
  final String flagPath = _env('WB_DUAL_FLAG');
  final String endpoint = _env('WB_DUAL_ENDPOINT', 'http://127.0.0.1:18792');

  /// 角色门槛：非目标角色 / 未开 gate 时优雅跳过（协调脚本另行注入）。
  String? gate(String want) {
    final String? coreSkip = ffiIntegrationSkipReason();
    if (coreSkip != null) {
      return coreSkip;
    }
    if (_env('WB_REALTIME_E2E') != '1') {
      return '未设置 WB_REALTIME_E2E=1：跳过双进程真连集成测试';
    }
    if (role != want) {
      return '角色不符（WB_DUAL_ROLE=$role）：跳过';
    }
    if (flagPath.isEmpty) {
      return 'WB_DUAL_FLAG 未设置：跳过';
    }
    return null;
  }

  test(
    'dual-process receiver: join confirmed then receive remote op',
    () async {
      final WbCollabService collab = _buildService();
      final List<WbCanvasElement> received = <WbCanvasElement>[];
      collab.onRemoteElement = received.add;
      addTearDown(() async {
        await collab.stop();
        collab.dispose();
      });

      final bool started =
          await collab.start(boardId: boardId, endpoint: endpoint);
      expect(
        started,
        isTrue,
        reason: 'start 失败：lastError=${collab.lastError}'
            ' transport=${collab.lastStatus.transportState}',
      );
      expect(collab.status, WbSyncStatus.online);

      // join 被服务端确认（board:joined 快照回流 → participants ≥ 1）。
      final bool joined = await _waitUntil(
        () => collab.participants >= 1,
        timeout: const Duration(seconds: 30),
      );
      expect(
        joined,
        isTrue,
        reason: '参与者数未更新（participants=${collab.participants}'
            ' lastError=${collab.lastError}）',
      );
      File(flagPath).writeAsStringSync('ready');

      // 等待对端 op（服务端广播排除发送者 → 本进程经 events 轮询回流）。
      final bool arrived = await _waitUntil(
        () => received.any((WbCanvasElement e) => e.id == elementId),
        timeout: const Duration(seconds: 240),
      );
      expect(
        arrived,
        isTrue,
        reason: '240s 内未收到对端 op（elementId=$elementId'
            ' 已收=${received.map((WbCanvasElement e) => e.id).toList()}'
            ' lastError=${collab.lastError}）',
      );
      final WbCanvasElement element =
          received.firstWhere((WbCanvasElement e) => e.id == elementId);
      expect(element.type, WbElementKind.note);
      expect(element.text, 'T1.6 dual');
    },
    skip: gate('receiver'),
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'dual-process sender: canvas commit then accepted by local transport',
    () async {
      // 等待接收端 join 确认信号。
      final bool ready = await _waitUntil(
        () => File(flagPath).existsSync(),
        timeout: const Duration(seconds: 240),
      );
      expect(ready, isTrue, reason: '240s 内未见接收端就绪信号：$flagPath');
      // 广播路由余量（接收端 join 已确认，仅作稳妥缓冲）。
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final WbCollabService collab = _buildService();
      addTearDown(() async {
        await collab.stop();
        collab.dispose();
      });
      final bool started =
          await collab.start(boardId: boardId, endpoint: endpoint);
      expect(
        started,
        isTrue,
        reason: 'start 失败：lastError=${collab.lastError}'
            ' transport=${collab.lastStatus.transportState}',
      );
      expect(collab.status, WbSyncStatus.online);

      collab.handleCanvasCommit(
        WbCanvasCommitBatch(
          upserts: <WbCanvasElement>[
            WbCanvasElement(
              id: elementId,
              type: WbElementKind.note,
              x: 12,
              y: 34,
              width: 160,
              height: 96,
              text: 'T1.6 dual',
            ),
          ],
        ),
      );

      // 服务端接受确认：ack RTT 已采样（latencyMs > 0 表示我们的 op 批次
      // 已被服务端 ack；服务端对 board:ops 先广播后 ack，ack 到达时广播
      // 已入队发出，随后断开不影响房间内其他连接的推送）且离线队列为空。
      // 注意：仅本地乐观计数（syncedCount）不足以证明送达——outbound 为
      // 100ms 攒批 + ack 重发，teardown 过早会把 op 归入 failure list。
      final bool accepted = await _waitUntil(
        () => collab.pendingCount == 0 && collab.lastStatus.latencyMs > 0,
        timeout: const Duration(seconds: 30),
      );
      expect(
        accepted,
        isTrue,
        reason: '发送未被服务端确认（pending=${collab.pendingCount}'
            ' latency=${collab.lastStatus.latencyMs}'
            ' synced=${collab.lastStatus.syncedCount}'
            ' lastError=${collab.lastError}）',
      );
    },
    skip: gate('sender'),
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
