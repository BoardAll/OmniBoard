/// 局域网投屏：领域模型与状态枚举。
///
/// 与 `services/realtime/src/castTypes.ts` 的协议载荷一一对应：
/// - 投屏码是 `'0000'`–`'9999'` 的**字符串**（保留前导零，禁止按 int 处理）；
/// - 房间快照只包含 UI 需要的信息（不含 receiverToken / senderToken / socketId）；
/// - 失败以 [WbCastFailure] 抛出（code 与服务端一致，便于 UI 精确提示）。
library;

import 'dart:async';

/// 投屏传输的媒体来源。
enum WbCastMediaSource {
  /// 摄像头（getUserMedia）。
  camera('摄像头'),

  /// 屏幕采集（getDisplayMedia；Web 端需安全上下文）。
  screen('屏幕');

  const WbCastMediaSource(this.label);

  /// 中文显示名。
  final String label;
}

/// 投屏会话角色（同一连接只承担一种）。
enum WbCastRole {
  /// 接收端（建房、显示投屏码、播放多路视频）。
  receiver,

  /// 发送端（输入四位码、采集并推流）。
  sender,
}

/// 会话状态（驱动投屏码悬浮卡与设置面板）。
enum WbCastSessionStatus {
  /// 未开启。
  idle('未开启'),

  /// 连接信令 / 建房中（此时**不得**显示有效投屏码）。
  connecting('连接中'),

  /// 已建房，等待发送端（接收端）。
  waiting('等待连接'),

  /// 发送端已提交申请，等待接收端确认。
  pendingApproval('等待确认'),

  /// 会话已建立。
  active('投屏中'),

  /// 出错（保留错误文案，可重试）。
  error('投屏异常');

  const WbCastSessionStatus(this.label);

  /// 中文显示名。
  final String label;
}

/// 单路发送端连接状态（UI 列表 / 浮层角标）。
enum WbCastLinkState {
  /// 等待接收端确认。
  pending('待确认'),

  /// 已确认，WebRTC 协商中。
  connecting('连接中'),

  /// 媒体通道已连通。
  connected('已连接'),

  /// 连接失败（可被接收端断开后重试）。
  failed('连接失败'),

  /// 已断开（即将从列表移除）。
  closed('已断开');

  const WbCastLinkState(this.label);

  /// 中文显示名。
  final String label;
}

/// 服务端投屏房间快照（`cast:room` / ack.room）。
class WbCastRoomSnapshot {
  /// 创建快照。
  const WbCastRoomSnapshot({
    required this.code,
    required this.maxSenders,
    required this.autoAccept,
    required this.expiresAt,
    required this.senders,
  });

  /// 四位投屏码（字符串，保留前导零）。
  final String code;

  /// 最大并发路数（1–4）。
  final int maxSenders;

  /// 是否自动接受新连接。
  final bool autoAccept;

  /// 房间过期时间（本地时钟估算，仅展示用）。
  final DateTime? expiresAt;

  /// 已加入的发送端（含 pending / accepted）。
  final List<WbCastSenderSnapshot> senders;

  /// 已接受的连接数（UI 的 `n/m` 分子）。
  int get acceptedCount =>
      senders.where((WbCastSenderSnapshot item) => item.accepted).length;

  /// 从服务端 JSON 解析。
  factory WbCastRoomSnapshot.fromJson(Map<String, dynamic> json) {
    final Object? rawSenders = json['senders'];
    final int? expires = _readInt(json['expiresAt']);
    return WbCastRoomSnapshot(
      code: _readString(json['code']) ?? '',
      maxSenders: _readInt(json['maxSenders']) ?? 4,
      autoAccept: json['autoAccept'] == true,
      expiresAt: expires == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expires),
      senders: rawSenders is List
          ? rawSenders
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> item) => WbCastSenderSnapshot.fromJson(
                    item.map((Object? key, Object? value) =>
                        MapEntry<String, dynamic>('$key', value)),
                  ))
              .toList(growable: false)
          : const <WbCastSenderSnapshot>[],
    );
  }
}

/// 单路发送端快照。
class WbCastSenderSnapshot {
  /// 创建快照。
  const WbCastSenderSnapshot({
    required this.senderId,
    required this.userId,
    required this.deviceName,
    required this.state,
    required this.reconnecting,
  });

  /// 服务端分配的发送端标识（SDP/ICE 关联键）。
  final String senderId;

  /// 用户 id（展示 / 审计用）。
  final String userId;

  /// 设备名称。
  final String deviceName;

  /// `pending` / `accepted`。
  final String state;

  /// 宽限期内重连（UI 可显示「重连中」）。
  final bool reconnecting;

  /// 是否已接受。
  bool get accepted => state == 'accepted';

  /// 从服务端 JSON 解析。
  factory WbCastSenderSnapshot.fromJson(Map<String, dynamic> json) {
    return WbCastSenderSnapshot(
      senderId: _readString(json['senderId']) ?? '',
      userId: _readString(json['userId']) ?? '',
      deviceName: _readString(json['deviceName']) ?? '未知设备',
      state: _readString(json['state']) ?? 'pending',
      reconnecting: json['reconnecting'] == true,
    );
  }
}

/// 建房结果（receiverToken 只在当前会话内存中保存，不落盘）。
class WbCastCreateResult {
  /// 创建结果。
  const WbCastCreateResult({
    required this.room,
    required this.receiverToken,
  });

  /// 房间快照。
  final WbCastRoomSnapshot room;

  /// 断线恢复凭证（128-bit hex）。
  final String receiverToken;
}

/// 加入结果。
class WbCastJoinResult {
  /// 创建结果。
  const WbCastJoinResult({
    required this.code,
    required this.senderId,
    required this.senderToken,
    required this.accepted,
    required this.maxSenders,
  });

  /// 四位投屏码。
  final String code;

  /// 服务端分配的发送端标识。
  final String senderId;

  /// 断线恢复凭证。
  final String senderToken;

  /// 是否自动接受（false 时等待接收端确认）。
  final bool accepted;

  /// 房间最大路数。
  final int maxSenders;
}

/// 恢复结果（接收端 / 发送端共用）。
class WbCastResumeResult {
  /// 创建结果。
  const WbCastResumeResult({
    required this.role,
    this.room,
    this.senderId,
    this.senderState,
  });

  /// 恢复出的角色。
  final WbCastRole role;

  /// 接收端恢复时的房间快照。
  final WbCastRoomSnapshot? room;

  /// 发送端恢复时的 senderId。
  final String? senderId;

  /// 发送端恢复时的席位状态（`accepted` / `pending`）。
  final String? senderState;
}

/// 投屏失败（code 与服务端错误码一致）。
class WbCastFailure implements Exception {
  /// 创建失败。
  const WbCastFailure(this.code, this.message);

  /// 服务端错误码（如 `NotFound` / `RoomFull` / `Forbidden`）。
  final String code;

  /// 可直接展示的中文说明。
  final String message;

  @override
  String toString() => 'WbCastFailure($code): $message';
}

/// 服务端下发的候选（`RTCIceCandidate` 的 JSON 形态；null 表示候选结束）。
typedef WbCastIceCandidate = Map<String, dynamic>;

/// 时间戳解析（毫秒 / 秒 / ISO 字符串均容忍）。
int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _readString(Object? value) => value is String ? value : null;

/// 四位码工具（字符串形态，保留前导零）。
abstract final class WbCastCodes {
  /// 合法四位码。
  static final RegExp pattern = RegExp(r'^\d{4}$');

  /// 归一化（去空白）；非法返回 null。
  static String? normalize(String? raw) {
    final String value = (raw ?? '').trim();
    return pattern.hasMatch(value) ? value : null;
  }

  /// 宽松格式化输入（仅保留数字并截断到 4 位）。
  static String sanitizeInput(String raw) {
    final String digits = raw.replaceAll(RegExp(r'\D'), '');
    return digits.length <= 4 ? digits : digits.substring(0, 4);
  }

  /// 复制 / 展示时保持 `0000` 形态。
  static String display(String? code) =>
      code == null || code.isEmpty ? '----' : code;

  /// 广播流适配（把回调转成可 await 的首个匹配值）。
  static Future<T> firstWhere<T>(Stream<T> stream, bool Function(T) test,
      {Duration timeout = const Duration(seconds: 8)}) {
    return stream.firstWhere(test).timeout(timeout);
  }
}
