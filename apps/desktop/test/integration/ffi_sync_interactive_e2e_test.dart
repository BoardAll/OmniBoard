/// M3 T3.2 双进程「真引擎 interactive 闭环」集成测试（env-gated：
/// `WB_REALTIME_E2E=1`）。
///
/// 背景：M3 interactive 事件族的既有证据中，e2e 探针
/// （tests/e2e/support/wb_collab_scenario_probe.mjs）为直连服务端的协议级
/// 验证（socket.io-client 客户端），引擎侧 interactive 为 ctest #205–#209
/// 的 fake transport 级验证——独缺「两个真实引擎进程经真实 realtime 服务端
/// 完成一次 interactive 往返」的全自动断言。本文件以两个 flutter test
/// 进程（角色由 WB_DUAL_ROLE 区分，各自加载真实 wb_core.dll）补齐该缺口：
/// - 接收端（receiver）：真实引擎 join → 观察对端 `interactive:raiseHand`
///   经 `board:participants` 广播折叠出的 `handRaised`，以及对端
///   `interactive:follow` 单播折叠出的 `followers`；
/// - 发送端（sender）：真实引擎 `raiseHand()` → 等接收端确认 →
///   `follow(receiverUserId)` → 等接收端确认。
///
/// 环境变量（协调脚本 support/run_dual_process_interactive.mjs 注入）：
/// - `WB_DUAL_ROLE`：receiver / sender；
/// - `WB_DUAL_BOARD`：房间 id；
/// - `WB_DUAL_FLAG`：接收端就绪信号路径（内容 = receiver selfUserId）；
///   派生信号：`<flag>.sender`（sender selfUserId）/ `<flag>.hand`
///   （接收端已观察到对端举手）/ `<flag>.follow`（接收端已观察到对端跟随）
///   / `<flag>.done`（发送端完成）；
/// - `WB_DUAL_ENDPOINT`：realtime 端点（默认 http://127.0.0.1:18793）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';

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
  final String boardId = _env('WB_DUAL_BOARD', 'wb-dual-interactive');
  final String flagPath = _env('WB_DUAL_FLAG');
  final String endpoint = _env('WB_DUAL_ENDPOINT', 'http://127.0.0.1:18793');
  final String senderFlagPath = '$flagPath.sender';
  final String handFlagPath = '$flagPath.hand';
  final String followFlagPath = '$flagPath.follow';
  final String doneFlagPath = '$flagPath.done';

  /// 角色门槛：非目标角色 / 未开 gate 时优雅跳过（协调脚本另行注入）。
  String? gate(String want) {
    final String? coreSkip = ffiIntegrationSkipReason();
    if (coreSkip != null) {
      return coreSkip;
    }
    if (_env('WB_REALTIME_E2E') != '1') {
      return '未设置 WB_REALTIME_E2E=1：跳过 interactive 双进程集成测试';
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
    'dual-process interactive receiver: observe remote raise-hand and follow',
    () async {
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

      // join 被服务端确认（board:joined 快照回流：participants ≥ 1 且
      // board:session 的 selfUserId 已就位）。
      final bool joined = await _waitUntil(
        () => collab.participants >= 1 && collab.selfUserId.isNotEmpty,
        timeout: const Duration(seconds: 30),
      );
      expect(
        joined,
        isTrue,
        reason: 'join 未确认（participants=${collab.participants}'
            ' selfUserId=${collab.selfUserId} lastError=${collab.lastError}）',
      );
      File(flagPath).writeAsStringSync(collab.selfUserId);

      // 等发送端自报身份（join 后写入自身 selfUserId）。
      final bool senderReady = await _waitUntil(
        () => File(senderFlagPath).existsSync(),
        timeout: const Duration(seconds: 240),
      );
      expect(senderReady, isTrue, reason: '240s 内未见发送端身份信号：$senderFlagPath');
      final String senderId = File(senderFlagPath).readAsStringSync().trim();
      expect(senderId.isNotEmpty, isTrue, reason: '发送端身份信号为空');
      expect(senderId, isNot(collab.selfUserId), reason: '发送端身份与自身相同');

      // interactive 闭环①：对端 raiseHand 经服务端 board:participants
      // 广播 → 引擎 roster 折叠 → 本端 participantList 出现 handRaised。
      final bool handSeen = await _waitUntil(
        () => collab.participantList
            .any((WbCollabParticipant p) => p.id == senderId && p.handRaised),
        timeout: const Duration(seconds: 120),
      );
      expect(
        handSeen,
        isTrue,
        reason: '120s 内未观察到对端 handRaised（roster='
            '${collab.participantList.map((WbCollabParticipant p) => '${p.id}:${p.handRaised}').join(',')}'
            ' lastError=${collab.lastError}）',
      );
      File(handFlagPath).writeAsStringSync('hand');

      // interactive 闭环②：对端 follow 单播 → 引擎 incomingFollows 折叠
      // → 本端 followers 包含对端。
      final bool followSeen = await _waitUntil(
        () => collab.followers.contains(senderId),
        timeout: const Duration(seconds: 120),
      );
      expect(
        followSeen,
        isTrue,
        reason: '120s 内未观察到对端跟随（followers=${collab.followers}'
            ' lastError=${collab.lastError}）',
      );
      File(followFlagPath).writeAsStringSync('follow');

      // 等发送端收尾信号，避免 teardown 截断对端最后一步。
      final bool done = await _waitUntil(
        () => File(doneFlagPath).existsSync(),
        timeout: const Duration(seconds: 120),
      );
      expect(done, isTrue, reason: '120s 内未见发送端完成信号：$doneFlagPath');
    },
    skip: gate('receiver'),
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'dual-process interactive sender: raise hand and follow remote',
    () async {
      // 等接收端 join 确认信号（内容 = receiver selfUserId）。
      final bool ready = await _waitUntil(
        () => File(flagPath).existsSync(),
        timeout: const Duration(seconds: 240),
      );
      expect(ready, isTrue, reason: '240s 内未见接收端就绪信号：$flagPath');
      final String receiverId = File(flagPath).readAsStringSync().trim();
      expect(receiverId.isNotEmpty, isTrue, reason: '接收端身份信号为空');

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

      // 双端同房（roster 含接收端 + 自身）。
      final bool joined = await _waitUntil(
        () => collab.selfUserId.isNotEmpty && collab.participants >= 2,
        timeout: const Duration(seconds: 30),
      );
      expect(
        joined,
        isTrue,
        reason: 'join/roster 未就位（participants=${collab.participants}'
            ' selfUserId=${collab.selfUserId} lastError=${collab.lastError}）',
      );
      File(senderFlagPath).writeAsStringSync(collab.selfUserId);

      // interactive 动作①：真实引擎发起举手（wire: interactive:raiseHand）。
      final WbSyncInteractiveResult raise = collab.raiseHand();
      expect(
        raise.requested,
        isTrue,
        reason: '引擎未受理 raiseHand（lastError=${collab.lastError}）',
      );
      final bool handOk = await _waitUntil(
        () => File(handFlagPath).existsSync(),
        timeout: const Duration(seconds: 120),
      );
      expect(handOk, isTrue, reason: '120s 内接收端未确认观察到举手：$handFlagPath');

      // interactive 动作②：真实引擎发起跟随（wire: interactive:follow 单播）。
      final WbSyncInteractiveResult follow = collab.follow(receiverId);
      expect(
        follow.requested,
        isTrue,
        reason: '引擎未受理 follow（lastError=${collab.lastError}）',
      );
      final bool followOk = await _waitUntil(
        () => File(followFlagPath).existsSync(),
        timeout: const Duration(seconds: 120),
      );
      expect(followOk, isTrue, reason: '120s 内接收端未确认观察到跟随：$followFlagPath');

      File(doneFlagPath).writeAsStringSync('done');
    },
    skip: gate('sender'),
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
