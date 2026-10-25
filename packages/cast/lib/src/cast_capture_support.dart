/// 采集能力检测（跨端分发）。
///
/// Web 端在非安全上下文（HTTP + 非 localhost）下，浏览器会把
/// `navigator.mediaDevices` 置为 undefined，直接调用 `getDisplayMedia` 会抛
/// `Null check operator used on a null value`；移动端浏览器通常不提供
/// `getDisplayMedia`。这里在采集前给出可操作的提示，避免把底层断言直接暴露给用户。
library;

export 'cast_capture_support_stub.dart'
    if (dart.library.js_interop) 'cast_capture_support_web.dart';
