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
///   （syncedCount ≥ 1、离线队列为空）→ 发一条 ink 预览帧（pageId 为
///   跨端无关命名空间，M3 D3-0 预览流）→ 等接收端确认信号。端到端
///   到达性由接收端断言（插入 op + ink 预览），两者都绿则 A 发 B 收
///   经真实服务端全程闭环。
/// M3 默认无权限（2026-10）：后加入的发送端默认只读——接收端（首入
/// 自举 Host）观测对端入房后授权其写入（interactive:grantControl），
/// 发送端等 grantedWrite 折叠后再落定提交。
///
/// 环境变量（协调脚本注入）：
/// - `WB_DUAL_ROLE`：receiver / sender；
/// - `WB_DUAL_BOARD` / `WB_DUAL_ELEMENT`：房间与元素 id；
/// - `WB_DUAL_FLAG`：接收端就绪信号文件路径；
/// - `WB_DUAL_PREVIEW_FLAG`：接收端 ink 预览到达信号路径（M3 D3-0：
///   发送端落定后再发一条命名空间无关的 ink 预览帧，接收端收到后写）；
/// - `WB_DUAL_ENDPOINT`：realtime 端点（默认 http://127.0.0.1:18792）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';
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
  final String previewFlagPath = _env('WB_DUAL_PREVIEW_FLAG');
  final String endpoint = _env('WB_DUAL_ENDPOINT', 'http://127.0.0.1:18792');
  // M3 D3-0 预览流闭环：strokeId 由两端共享的房间号派生（无需额外 env）。
  final String previewStrokeId = '$boardId-preview-ink';

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
    if (previewFlagPath.isEmpty) {
      return 'WB_DUAL_PREVIEW_FLAG 未设置：跳过';
    }
    return null;
  }

  test(
    'dual-process receiver: join confirmed then receive remote op',
    () async {
      final WbCollabService collab = _buildService();
      final List<WbCanvasElement> received = <WbCanvasElement>[];
      collab.onRemoteElement =
          (WbCanvasElement element, {String? pageId}) => received.add(element);
      final List<Map<String, dynamic>> receivedPreviews =
          <Map<String, dynamic>>[];
      collab.onRemotePreviews = (List<Map<String, dynamic>> batch) =>
          receivedPreviews.addAll(batch);
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

      // M3 默认无权限（2026-10）：等对端（发送端）入房后由本端（自举 Host）
      // 授权写入；发送端等 grantedWrite 折叠后再落定提交。
      final bool peerJoined = await _waitUntil(
        () => collab.selfUserId.isNotEmpty
            && collab.participantList
                .any((WbCollabParticipant p) => p.id != collab.selfUserId),
        timeout: const Duration(seconds: 240),
      );
      expect(
        peerJoined,
        isTrue,
        reason: '240s 内未见对端入房（participants=${collab.participants}'
            ' lastError=${collab.lastError}）',
      );
      final WbCollabParticipant peer = collab.participantList
          .firstWhere((WbCollabParticipant p) => p.id != collab.selfUserId);
      expect(
        collab.grantControl(peer.id).requested,
        isTrue,
        reason: '授权发送端失败（lastError=${collab.lastError}）',
      );

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

      // M3 D3-0 预览流闭环：等发送端 ink 预览帧经真实服务端回流。
      // 服务端 presence:preview 转发排除发送者并原样保留载荷（pageId
      // 为对端命名空间——「本地板 id 派生 vs 房间号入房」的真实跨端
      // 差异）；UI 层页匹配（previewPageMatches）由单测覆盖，此处只
      // 验证引擎 / 服务端链路。
      final bool previewArrived = await _waitUntil(
        () => receivedPreviews.any(
          (Map<String, dynamic> p) =>
              p['kind'] == 'ink' && p['strokeId'] == previewStrokeId,
        ),
        timeout: const Duration(seconds: 90),
      );
      expect(
        previewArrived,
        isTrue,
        reason: '90s 内未收到对端 ink 预览（已收 ${receivedPreviews.length} 条'
            ' lastError=${collab.lastError}）',
      );
      final Map<String, dynamic> inkPreview = receivedPreviews.firstWhere(
        (Map<String, dynamic> p) =>
            p['kind'] == 'ink' && p['strokeId'] == previewStrokeId,
      );
      expect(inkPreview['pageId'], 'remote-ns-page-1');
      File(previewFlagPath).writeAsStringSync('previewed');
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

      // M3 默认无权限（2026-10）：等接收端（自举 Host）授权后落定提交
      // （interactive:grantControl → roleChanged 单播折叠为 grantedWrite）。
      final bool writeGranted = await _waitUntil(
        () => collab.grantedWrite,
        timeout: const Duration(seconds: 60),
      );
      expect(
        writeGranted,
        isTrue,
        reason: '60s 内未获得写授权（grantedWrite=true；'
            'lastError=${collab.lastError}）',
      );

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

      // M3 D3-0 预览流闭环：落定 op 被服务端 ack 后，发一条 ink 预览帧。
      // pageId 故意使用与本机无关的命名空间——模拟「发送端本地板 id
      // 派生 vs 用户输入房间号入房」的真实跨端差异；引擎 depth-1 迟滞
      // 槽下此为唯一预览帧，不会被后续更新覆盖。等接收端确认信号再退出，
      // 避免 teardown 截断预览轮询回归窗口。
      final WbSyncPreviewResult preview = collab.sendPreview(
        <String, dynamic>{
          'kind': 'ink',
          'strokeId': previewStrokeId,
          'pageId': 'remote-ns-page-1',
          'points': <List<double>>[
            <double>[12, 34],
            <double>[56, 78],
          ],
          'style': <String, dynamic>{'color': 0xFF112233, 'width': 3},
          'highlight': false,
        },
      );
      expect(
        preview.dropped,
        isFalse,
        reason: '预览帧未被本地引擎发出（sent=${preview.sent}'
            ' queued=${preview.queued}）',
      );
      final bool previewSeen = await _waitUntil(
        () => File(previewFlagPath).existsSync(),
        timeout: const Duration(seconds: 120),
      );
      expect(
        previewSeen,
        isTrue,
        reason: '120s 内未见接收端预览确认信号：$previewFlagPath',
      );
    },
    skip: gate('sender'),
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
