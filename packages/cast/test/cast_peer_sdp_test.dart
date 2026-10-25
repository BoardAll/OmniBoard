/// SDP 规范化单测：覆盖「最后一行缺少换行」导致的远端描述解析失败。
///
/// 背景：Edge/Chromium 的 `setRemoteDescription` 对末行无换行的 SDP 会报
/// `Invalid SDP line`（采集自真实投屏闭环），收发两侧都必须补齐结尾换行。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_cast/cast.dart';

void main() {
  group('normalizeWbCastSdp', () {
    test('缺少结尾换行时补齐 CRLF', () {
      const String sdp = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=ssrc:1 cname:x';
      expect(normalizeWbCastSdp(sdp), '$sdp\r\n');
    });

    test('已以 CRLF 结尾时保持不变（幂等）', () {
      const String sdp = 'v=0\r\na=ssrc:1 cname:x\r\n';
      expect(normalizeWbCastSdp(sdp), sdp);
      expect(normalizeWbCastSdp(normalizeWbCastSdp(sdp)), sdp);
    });

    test('已以 LF 结尾时不再追加（Chrome 接受 LF 行分隔）', () {
      const String sdp = 'v=0\na=ssrc:1 cname:x\n';
      expect(normalizeWbCastSdp(sdp), sdp);
    });

    test('空串原样返回', () {
      expect(normalizeWbCastSdp(''), '');
    });
  });
}
