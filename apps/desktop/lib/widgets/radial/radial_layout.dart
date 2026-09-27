/// 齿轮圆盘几何：角度分配、径向命中测试与子环槽位计算（纯函数，便于单测）。
///
/// 尺寸口径来自《齿轮圆盘交互详细设计 v1.1》2.2 / 5.2 / 6.2 节：
/// - 中心 0–28px；内环 28–72px；外环 72–120px；子环 120–180px；
/// - 底盘直径 240px（[discDiameter]）；布局外框 360px（[frame]，覆盖
///   子环 180px 半径的命中区域，收起时中心 56px）；
/// - 条目宽 内环 40 / 外环 44 / 子环 40（较初版收窄 4px 拉开相邻间距）。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'radial_models.dart';

/// 子工具弧总跨度（弧度，约 56°）。
const double kSubSpanRadians = 56 * math.pi / 180;

/// 子环最多同时显示的槽位数（文档 6.2：超过 6 个滚动）。
const int kSubVisibleSlots = 6;

/// 圆盘几何度量（按 [scale] 派生；scale=1 为基准）。
class RadialMetrics {
  const RadialMetrics({this.scale = 1});

  /// 尺寸缩放系数（档位 / 屏幕自适应 / 触屏放大叠加）。
  final double scale;

  /// 组件布局外框尺寸（基准 360px = 2 × 子环外缘）。
  ///
  /// 取子环满半径，保证子工具扇区（120–180px）可命中；底盘仍为
  /// [discDiameter]（240px）。
  double get frame => 360 * scale;

  /// 圆盘底盘直径（基准 240px）。
  double get discDiameter => 240 * scale;

  /// 圆盘外接半径（底盘半径，基准 120px）。
  double get radius => 120 * scale;

  /// 中心圆半径（基准 28px）。
  double get centerRadius => 28 * scale;

  /// 内环条目中心半径（外移至 56，拉开相邻条目弧向间距）。
  double get innerRadius => 56 * scale;

  /// 内环条目尺寸（40px 宽；配合 56 半径保证条目留白）。
  double get innerItemSize => 40 * scale;

  /// 外环条目中心半径（72–120 环带中线）。
  double get outerRadius => 96 * scale;

  /// 外环条目尺寸（44px 宽）。
  double get outerItemSize => 44 * scale;

  /// 子环条目中心半径（外移至 156，拉开与底盘的间隙）。
  double get subRadius => 156 * scale;

  /// 子环条目尺寸（40px 宽）。
  double get subItemSize => 40 * scale;

  /// 图标基准尺寸（24px）。
  double get iconSize => 24 * scale;

  /// 标签字号（文档 2.2：11px）。
  double get labelFontSize => 11 * scale;

  /// 最近使用条目尺寸（28px）。
  double get recentItemSize => 28 * scale;

  /// 拖拽取消半径（< 28px 视为"回拖取消"）。
  double get cancelRadius => 28 * scale;

  /// 内环外缘（72px）。
  double get innerOuterEdge => 72 * scale;

  /// 外环外缘 / 子环内缘（120px）。
  double get outerEdge => 120 * scale;

  /// 子环外缘（180px）。
  double get subEdge => 180 * scale;

  /// 组件中心（也是圆盘圆心）。
  Offset get center => Offset(frame / 2, frame / 2);

  @override
  bool operator ==(Object other) =>
      other is RadialMetrics && other.scale == scale;

  @override
  int get hashCode => scale.hashCode;
}

/// 第 [index] / [count] 个扇区的角度（弧度）。
///
/// 约定：第 0 个在正上方（-π/2），顺时针递增（文档 2.1：从正上方开始）。
double angleForIndex(int index, int count) {
  if (count <= 0) {
    return -math.pi / 2;
  }
  return -math.pi / 2 + 2 * math.pi * index / count;
}

/// 归一化角度到 [0, 2π)。
double normalizeAngle(double angle) {
  const double twoPi = 2 * math.pi;
  double value = angle % twoPi;
  if (value < 0) {
    value += twoPi;
  }
  return value;
}

/// 角度差 `a - b` 归一化到 (-π, π]。
double angleDelta(double a, double b) {
  double delta = normalizeAngle(a - b);
  if (delta > math.pi) {
    delta -= 2 * math.pi;
  }
  return delta;
}

/// 径向 + 角度坐标：以圆盘中心为原点，角度从正上方顺时针。
Offset offsetAt(double radius, double angle) =>
    Offset(radius * math.cos(angle), radius * math.sin(angle));

/// 指针角度（弧度，atan2 口径）最接近的扇区序号（0..count-1）。
int nearestIndexForAngle(double angle, int count) {
  if (count <= 0) {
    return 0;
  }
  final double step = 2 * math.pi / count;
  final double relative = normalizeAngle(angle + math.pi / 2);
  final int index = (relative / step).round() % count;
  return index < 0 ? index + count : index;
}

/// 由距中心半径判断拖拽所在环带。
///
/// 与文档 5.2 一致：<28 取消区；28–72 内环；72–120 外环；>120 子环带。
RadialZone zoneForRadius(double radius, RadialMetrics metrics) {
  if (radius < metrics.cancelRadius) {
    return RadialZone.none;
  }
  if (radius < metrics.innerOuterEdge) {
    return RadialZone.inner;
  }
  if (radius < metrics.outerEdge) {
    return RadialZone.outer;
  }
  return RadialZone.sub;
}

/// 子环第 [slot] / [slotCount] 个槽位相对父扇区中心角 [centerAngle] 的角度。
///
/// 槽位沿弧分布：slot=0 落在顺指针端，末位槽落在逆时针端，中间均匀过渡。
double subSlotAngle(double centerAngle, int slot, int slotCount) {
  if (slotCount <= 1) {
    return centerAngle;
  }
  final double t = slot / (slotCount - 1);
  return centerAngle + kSubSpanRadians * (0.5 - t);
}

/// 由指针角度反推子槽位序号；超出子环弧范围返回 null。
int? subSlotForAngle(double angle, double centerAngle, int slotCount) {
  if (slotCount <= 0) {
    return null;
  }
  final double delta = angleDelta(angle, centerAngle);
  const double tolerance = 0.10; // 约 6°，避免弧外微微抖动丢失命中
  if (delta.abs() > kSubSpanRadians / 2 + tolerance) {
    return null;
  }
  if (slotCount == 1) {
    return 0;
  }
  final double t = 0.5 - delta / kSubSpanRadians;
  return (t * (slotCount - 1)).round().clamp(0, slotCount - 1);
}

/// 子环滚动上限（工具数不超过 [visible] 时为 0）。
int subScrollMax(int toolCount, {int visible = kSubVisibleSlots}) =>
    math.max(0, toolCount - visible);

/// 将滚动偏移夹到有效范围。
int clampSubScroll(int value, int toolCount,
        {int visible = kSubVisibleSlots}) =>
    value.clamp(0, subScrollMax(toolCount, visible: visible));
