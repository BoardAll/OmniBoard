/// 画笔取色盘的 HSV 色轮：色相沿圆周、饱和度沿半径，下方为明度条；
/// 拖动过程中实时回调 [WbPenColorWheel.onChanged]。
///
/// 几何约定（渲染与手势换算一致）：
/// - 角度 0 处为色相 0°（红，+x 方向），顺时针一周 360°；
/// - 圆心饱和度 0，圆缘饱和度 1；
/// - 明度条左端 0（黑）、右端 1（当前色相满饱和色）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 画笔取色色轮（受控组件，alpha 通道原样保留）。
class WbPenColorWheel extends StatefulWidget {
  /// 创建色轮。
  const WbPenColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
    this.diameter = 224,
    this.barHeight = 22,
  });

  /// 当前颜色。
  final Color color;

  /// 选色回调（拖动过程中连续触发）。
  final ValueChanged<Color> onChanged;

  /// 色轮直径。
  final double diameter;

  /// 明度条高度。
  final double barHeight;

  @override
  State<WbPenColorWheel> createState() => _WbPenColorWheelState();
}

class _WbPenColorWheelState extends State<WbPenColorWheel> {
  /// 最近一次由本组件发出的颜色（外部回环时不重算缓存）。
  int? _lastEmitted;

  /// 色相缓存：饱和度为 0 时 HSV 换算丢失色相，交互中保持上次有效值。
  late double _hue = HSVColor.fromColor(widget.color).hue;

  /// 饱和度缓存：同理用于明度为 0 的场景。
  late double _saturation = HSVColor.fromColor(widget.color).saturation;

  @override
  void initState() {
    super.initState();
    _syncFromWidget(null);
  }

  @override
  void didUpdateWidget(WbPenColorWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFromWidget(oldWidget.color);
  }

  /// 外部颜色变化时同步缓存；自己发出的颜色（[_lastEmitted]）不重算，
  /// 避免灰度 / 黑色经 HSV 换算丢失色相导致光标跳动。
  void _syncFromWidget(Color? previous) {
    final int argb = widget.color.toARGB32();
    if (previous != null && previous.toARGB32() == argb) {
      return;
    }
    if (argb == _lastEmitted) {
      return;
    }
    final HSVColor hsv = HSVColor.fromColor(widget.color);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
  }

  /// 当前明度（v 不会经换算丢失：黑色即 v=0）。
  double get _value => HSVColor.fromColor(widget.color).value;

  void _emit(double hue, double saturation, double value) {
    final HSVColor hsv = HSVColor.fromAHSV(
      widget.color.a.clamp(0.0, 1.0),
      (hue % 360 + 360) % 360,
      saturation.clamp(0.0, 1.0),
      value.clamp(0.0, 1.0),
    );
    final Color color = hsv.toColor();
    setState(() {
      _hue = hsv.hue;
      _saturation = hsv.saturation;
      _lastEmitted = color.toARGB32();
    });
    widget.onChanged(color);
  }

  void _handleWheel(Offset local) {
    final double radius = widget.diameter / 2;
    final Offset delta = local - Offset(radius, radius);
    final double saturation = (delta.distance / radius).clamp(0.0, 1.0);
    final double hue = delta.distance < 0.5
        ? _hue
        : math.atan2(delta.dy, delta.dx) * 180 / math.pi;
    _emit(hue, saturation, _value);
  }

  void _handleValueBar(Offset local) {
    final double width = widget.diameter;
    if (width <= 0) {
      return;
    }
    _emit(_hue, _saturation, (local.dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final double diameter = widget.diameter;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        GestureDetector(
          key: const ValueKey<String>('wb-pen-color-wheel'),
          behavior: HitTestBehavior.opaque,
          onPanDown: (DragDownDetails details) =>
              _handleWheel(details.localPosition),
          onPanUpdate: (DragUpdateDetails details) =>
              _handleWheel(details.localPosition),
          child: CustomPaint(
            size: Size.square(diameter),
            painter: _WbColorWheelPainter(
              hue: _hue,
              saturation: _saturation,
              value: _value,
            ),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          key: const ValueKey<String>('wb-pen-color-value-bar'),
          behavior: HitTestBehavior.opaque,
          onPanDown: (DragDownDetails details) =>
              _handleValueBar(details.localPosition),
          onPanUpdate: (DragUpdateDetails details) =>
              _handleValueBar(details.localPosition),
          child: CustomPaint(
            size: Size(diameter, widget.barHeight),
            painter: _WbValueBarPainter(
              hue: _hue,
              saturation: _saturation,
              value: _value,
            ),
          ),
        ),
      ],
    );
  }
}

/// 色轮绘制：色相盘 + 饱和度渐变 + 明度蒙层 + 光标圆环。
class _WbColorWheelPainter extends CustomPainter {
  const _WbColorWheelPainter({
    required this.hue,
    required this.saturation,
    required this.value,
  });

  final double hue;
  final double saturation;
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = size.shortestSide / 2;
    final Rect circle = Rect.fromCircle(center: center, radius: radius);

    // 色相盘：六段标准色相 + 收尾红（与手势 atan2 同向，顺时针递增）。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = SweepGradient(
          colors: <Color>[
            for (int step = 0; step < 6; step++)
              HSVColor.fromAHSV(1, step * 60.0, 1, 1).toColor(),
            const HSVColor.fromAHSV(1, 360, 1, 1).toColor(),
          ],
        ).createShader(circle),
    );

    // 饱和度：圆心白 → 圆缘透明（等价于由白向纯色过渡）。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: <Color>[Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        ).createShader(circle),
    );

    // 明度：黑色蒙层 alpha = 1 - v。
    if (value < 1) {
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = Color.fromRGBO(0, 0, 0, 1 - value),
      );
    }

    // 外描边。
    canvas.drawCircle(
      center,
      radius - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x22000000),
    );

    // 光标：白色圆环 + 内芯当前色（半径内收避免越出圆缘）。
    final double angle = hue * math.pi / 180;
    final Offset thumb = center +
        Offset(math.cos(angle), math.sin(angle)) * (saturation * (radius - 12));
    canvas.drawCircle(thumb, 10, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(
      thumb,
      10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x66000000),
    );
    canvas.drawCircle(
      thumb,
      6,
      Paint()..color = HSVColor.fromAHSV(1, hue, saturation, value).toColor(),
    );
  }

  @override
  bool shouldRepaint(_WbColorWheelPainter oldDelegate) =>
      oldDelegate.hue != hue ||
      oldDelegate.saturation != saturation ||
      oldDelegate.value != value;
}

/// 明度条绘制：黑 → 当前色相满饱和色的渐变 + 圆形滑块。
class _WbValueBarPainter extends CustomPainter {
  const _WbValueBarPainter({
    required this.hue,
    required this.saturation,
    required this.value,
  });

  final double hue;
  final double saturation;
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect track = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(
      track,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            const Color(0xFF000000),
            HSVColor.fromAHSV(1, hue, saturation, 1).toColor(),
          ],
        ).createShader(rect),
    );
    canvas.drawRRect(
      track,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x22000000),
    );

    // 滑块圆心在 [inset, width - inset] 之间随 v 线性移动。
    final double inset = size.height / 2;
    final Offset thumb = Offset(
      inset + (size.width - 2 * inset) * value.clamp(0.0, 1.0),
      inset,
    );
    canvas.drawCircle(thumb, inset, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(
      thumb,
      inset,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x66000000),
    );
    canvas.drawCircle(
      thumb,
      inset - 3.5,
      Paint()..color = HSVColor.fromAHSV(1, hue, saturation, value).toColor(),
    );
  }

  @override
  bool shouldRepaint(_WbValueBarPainter oldDelegate) =>
      oldDelegate.hue != hue ||
      oldDelegate.saturation != saturation ||
      oldDelegate.value != value;
}
