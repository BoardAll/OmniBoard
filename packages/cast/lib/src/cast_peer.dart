/// 投屏对端（WebRTC PeerConnection 封装）。
///
/// 设计：
/// - 每个发送端对应**一个独立的** PeerConnection（接收端），单路断开互不影响；
/// - 平台差异（采集权限 / 屏幕采集能力 / 渲染）收敛在本文件，UI 不写平台判断；
/// - 媒体不经过信令服务：本文件只交换 SDP / ICE 文本，媒体走 P2P；
/// - 默认不配置 STUN/TURN（同一局域网 host candidate 直连）；跨网段场景可由调用方注入。
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'cast_capture_support.dart';
import 'cast_models.dart';

/// 一路远端视频的渲染句柄。
class WbCastVideoFeed {
  /// 创建句柄。
  const WbCastVideoFeed({required this.renderer, required this.dispose});

  /// 渲染器（null 仅出现在测试 fake 中；UI 需显示占位）。
  final RTCVideoRenderer? renderer;

  /// 释放渲染资源（幂等）。
  final Future<void> Function() dispose;
}

/// 对端连接状态（映射 `RTCPeerConnectionState`）。
enum WbCastPeerState {
  /// 连接中。
  connecting,

  /// 已连通。
  connected,

  /// 连接中断（可能自愈）。
  disconnected,

  /// 连接失败。
  failed,

  /// 已关闭。
  closed,
}

/// 对端端口（控制器只依赖此接口，测试注入 fake）。
abstract interface class WbCastPeer {
  /// 接收端初始化（不采集本地媒体）。
  Future<void> startReceiver();

  /// 发送端初始化（采集媒体并加入轨道）。
  Future<void> startSender(WbCastMediaSource source);

  /// 发送端创建 Offer。
  Future<String> createOffer();

  /// 接收端处理 Offer 并返回 Answer。
  Future<String> acceptOffer(String sdp);

  /// 发送端处理 Answer。
  Future<void> acceptAnswer(String sdp);

  /// 添加远端 ICE 候选（null = 候选结束）。
  Future<void> addIceCandidate(WbCastIceCandidate? candidate);

  /// 本地 ICE 候选回调（由控制器上行发送）。
  void onLocalIceCandidate(void Function(WbCastIceCandidate? candidate) handler);

  /// 远端视频就绪回调（接收端）。
  void onVideoFeed(void Function(WbCastVideoFeed feed) handler);

  /// 连接状态回调。
  void onState(void Function(WbCastPeerState state) handler);

  /// 释放（幂等）。
  Future<void> dispose();
}

/// 对端工厂（生产：flutter_webrtc；测试：fake）。
typedef WbCastPeerFactory = WbCastPeer Function();

/// 规范化 SDP 文本：保证以换行结尾（幂等）。
///
/// Chromium/Edge 的 `setRemoteDescription` 在解析**最后一行没有换行符**的 SDP 时
/// 会报 `Failed to parse SessionDescription ... Invalid SDP line`（实测 Edge 155；
/// 本地 description 不受影响）。部分浏览器版本的 `createOffer` / `createAnswer`
/// 返回的 SDP 不带结尾换行，因此收发两侧都做一次规范化。
String normalizeWbCastSdp(String sdp) {
  if (sdp.isEmpty || sdp.endsWith('\n')) return sdp;
  return '$sdp\r\n';
}

/// `flutter_webrtc` 实现。
class WbFlutterWebrtcPeer implements WbCastPeer {
  /// 创建对端。
  WbFlutterWebrtcPeer({
    this.iceServers = const <Map<String, dynamic>>[],
    this.enableAudio = false,
  });

  /// ICE 服务器配置（局域网直连留空即可；跨网段可注入 STUN/TURN）。
  final List<Map<String, dynamic>> iceServers;

  /// 是否采集音频（本期默认视频；屏幕音频在 Windows 上不受支持）。
  final bool enableAudio;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCVideoRenderer? _renderer;
  bool _rendererDisposed = false;
  bool _disposed = false;
  void Function(WbCastIceCandidate? candidate)? _onLocalIce;
  void Function(WbCastVideoFeed feed)? _onFeed;
  void Function(WbCastPeerState state)? _onState;

  @override
  void onLocalIceCandidate(void Function(WbCastIceCandidate? candidate) handler) {
    _onLocalIce = handler;
  }

  @override
  void onVideoFeed(void Function(WbCastVideoFeed feed) handler) {
    _onFeed = handler;
  }

  @override
  void onState(void Function(WbCastPeerState state) handler) {
    _onState = handler;
  }

  @override
  Future<void> startReceiver() async {
    await _ensurePeerConnection();
  }

  @override
  Future<void> startSender(WbCastMediaSource source) async {
    final RTCPeerConnection pc = await _ensurePeerConnection();
    try {
      final MediaStream stream = await _capture(source);
      _localStream = stream;
      for (final MediaStreamTrack track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    } on WbCastFailure {
      rethrow;
    } catch (error) {
      throw WbCastFailure('MediaUnavailable', '无法采集${source.label}：$error');
    }
  }

  @override
  Future<String> createOffer() async {
    final RTCPeerConnection pc = await _ensurePeerConnection();
    final RTCSessionDescription offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return normalizeWbCastSdp(offer.sdp ?? '');
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    final RTCPeerConnection pc = await _ensurePeerConnection();
    await pc.setRemoteDescription(
      RTCSessionDescription(normalizeWbCastSdp(sdp), 'offer'),
    );
    final RTCSessionDescription answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return normalizeWbCastSdp(answer.sdp ?? '');
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    final RTCPeerConnection pc = await _ensurePeerConnection();
    await pc.setRemoteDescription(
      RTCSessionDescription(normalizeWbCastSdp(sdp), 'answer'),
    );
  }

  @override
  Future<void> addIceCandidate(WbCastIceCandidate? candidate) async {
    // null = 远端候选结束标记；flutter_webrtc 的 addCandidate 不接受 null，
    // 直接忽略即可（不影响已投递的候选）。
    if (candidate == null) return;
    final Object? raw = candidate['candidate'];
    if (raw is! String || raw.isEmpty) return;
    final RTCPeerConnection pc = await _ensurePeerConnection();
    await pc.addCandidate(
      RTCIceCandidate(
        raw,
        candidate['sdpMid']?.toString(),
        _asInt(candidate['sdpMLineIndex']),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _disposeRenderer();
    final MediaStream? local = _localStream;
    _localStream = null;
    if (local != null) {
      for (final MediaStreamTrack track in local.getTracks()) {
        await track.stop();
      }
    }
    final RTCPeerConnection? pc = _pc;
    _pc = null;
    if (pc != null) {
      await pc.close();
      await pc.dispose();
    }
  }

  // —— 内部 ——

  Future<RTCPeerConnection> _ensurePeerConnection() async {
    final RTCPeerConnection? existing = _pc;
    if (existing != null) return existing;
    final RTCPeerConnection pc = await createPeerConnection(<String, dynamic>{
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      if (_disposed) return;
      if (candidate.candidate == null || candidate.candidate!.isEmpty) {
        _onLocalIce?.call(null);
        return;
      }
      _onLocalIce?.call(<String, dynamic>{
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onConnectionState = (RTCPeerConnectionState state) {
      _onState?.call(_mapState(state));
    };
    pc.onTrack = (RTCTrackEvent event) {
      unawaited(_handleRemoteStream(event));
    };
    return pc;
  }

  Future<void> _handleRemoteStream(RTCTrackEvent event) async {
    if (_disposed) return;
    MediaStream? stream = event.streams.isNotEmpty ? event.streams.first : null;
    if (stream == null) {
      final MediaStreamTrack track = event.track;
      stream = await createLocalMediaStream('remote-${track.id}');
      await stream.addTrack(track);
    }
    if (_remoteStream == stream && _renderer != null) return;
    _remoteStream = stream;
    final RTCVideoRenderer renderer = _renderer ?? RTCVideoRenderer();
    if (_renderer == null) {
      _renderer = renderer;
      await renderer.initialize();
    }
    renderer.srcObject = stream;
    _onFeed?.call(
      WbCastVideoFeed(renderer: renderer, dispose: _disposeRenderer),
    );
  }

  Future<MediaStream> _capture(WbCastMediaSource source) async {
    final String? unavailable = wbCastCaptureUnavailableReason(
      screen: source == WbCastMediaSource.screen,
    );
    if (unavailable != null) {
      throw WbCastFailure('MediaUnavailable', unavailable);
    }
    switch (source) {
      case WbCastMediaSource.camera:
        return navigator.mediaDevices.getUserMedia(<String, dynamic>{
          'audio': enableAudio,
          'video': <String, dynamic>{
            'width': <String, dynamic>{'ideal': 1280},
            'height': <String, dynamic>{'ideal': 720},
            'frameRate': <String, dynamic>{'ideal': 30},
            'facingMode': 'user',
          },
        });
      case WbCastMediaSource.screen:
        // 桌面原生端必须先枚举屏幕源再显式指定 id：flutter_webrtc 的 C++
        // 实现里 `getDisplayMedia` 在拿不到 `deviceId.exact` 时把 source_id
        // 固定成 "0"，只有 Linux 分支会在 sources_ 为空时重新枚举并回落到
        // 第一个源；Windows 没有这段兜底，会直接返回 "source not found!"。
        // 而 sources_ 只在 `desktopCapturer.getSources` 时被填充，故先取源。
        if (!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.linux ||
                defaultTargetPlatform == TargetPlatform.macOS)) {
          final List<DesktopCapturerSource> screens =
              await desktopCapturer.getSources(
            types: <SourceType>[SourceType.Screen],
          );
          if (screens.isEmpty) {
            throw const WbCastFailure(
              'MediaUnavailable',
              '没有找到可捕获的屏幕，请确认系统已允许录屏权限后重试。',
            );
          }
          return navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
            'video': <String, dynamic>{
              'deviceId': <String, dynamic>{'exact': screens.first.id},
              'cursor': 'always',
            },
            'audio': enableAudio,
          });
        }
        return navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
          'video': <String, dynamic>{'cursor': 'always'},
          'audio': enableAudio,
        });
    }
  }

  Future<void> _disposeRenderer() async {
    if (_rendererDisposed) return;
    _rendererDisposed = true;
    final RTCVideoRenderer? renderer = _renderer;
    _renderer = null;
    if (renderer == null) return;
    renderer.srcObject = null;
    await renderer.dispose();
  }

  static WbCastPeerState _mapState(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        return WbCastPeerState.connected;
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        return WbCastPeerState.disconnected;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return WbCastPeerState.failed;
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        return WbCastPeerState.closed;
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        return WbCastPeerState.connecting;
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
