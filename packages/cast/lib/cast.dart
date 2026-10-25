/// Whiteboard 局域网投屏（LAN Cast）。
///
/// 分层：
/// - [WbCastController]：投屏会话状态机（接收端 / 发送端）；
/// - `WbCastSocketSignaling`：既有 realtime 服务 `/cast` namespace 的信令传输；
/// - [WbFlutterWebrtcPeer]：每个发送端一个 PeerConnection，媒体 P2P；
/// - [WbCastCodeOverlay] / [WbCastOverlayLayer] / [WbCastSettingsSheet] / [WbCastJoinDialog]：白板内的覆盖层 UI。
///
/// 与白板的边界：本包不依赖白板文档模型，视频与投屏码只作为画布上方的
/// Flutter 覆盖层存在，不写入白板内容 / 导出 / 普通协同消息。
library;

export 'src/cast_capture_support.dart';
export 'src/cast_controller.dart';
export 'src/cast_join_dialog.dart';
export 'src/cast_models.dart';
export 'src/cast_peer.dart';
export 'src/cast_settings.dart';
export 'src/cast_signaling.dart';
export 'src/cast_widgets.dart';
