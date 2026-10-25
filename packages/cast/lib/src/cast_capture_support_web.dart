import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// 安全上下文（HTTPS / localhost / 127.0.0.1）时为 true。
@JS('isSecureContext')
external bool? get _isSecureContext;

/// 非安全上下文下该属性为 undefined；用可空 JSObject 读取，避免 `mediaDevices!`
/// 的空断言（这正是 flutter_webrtc 在 HTTP 页面报 null check 的根因）。
@JS('navigator.mediaDevices')
external JSObject? get _mediaDevices;

/// 返回不可采集的原因；null 表示可以继续调用采集 API。
String? wbCastCaptureUnavailableReason({required bool screen}) {
  if (_isSecureContext != true) {
    return '当前页面不是安全上下文（HTTPS 或 localhost），浏览器已禁用屏幕/摄像头采集。'
        '请通过 HTTPS 访问后再试。';
  }
  final JSObject? devices = _mediaDevices;
  if (devices == null) {
    return '当前浏览器未提供媒体设备接口（navigator.mediaDevices），无法采集。'
        '请确认使用 HTTPS，并更换为支持的浏览器。';
  }
  if (screen && !devices.has('getDisplayMedia')) {
    return '当前浏览器不支持屏幕采集（移动端浏览器通常不支持）。'
        '请改用摄像头，或在桌面浏览器中发起投屏。';
  }
  return null;
}
