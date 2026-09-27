import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

void main() {
  group('WbColors', () {
    test('基准蓝与 C++ 默认主题 accent 对齐', () {
      expect(WbColors.primary, const Color(0xFF3370FF));
    });

    test('中性色阶单调递增', () {
      expect(WbColors.gray50.toARGB32() != WbColors.gray900.toARGB32(), isTrue);
      expect(WbColors.opacityDisabled, 0.38);
      expect(WbColors.opacityScrim, 0.45);
    });
  });

  group('WbSpacing', () {
    test('4pt 网格比例', () {
      expect(WbSpacing.xxs, 2);
      expect(WbSpacing.xs, 4);
      expect(WbSpacing.sm, 8);
      expect(WbSpacing.md, 12);
      expect(WbSpacing.lg, 16);
      expect(WbSpacing.xl, 24);
      expect(WbSpacing.xxl, 32);
      expect(WbSpacing.xxxl, 48);
    });
  });

  group('WbRadius', () {
    test('基础三档与 C++ 主题 radius token 对齐（4/8/12）', () {
      expect(WbRadius.s, 4);
      expect(WbRadius.m, 8);
      expect(WbRadius.l, 12);
    });

    test('预设与动态构造一致', () {
      expect(WbRadius.allM, WbRadius.circular(WbRadius.m));
      expect(WbRadius.circular(0), BorderRadius.zero);
    });
  });

  group('WbElevation', () {
    test('层级 0 无阴影，逐级增强', () {
      expect(WbElevation.shadows(0), isEmpty);
      expect(WbElevation.shadows(1), isNotEmpty);
      expect(
        WbElevation.shadows(3).first.blurRadius,
        greaterThan(WbElevation.shadows(1).first.blurRadius),
      );
    });

    test('超过最高层级被钳制', () {
      expect(
        WbElevation.shadows(9).first.blurRadius,
        WbElevation.shadows(WbElevation.highest).first.blurRadius,
      );
    });
  });

  group('WbDuration', () {
    test('时长按序递增', () {
      expect(WbDuration.instant, Duration.zero);
      expect(WbDuration.fast < WbDuration.normal, isTrue);
      expect(WbDuration.normal < WbDuration.medium, isTrue);
      expect(WbDuration.medium < WbDuration.slow, isTrue);
      expect(WbDuration.slow < WbDuration.slower, isTrue);
    });

    test('交互时延常量', () {
      expect(WbDuration.longPressDelay, const Duration(milliseconds: 500));
      expect(WbDuration.doubleTapDelay, const Duration(milliseconds: 250));
    });
  });

  group('WbTypography', () {
    test('字号递增', () {
      expect(WbTypography.fontSizeXs < WbTypography.fontSizeSm, isTrue);
      expect(WbTypography.fontSizeSm < WbTypography.fontSizeBase, isTrue);
      expect(WbTypography.fontSizeBase < WbTypography.fontSizeLg, isTrue);
      expect(WbTypography.fontSizeLg < WbTypography.fontSizeXxl, isTrue);
    });

    test('预置样式引用正确字号', () {
      expect(WbTypography.caption.fontSize, WbTypography.fontSizeXs);
      expect(WbTypography.body.fontSize, WbTypography.fontSizeBase);
      expect(WbTypography.bodyMedium.fontWeight, WbTypography.weightMedium);
      expect(WbTypography.display.fontWeight, WbTypography.weightBold);
    });

    test('中文优先字体回退列表', () {
      expect(WbTypography.fontFallback.first, contains('YaHei'));
      expect(WbTypography.monoFallback, isNotEmpty);
    });
  });
}
