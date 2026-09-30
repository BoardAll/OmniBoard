/// T1.8 W1 协作层浏览器真连冒烟（对 :8790 实测）。
///
/// 仅浏览器运行（VM 下自动跳过）：
/// ```
/// flutter test --no-pub --platform chrome test\realtime_web_smoke_test.dart
/// ```
/// 前置：services/realtime 已启动（`node dist/server.js`，默认 :8790）。
/// 可覆盖服务地址：--dart-define=WB_REALTIME_ENDPOINT=http://127.0.0.1:8790
///
/// 覆盖断言（W1 层：成员 / 状态 / presence 元数据；不发画布 op）：
/// - 连接 + `board:session` 单播（匿名 dev 回落 `anon-*`）；
/// - `joinBoard` → `board:joined` 快照含自身（role/mode）；
/// - 双连接互见：A / B 均收到对方加入增量（`board:participants`）；
/// - B `leave()` → A 收到 left 增量。
@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web/services/realtime_service.dart';

/// realtime 服务地址（测试轮次可用 --dart-define 覆盖）。
const String kEndpoint = String.fromEnvironment(
  'WB_REALTIME_ENDPOINT',
  defaultValue: 'http://127.0.0.1:8790',
);

void main() {
  test(
    '连接 + board:session：匿名 dev 回落 userId（anon-*）',
    () async {
      final WbRealtimeService service = WbRealtimeService();
      addTearDown(service.dispose);

      await service.connect(kEndpoint);
      await _waitUntil(
        () => service.status == WbRealtimeStatus.connected,
        timeout: const Duration(seconds: 15),
        reason: '等待与 realtime 服务建立连接',
      );
      await _waitUntil(
        () => service.userId != null,
        timeout: const Duration(seconds: 10),
        reason: '等待 board:session 单播',
      );

      expect(service.userId, startsWith('anon-'));
      expect(service.authMode, 'anonymous');
      debugPrint('[T1.8] connected userId=${service.userId} authMode=${service.authMode}');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'W1 链路：join 快照含自身 → 双连接互见（joined 增量）→ leave（left 增量）',
    () async {
      final WbRealtimeService a = WbRealtimeService();
      final WbRealtimeService b = WbRealtimeService();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final String boardId = 't18-${DateTime.now().millisecondsSinceEpoch}';

      // A：连接 → 加入房间 → 快照含自身。
      await a.connect(kEndpoint);
      await _waitUntil(
        () => a.status == WbRealtimeStatus.connected,
        timeout: const Duration(seconds: 15),
        reason: 'A 等待连接',
      );
      await a.joinBoard(boardId);
      await _waitUntil(
        () => a.participants.length == 1,
        timeout: const Duration(seconds: 15),
        reason: 'A 等待 board:joined 快照',
      );
      expect(a.participants.single.userId, a.userId);
      expect(a.role, 'Participant');
      expect(a.boardId, boardId);

      // B：连接 → 加入同一房间 → 双方互见（joined 增量）。
      await b.connect(kEndpoint);
      await _waitUntil(
        () => b.status == WbRealtimeStatus.connected,
        timeout: const Duration(seconds: 15),
        reason: 'B 等待连接',
      );
      await b.joinBoard(boardId);
      await _waitUntil(
        () => a.participants.length == 2,
        timeout: const Duration(seconds: 15),
        reason: 'A 等待 B 加入增量',
      );
      await _waitUntil(
        () => b.participants.length == 2,
        timeout: const Duration(seconds: 15),
        reason: 'B 等待快照含双方',
      );
      expect(
        a.participants.map((WbCollabParticipant p) => p.userId).toSet(),
        <String>{a.userId!, b.userId!},
      );

      // B 离开 → A 收到 left 增量。
      await b.leave();
      await _waitUntil(
        () => a.participants.length == 1,
        timeout: const Duration(seconds: 15),
        reason: 'A 等待 B 离开增量',
      );
      expect(a.participants.single.userId, a.userId);

      await a.leave();
      debugPrint('[T1.8] W1 flow ok; boardId=$boardId users={${a.userId}, ${b.userId}}');
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

/// 轮询等待条件成立（50ms 间隔；超时抛 [TimeoutException]）。
Future<void> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
  required String reason,
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > timeout) {
      throw TimeoutException('$reason（超时 ${timeout.inSeconds}s）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
