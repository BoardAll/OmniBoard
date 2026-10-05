import '../engine.dart';
import '../utils/json_codec.dart';

/// CRDT 服务（M1 最小面）：文档创建 + 本地操作应用（crdt 域）。
///
/// 出口管道（docs/modules/05-core-collab.md §5.4 / 协同设计文档 §8.3）：
/// 画布操作 → [applyLocal] 生成完整规范化 op（响应 `op` 字段）→
/// `WbSyncService.sendOperation` 直发。
///
/// 合并 / 快照（applyRemote / encodeState / decodeState / encodeUpdate /
/// merge / list）暂不在 Dart 封装面内，按需另行扩展。
class WbCrdtService {
  const WbCrdtService(this.ffi);

  final WbEngineCaller ffi;

  /// 创建 CRDT 文档。
  ///
  /// [docId] 为空串时引擎自动生成（`crdt-N`）；已存在 → `Conflict`。
  /// [actor] 为副本标识（缺省 `"local"`）；合并副本须使用不同 actor 才能
  /// 区分 op（(actor, seq) 去重语义）。
  ///
  /// 响应 `{docId, actor, version}`。
  WbCrdtCreateData create(String docId, {String? actor}) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_crdt_create', docId, actor ?? ''),
    );
    return WbCrdtCreateData.fromJson(response.requireResult());
  }

  /// 应用一条本地操作（入参 `{key, value, timestamp?}`）。
  ///
  /// 引擎补齐 actor/seq/timestamp/origin 生成完整 op，随响应 `op` 字段
  /// 返回供同步直发；未知 [docId] → `NotFound`，缺 key/value →
  /// `InvalidArgument`。
  WbCrdtApplyData applyLocal(String docId, Map<String, dynamic> op) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_crdt_apply_local', docId, WbJsonCodec.encode(op)),
    );
    return WbCrdtApplyData.fromJson(response.requireResult());
  }
}

/// [WbCrdtService.create] 的响应：`{docId, actor, version}`。
class WbCrdtCreateData {
  const WbCrdtCreateData({this.docId = '', this.actor = '', this.version = 0});

  final String docId;
  final String actor;

  /// 文档版本（已应用 op 数量）。
  final int version;

  factory WbCrdtCreateData.fromJson(Map<String, dynamic> json) =>
      WbCrdtCreateData(
        docId: _stringAt(json, 'docId'),
        actor: _stringAt(json, 'actor'),
        version: _intAt(json, 'version'),
      );
}

/// [WbCrdtService.applyLocal] 的响应：
/// `{applied, docId, key, origin, seq, version, op}`。
class WbCrdtApplyData {
  const WbCrdtApplyData({
    this.applied = false,
    this.docId = '',
    this.key = '',
    this.origin = 'local',
    this.seq = 0,
    this.version = 0,
    this.op = const <String, dynamic>{},
  });

  /// 本次 op 是否真正改变了寄存器（LWW 败者为 false）。
  final bool applied;

  final String docId;

  /// 操作的寄存器键。
  final String key;

  /// op 来源（[WbCrdtService.applyLocal] 恒为 `"local"`）。
  final String origin;

  /// 本副本内的 op 序号。
  final int seq;

  /// 文档版本（已应用 op 数量）。
  final int version;

  /// 完整规范化 op（actor/seq/key/value/timestamp/origin），供
  /// `sendOperation` 直接转发。
  final Map<String, dynamic> op;

  factory WbCrdtApplyData.fromJson(Map<String, dynamic> json) {
    final Object? op = json['op'];
    return WbCrdtApplyData(
      applied: json['applied'] == true,
      docId: _stringAt(json, 'docId'),
      key: _stringAt(json, 'key'),
      origin: _stringAt(json, 'origin', 'local'),
      seq: _intAt(json, 'seq'),
      version: _intAt(json, 'version'),
      op: op is Map ? Map<String, dynamic>.from(op) : const <String, dynamic>{},
    );
  }
}

int _intAt(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  return value is num ? value.toInt() : 0;
}

String _stringAt(Map<String, dynamic> json, String key, [String fallback = '']) {
  final Object? value = json[key];
  return value is String ? value : fallback;
}
