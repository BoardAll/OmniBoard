/// 同步服务（骨架）：连接状态机 + 手动同步入口。
library;

import 'package:flutter/foundation.dart';

/// 同步连接状态。
enum WbSyncStatus {
  /// 离线（未配置 / 未连接）。
  offline('离线'),

  /// 连接中。
  connecting('连接中'),

  /// 在线（已连接协作服务）。
  online('已连接'),

  /// 同步中（上传/下行增量）。
  syncing('同步中'),

  /// 出错。
  error('同步错误');

  const WbSyncStatus(this.label);

  /// 中文显示名。
  final String label;
}

/// 同步服务。
///
/// 骨架实现仅维护状态机与配置；真实链路（WebSocket 增量 / CRDT 合并，
/// 见《CRDT 与同步》域设计）在 Wave 3 接入 —— [connect] 当前只做内存
/// 状态迁移，不代表真实网络已建立。
class WbSyncService extends ChangeNotifier {
  WbSyncService({this.serverUrl = ''});

  /// 协作服务端地址（空串表示未配置）。
  String serverUrl;

  WbSyncStatus _status = WbSyncStatus.offline;
  DateTime? _lastSyncedAt;

  /// 当前状态。
  WbSyncStatus get status => _status;

  /// 是否在线 / 同步中。
  bool get isOnline =>
      _status == WbSyncStatus.online || _status == WbSyncStatus.syncing;

  /// 最近同步完成时间（从未同步返回 null）。
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// 连接协作服务（骨架：仅内存状态迁移）。
  Future<void> connect([String? url]) async {
    if (url != null && url.isNotEmpty) {
      serverUrl = url;
    }
    _set(WbSyncStatus.connecting);
    // TODO(Wave3): 建立 WebSocket 连接并握手（CRDT 增量协议）。
    _set(WbSyncStatus.online);
  }

  /// 断开连接（骨架：仅内存状态迁移）。
  Future<void> disconnect() async {
    // TODO(Wave3): 关闭 WebSocket 并刷新未发送增量。
    _set(WbSyncStatus.offline);
  }

  /// 立即同步（骨架：仅记录时间戳）。
  Future<void> syncNow() async {
    if (!isOnline) {
      return;
    }
    _set(WbSyncStatus.syncing);
    // TODO(Wave3): 上行本地增量 / 下行远端增量并合并。
    _lastSyncedAt = DateTime.now();
    _set(WbSyncStatus.online);
  }

  /// 标记同步失败。
  void reportError() => _set(WbSyncStatus.error);

  void _set(WbSyncStatus status) {
    if (_status == status) {
      return;
    }
    _status = status;
    notifyListeners();
  }
}
