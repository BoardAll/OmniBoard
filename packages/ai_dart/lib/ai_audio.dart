/// AI 语音模型与流式音频通道（《AI 助手与 MCP 设计》§4.6 语音接入）。
///
/// 覆盖语音链路：麦克风 -> VAD -> 流式 ASR -> LLM -> Tool Calls -> TTS。
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// 语音交互状态（§4.6 状态视觉；颜色由 UI 层映射）。
abstract final class AiVoiceStates {
  static const String listening = 'listening';
  static const String thinking = 'thinking';
  static const String executing = 'executing';
  static const String done = 'done';
  static const String error = 'error';
  static const String waitingConfirm = 'waitingConfirm';

  /// 状态 → 中文标签。
  static String label(String state) {
    switch (state) {
      case listening:
        return '聆听中';
      case thinking:
        return '思考中';
      case executing:
        return '执行中';
      case done:
        return '已完成';
      case error:
        return '出错';
      case waitingConfirm:
        return '等待确认';
      default:
        return state;
    }
  }
}

/// 一段音频分片（流式 ASR 输入）。
class AiAudioChunk {
  const AiAudioChunk({
    required this.bytes,
    this.sequence = 0,
    this.isFinal = false,
  });

  /// 原始音频字节（PCM / Opus 等，由提供方约定）。
  final List<int> bytes;

  /// 分片序号（从 0 递增）。
  final int sequence;

  /// 是否为最后一片（触发 end-of-utterance）。
  final bool isFinal;

  int get length => bytes.length;

  @override
  String toString() =>
      'AiAudioChunk(#$sequence, ${bytes.length} bytes${isFinal ? ', final' : ''})';
}

/// ASR 转写结果（流式返回时 `isFinal == false` 表示临时结果）。
class AiTranscript {
  const AiTranscript({
    this.text = '',
    this.isFinal = false,
    this.confidence = 0,
    this.language = '',
  });

  final String text;
  final bool isFinal;

  /// 置信度（0-1，未知为 0）。
  final double confidence;
  final String language;

  factory AiTranscript.fromJson(Map<String, dynamic> json) {
    return AiTranscript(
      text: json['text'] is String ? json['text'] as String : '',
      isFinal: json['isFinal'] == true,
      confidence: json['confidence'] is num
          ? (json['confidence'] as num).toDouble()
          : 0,
      language: json['language'] is String ? json['language'] as String : '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'isFinal': isFinal,
        if (confidence > 0) 'confidence': confidence,
        if (language.isNotEmpty) 'language': language,
      };

  @override
  String toString() =>
      'AiTranscript(${text.length} chars, final=$isFinal)';
}

/// 流式音频 WebSocket 通道（对接实时 ASR / TTS 端点）。
///
/// ```dart
/// final socket = AiAudioSocket(Uri.parse('wss://host/v1/realtime?intent=transcription'));
/// await socket.connect();
/// socket.sendJson({'type': 'session.update', ...});
/// socket.sendAudio(AiAudioChunk(bytes: pcm16));
/// socket.events.listen((event) => ...);
/// ```
class AiAudioSocket {
  AiAudioSocket(this.uri);

  final Uri uri;

  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// 服务端事件流（JSON 帧）。
  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isConnected => _channel != null;

  /// 建立连接（幂等）。
  Future<void> connect() async {
    if (_channel != null) {
      return;
    }
    final WebSocketChannel channel = WebSocketChannel.connect(uri);
    await channel.ready;
    _channel = channel;
    channel.stream.listen(
      (Object? frame) {
        if (frame is String) {
          try {
            final Object? decoded = jsonDecode(frame);
            if (decoded is Map && !_events.isClosed) {
              _events.add(Map<String, dynamic>.from(decoded));
            }
          } on FormatException {
            // 忽略非 JSON 文本帧。
          }
        }
      },
      onError: (Object error) {
        if (!_events.isClosed) {
          _events.addError(error);
        }
      },
      onDone: () {
        _channel = null;
      },
    );
  }

  /// 发送一条 JSON 控制消息。
  void sendJson(Map<String, dynamic> payload) {
    final WebSocketChannel? channel = _channel;
    if (channel == null) {
      throw StateError('AiAudioSocket is not connected');
    }
    channel.sink.add(jsonEncode(payload));
  }

  /// 发送音频分片（二进制帧）。
  void sendAudio(AiAudioChunk chunk) {
    final WebSocketChannel? channel = _channel;
    if (channel == null) {
      throw StateError('AiAudioSocket is not connected');
    }
    channel.sink.add(chunk.bytes);
  }

  /// 关闭连接与事件流。
  Future<void> close() async {
    await _channel?.sink.close();
    _channel = null;
    await _events.close();
  }
}
