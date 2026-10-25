/// 采集能力检测单测。
///
/// VM/桌面条件走 stub：原生端采集能力由系统权限与插件决定，检测函数不应拦截；
/// Web 条件（dart.library.js_interop）下的安全上下文判断由浏览器端构建验证。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_cast/src/cast_capture_support.dart';

void main() {
  test('原生/VM 条件不拦截采集', () {
    expect(wbCastCaptureUnavailableReason(screen: true), isNull);
    expect(wbCastCaptureUnavailableReason(screen: false), isNull);
  });
}
