import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

void main() {
  group('WbColorUtils', () {
    test('fromHex 支持 #RGB/#RRGGBB/#AARRGGBB 与无 # 格式', () {
      expect(WbColorUtils.fromHex('#3370FF'), const Color(0xFF3370FF));
      expect(WbColorUtils.fromHex('3370FF'), const Color(0xFF3370FF));
      expect(WbColorUtils.fromHex('#abc'), const Color(0xFFAABBCC));
      expect(WbColorUtils.fromHex('#803370FF'), const Color(0x803370FF));
    });

    test('fromHex 非法输入回退到 fallback', () {
      expect(WbColorUtils.fromHex('zzz', fallback: const Color(0xFF123456)),
          const Color(0xFF123456));
      expect(WbColorUtils.fromHex('', fallback: const Color(0xFF123456)),
          const Color(0xFF123456));
    });

    test('toHex 往返一致', () {
      const Color color = Color(0xFF3370FF);
      expect(WbColorUtils.toHex(color), '#3370FF');
      expect(WbColorUtils.fromHex(WbColorUtils.toHex(color)), color);
    });

    test('亮度与对比色', () {
      expect(WbColorUtils.isLight(const Color(0xFFFFFFFF)), isTrue);
      expect(WbColorUtils.isLight(const Color(0xFF000000)), isFalse);
      expect(WbColorUtils.contrastText(const Color(0xFFFFFFFF)),
          const Color(0xFF1D2939));
      expect(WbColorUtils.contrastText(const Color(0xFF101828)),
          const Color(0xFFFFFFFF));
    });

    test('blend/lighten/darken/fade', () {
      const Color black = Color(0xFF000000);
      const Color white = Color(0xFFFFFFFF);
      expect(WbColorUtils.blend(black, white, 0), black);
      expect(WbColorUtils.blend(black, white, 1), white);
      expect(WbColorUtils.lighten(black, 1), white);
      expect(WbColorUtils.darken(white, 1), black);
      final Color faded = WbColorUtils.fade(const Color(0xFF3370FF), 0.5);
      expect(faded.a, closeTo(0.5, 0.01));
    });

    test('ARGB32 整数往返', () {
      const Color color = Color(0xFF3370FF);
      expect(WbColorUtils.fromArgb32(WbColorUtils.toArgb32(color)), color);
    });
  });

  group('WbTextUtils', () {
    test('ellipsis 按字符截断（含中文）', () {
      expect(WbTextUtils.ellipsis('abcdef', 10), 'abcdef');
      expect(WbTextUtils.ellipsis('abcdefghijk', 6), 'abcde…');
      expect(WbTextUtils.ellipsis('中文测试文本超长', 5), '中文测试…');
    });

    test('initials 中文取首字、英文取首字母', () {
      expect(WbTextUtils.initials('张三'), '张');
      expect(WbTextUtils.initials('John Doe'), 'JD');
      expect(WbTextUtils.initials('alice'), 'A');
      expect(WbTextUtils.initials(''), '?');
      expect(WbTextUtils.initials('   '), '?');
    });

    test('hasCjk', () {
      expect(WbTextUtils.hasCjk('hello 世界'), isTrue);
      expect(WbTextUtils.hasCjk('hello world'), isFalse);
    });

    test('estimateWidth 中文宽于英文', () {
      final double cn = WbTextUtils.estimateWidth('中文字', 14);
      final double en = WbTextUtils.estimateWidth('abc', 14);
      expect(cn, 42);
      expect(en, lessThan(cn));
    });

    test('thousands 千分位', () {
      expect(WbTextUtils.thousands(0), '0');
      expect(WbTextUtils.thousands(999), '999');
      expect(WbTextUtils.thousands(1234), '1,234');
      expect(WbTextUtils.thousands(1234567), '1,234,567');
      expect(WbTextUtils.thousands(-1234567), '-1,234,567');
    });
  });

  group('WbLayoutUtils', () {
    test('响应式断点', () {
      expect(WbLayoutUtils.isCompact(500), isTrue);
      expect(WbLayoutUtils.isMedium(800), isTrue);
      expect(WbLayoutUtils.isExpanded(1400), isTrue);
      expect(WbLayoutUtils.isCompact(1400), isFalse);
    });

    test('clampZoom 限制缩放范围', () {
      expect(WbLayoutUtils.clampZoom(0.01), WbLayoutUtils.minZoom);
      expect(WbLayoutUtils.clampZoom(100), WbLayoutUtils.maxZoom);
      expect(WbLayoutUtils.clampZoom(1.5), 1.5);
    });

    test('snapToGrid 吸附坐标', () {
      expect(WbLayoutUtils.snapToGrid(const Offset(13, 27), 10),
          const Offset(10, 30));
      expect(WbLayoutUtils.snapToGrid(const Offset(13.2, 27.9), 0),
          const Offset(13.2, 27.9));
    });

    test('ensureMinSize 居中扩展', () {
      final Rect rect = WbLayoutUtils.ensureMinSize(
        const Rect.fromLTWH(10, 10, 4, 4),
        const Size(20, 20),
      );
      expect(rect.width, 20);
      expect(rect.height, 20);
      expect(rect.center, const Offset(12, 12));
    });

    test('fitZoom 匹配视口', () {
      // 100×100 内容放进 200×200 视口（留白 20×2）→ 1.6 倍
      expect(
        WbLayoutUtils.fitZoom(const Size(100, 100), const Size(200, 200), padding: 20),
        closeTo(1.6, 0.001),
      );
      // 内容退化返回 1.0
      expect(WbLayoutUtils.fitZoom(Size.zero, const Size(100, 100)), 1.0);
    });
  });
}
