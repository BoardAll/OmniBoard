/// 3D 网格投影公共模块（问题 6 后半：直绘 / 翻转 / 涂色共用）。
///
/// 把 `render3d_editor.dart` 原有的迷你软件渲染（正交投影 + 背面剔除 +
/// 画家算法 + Lambert 明暗）平移为无状态纯函数，供三类消费者复用：
/// - 编辑器预览（`Wb3dMeshPainter`，经本模块投影后绘制）；
/// - 画布元素渲染（`professional_painter.dart`，零改动走 painter）；
/// - 画布交互（直绘半透明预览 / 表面涂色命中面 / 翻转旋转实时重投影）。
///
/// 投影口径与原 `Wb3dMeshPainter.paint` 完全一致：
/// 相机 yaw = 0.58 / pitch = 0.38（弧度）、平行光 / 点光 / 聚光方向固定、
/// 正交投影 `k = min(w,h) * 0.34 / extent`、画布中心对齐 +
/// `(p.x * k, -p.y * k)`；面按 depth 升序（远 → 近）返回。
///
/// [Wb3dProjector.project] 的 `colors` 入参对齐绘制端签名（当前着色由
/// `scene.color` 驱动；保留参数以便未来接入主题化网格配色）。
///
/// 注意：本文件与 `render3d_editor.dart` 互相导入（后者引用本模块做投影，
/// 本模块引用后者的 [Wb3dScene] / [Wb3dObjectType] 模型），Dart 允许库级
/// 循环导入，无初始化顺序问题。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:whiteboard_theme/theme.dart';

import '../context_editors/render3d_editor.dart';

// ---------------------------------------------------------------------------
// 三维向量与网格
// ---------------------------------------------------------------------------

/// 三维向量（不可变；投影管线内部与测试共用）。
@immutable
class Wb3dV3 {
  /// 创建向量。
  const Wb3dV3(this.x, this.y, this.z);

  /// X 分量。
  final double x;

  /// Y 分量。
  final double y;

  /// Z 分量。
  final double z;

  /// 向量加法。
  Wb3dV3 operator +(Wb3dV3 other) => Wb3dV3(x + other.x, y + other.y, z + other.z);

  /// 向量减法。
  Wb3dV3 operator -(Wb3dV3 other) => Wb3dV3(x - other.x, y - other.y, z - other.z);

  /// 标量乘法。
  Wb3dV3 operator *(double scalar) => Wb3dV3(x * scalar, y * scalar, z * scalar);

  /// 点积。
  double dot(Wb3dV3 other) => x * other.x + y * other.y + z * other.z;

  /// 叉积。
  Wb3dV3 cross(Wb3dV3 other) => Wb3dV3(
        y * other.z - z * other.y,
        z * other.x - x * other.z,
        x * other.y - y * other.x,
      );

  /// 模长。
  double get length => math.sqrt(x * x + y * y + z * z);

  /// 单位化（零向量返回零向量）。
  Wb3dV3 normalized() {
    final double len = length;
    if (len < 1e-9) {
      return const Wb3dV3(0, 0, 0);
    }
    return Wb3dV3(x / len, y / len, z / len);
  }

  /// 绕 X 轴旋转（弧度）。
  Wb3dV3 rotateX(double angle) {
    final double c = math.cos(angle);
    final double s = math.sin(angle);
    return Wb3dV3(x, y * c - z * s, y * s + z * c);
  }

  /// 绕 Y 轴旋转（弧度）。
  Wb3dV3 rotateY(double angle) {
    final double c = math.cos(angle);
    final double s = math.sin(angle);
    return Wb3dV3(x * c + z * s, y, -x * s + z * c);
  }

  /// 绕 Z 轴旋转（弧度）。
  Wb3dV3 rotateZ(double angle) {
    final double c = math.cos(angle);
    final double s = math.sin(angle);
    return Wb3dV3(x * c - y * s, x * s + y * c, z);
  }
}

/// 网格（顶点 + 多边形面；尺寸归一到约 ±1）。
@immutable
class Wb3dMesh {
  /// 创建网格。
  const Wb3dMesh({
    required this.vertices,
    required this.faces,
    this.flipNormalsToOutward = true,
  });

  /// 顶点列表。
  final List<Wb3dV3> vertices;

  /// 多边形面（顶点索引绕序列表）。
  final List<List<int>> faces;

  /// 是否以网格中心为参照翻转法线（凸体适用；圆环等已按外向绕序建模）。
  final bool flipNormalsToOutward;
}

/// 各对象类型的网格构建（尺寸归一到约 ±1）。
abstract final class Wb3dMeshFactory {
  /// 按类型构建网格。
  static Wb3dMesh build(Wb3dObjectType type) {
    switch (type) {
      case Wb3dObjectType.box:
        return _box();
      case Wb3dObjectType.cylinder:
        return _cylinder();
      case Wb3dObjectType.cone:
        return _cone();
      case Wb3dObjectType.sphere:
        return _sphere();
      case Wb3dObjectType.prism:
        return _prism();
      case Wb3dObjectType.pyramid:
        return _pyramid();
      case Wb3dObjectType.torus:
        return _torus();
    }
  }

  static Wb3dMesh _box() {
    final List<Wb3dV3> vertices = <Wb3dV3>[
      for (int i = 0; i < 8; i++)
        Wb3dV3(
          (i & 1) == 0 ? -1 : 1,
          (i & 2) == 0 ? -1 : 1,
          (i & 4) == 0 ? -1 : 1,
        ),
    ];
    return Wb3dMesh(
      vertices: vertices,
      faces: const <List<int>>[
        <int>[0, 1, 3, 2],
        <int>[4, 6, 7, 5],
        <int>[0, 2, 6, 4],
        <int>[1, 5, 7, 3],
        <int>[0, 4, 5, 1],
        <int>[2, 3, 7, 6],
      ],
    );
  }

  static Wb3dMesh _pyramid() {
    const double b = 0.95;
    final List<Wb3dV3> vertices = <Wb3dV3>[
      const Wb3dV3(-b, -1, -b),
      const Wb3dV3(b, -1, -b),
      const Wb3dV3(b, -1, b),
      const Wb3dV3(-b, -1, b),
      const Wb3dV3(0, 1.05, 0),
    ];
    return Wb3dMesh(
      vertices: vertices,
      faces: const <List<int>>[
        <int>[0, 1, 2, 3],
        <int>[0, 1, 4],
        <int>[1, 2, 4],
        <int>[2, 3, 4],
        <int>[3, 0, 4],
      ],
    );
  }

  static Wb3dMesh _prism() {
    final List<Wb3dV3> vertices = <Wb3dV3>[];
    for (int ring = 0; ring < 2; ring++) {
      final double y = ring == 0 ? -1 : 1;
      for (int i = 0; i < 3; i++) {
        final double angle = math.pi / 2 + i * 2 * math.pi / 3;
        vertices.add(Wb3dV3(math.cos(angle), y, math.sin(angle)));
      }
    }
    return Wb3dMesh(
      vertices: vertices,
      faces: const <List<int>>[
        <int>[0, 1, 2],
        <int>[3, 4, 5],
        <int>[0, 1, 4, 3],
        <int>[1, 2, 5, 4],
        <int>[2, 0, 3, 5],
      ],
    );
  }

  static Wb3dMesh _cylinder() {
    const int segments = 18;
    const double half = 0.9;
    final List<Wb3dV3> vertices = <Wb3dV3>[];
    for (int ring = 0; ring < 2; ring++) {
      final double y = ring == 0 ? -half : half;
      for (int i = 0; i < segments; i++) {
        final double angle = 2 * math.pi * i / segments;
        vertices.add(Wb3dV3(math.cos(angle), y, math.sin(angle)));
      }
    }
    final List<List<int>> faces = <List<int>>[];
    for (int i = 0; i < segments; i++) {
      final int j = (i + 1) % segments;
      faces.add(<int>[i, j, segments + j, segments + i]);
    }
    faces.add(<int>[for (int i = segments - 1; i >= 0; i--) i]);
    faces.add(<int>[for (int i = 0; i < segments; i++) segments + i]);
    return Wb3dMesh(vertices: vertices, faces: faces);
  }

  static Wb3dMesh _cone() {
    const int segments = 18;
    final List<Wb3dV3> vertices = <Wb3dV3>[
      for (int i = 0; i < segments; i++)
        Wb3dV3(
          math.cos(2 * math.pi * i / segments),
          -0.9,
          math.sin(2 * math.pi * i / segments),
        ),
      const Wb3dV3(0, 1.05, 0),
    ];
    final List<List<int>> faces = <List<int>>[];
    for (int i = 0; i < segments; i++) {
      final int j = (i + 1) % segments;
      faces.add(<int>[i, j, segments]);
    }
    faces.add(<int>[for (int i = segments - 1; i >= 0; i--) i]);
    return Wb3dMesh(vertices: vertices, faces: faces);
  }

  static Wb3dMesh _sphere() {
    const int stacks = 8;
    const int slices = 16;
    final List<Wb3dV3> vertices = <Wb3dV3>[
      const Wb3dV3(0, 1, 0),
      const Wb3dV3(0, -1, 0),
    ];
    for (int ring = 1; ring < stacks; ring++) {
      final double theta = math.pi * ring / stacks;
      final double y = math.cos(theta);
      final double radius = math.sin(theta);
      for (int j = 0; j < slices; j++) {
        final double angle = 2 * math.pi * j / slices;
        vertices.add(Wb3dV3(radius * math.cos(angle), y, radius * math.sin(angle)));
      }
    }
    int index(int ring, int j) => 2 + (ring - 1) * slices + j % slices;
    final List<List<int>> faces = <List<int>>[];
    for (int j = 0; j < slices; j++) {
      faces.add(<int>[0, index(1, j), index(1, j + 1)]);
      faces.add(<int>[1, index(stacks - 1, j + 1), index(stacks - 1, j)]);
    }
    for (int ring = 1; ring < stacks - 1; ring++) {
      for (int j = 0; j < slices; j++) {
        faces.add(<int>[
          index(ring, j),
          index(ring, j + 1),
          index(ring + 1, j + 1),
          index(ring + 1, j),
        ]);
      }
    }
    return Wb3dMesh(vertices: vertices, faces: faces);
  }

  static Wb3dMesh _torus() {
    const int segmentsU = 18;
    const int segmentsV = 10;
    const double bigR = 0.72;
    const double smallR = 0.3;
    final List<Wb3dV3> vertices = <Wb3dV3>[];
    for (int i = 0; i < segmentsU; i++) {
      final double u = 2 * math.pi * i / segmentsU;
      for (int j = 0; j < segmentsV; j++) {
        final double v = 2 * math.pi * j / segmentsV;
        final double radial = bigR + smallR * math.cos(v);
        vertices.add(
          Wb3dV3(radial * math.cos(u), smallR * math.sin(v), radial * math.sin(u)),
        );
      }
    }
    int index(int i, int j) => (i % segmentsU) * segmentsV + j % segmentsV;
    final List<List<int>> faces = <List<int>>[];
    for (int i = 0; i < segmentsU; i++) {
      for (int j = 0; j < segmentsV; j++) {
        faces.add(<int>[
          index(i, j),
          index(i, j + 1),
          index(i + 1, j + 1),
          index(i + 1, j),
        ]);
      }
    }
    return Wb3dMesh(vertices: vertices, faces: faces, flipNormalsToOutward: false);
  }
}

// ---------------------------------------------------------------------------
// 投影结果
// ---------------------------------------------------------------------------

/// 投影后的单个面。
///
/// [points] 为该面的屏幕空间顶点（相对投影画布左上角）；[faceIndex] 为
/// 网格 [Wb3dMesh.faces] 中的原始索引（表面涂色按此索引持久化）；
/// [depth] 为面心视图空间 Z（越大越近）。
class Wb3dProjectedFace {
  /// 创建投影面。
  Wb3dProjectedFace({
    required this.points,
    required this.faceIndex,
    required this.depth,
    required this.fill,
    required this.stroke,
  });

  /// 屏幕空间顶点（≥ 3 个）。
  final List<Offset> points;

  /// 网格面索引（`Wb3dMesh.faces` 下标）。
  final int faceIndex;

  /// 面心深度（视图空间 Z，越大越靠近相机）。
  final double depth;

  /// 填充色（含明暗 / 玻璃透明度 / 用户涂色处理）。
  final Color fill;

  /// 描边色（比填充更暗一档）。
  final Color stroke;

  Path? _lazyPath;

  /// 闭合路径（惰性构建并缓存）。
  Path get path {
    final Path? cached = _lazyPath;
    if (cached != null) {
      return cached;
    }
    final Path built = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      built.lineTo(points[i].dx, points[i].dy);
    }
    built.close();
    _lazyPath = built;
    return built;
  }
}

/// 一次投影的完整结果。
class Wb3dProjection {
  /// 创建投影结果。
  Wb3dProjection({required this.vertices, required this.faces});

  /// 全部顶点投影坐标（阴影绘制等使用；索引与网格顶点一一对应）。
  final List<Offset> vertices;

  /// 可见面（已按 depth 升序排序：远的在前，直接顺序绘制即可）。
  final List<Wb3dProjectedFace> faces;
}

// ---------------------------------------------------------------------------
// 投影器
// ---------------------------------------------------------------------------

/// 3D 正交投影器（纯函数；复刻原 `Wb3dMeshPainter.paint` 的全部数学）。
abstract final class Wb3dProjector {
  /// 相机偏航（弧度，固定俯视角度）。
  static const double cameraYaw = 0.58;

  /// 相机俯仰（弧度）。
  static const double cameraPitch = 0.38;

  /// 平行光方向（视图空间，朝向光源）。
  static const Wb3dV3 directionalLight = Wb3dV3(-0.36, 0.62, 0.7);

  /// 点光源位置（视图空间）。
  static const Wb3dV3 pointLight = Wb3dV3(-1.7, 2.5, 2.2);

  /// 聚光灯位置（视图空间，偏顶部）。
  static const Wb3dV3 spotLight = Wb3dV3(1.9, 3.0, 1.1);

  /// 角度 → 弧度。
  static double degreesToRadians(double degree) => degree * math.pi / 180;

  /// 3D 元素内容适配系数（与 `professional_painter.dart` 的 fit 公式一致）：
  /// 元素矩形内缩 16px 后按 300×300 基准缩放，钳制 0.05~4。
  ///
  /// 直绘半透明预览（缩放绘制）与表面涂色（世界 → 内容坐标逆变换）共用。
  static double contentFit(Size elementSize) {
    return math
        .min(
          (elementSize.width - 32) / 300,
          (elementSize.height - 32) / 300,
        )
        .clamp(0.05, 4)
        .toDouble();
  }

  /// 把 [scene] 投影到 [size] 画布（正交投影 + 背面剔除 + Lambert 明暗）。
  ///
  /// - 玻璃材质保留背面（半透明观感）；金属 / 自发光按原口径处理明暗；
  /// - 尺寸任一边 < 4 时返回空投影（调用方跳过绘制）；
  /// - [scene.faceColors] 中登记的面直接使用用户涂色平涂（不叠加明暗 /
  ///   玻璃透明度），描边取该色与黑色的 22% 混合。
  static Wb3dProjection project({
    required Wb3dScene scene,
    required Size size,
    required WbThemeColors colors,
  }) {
    if (size.width < 4 || size.height < 4) {
      return Wb3dProjection(
        vertices: const <Offset>[],
        faces: const <Wb3dProjectedFace>[],
      );
    }
    final Wb3dMesh mesh = Wb3dMeshFactory.build(scene.objectType);
    final Wb3dTransform t = scene.transform;
    final double rz = degreesToRadians(t.rotationZ);
    final double ry = degreesToRadians(t.rotationY);
    final double rx = degreesToRadians(t.rotationX);

    final List<Wb3dV3> view = <Wb3dV3>[];
    for (final Wb3dV3 vertex in mesh.vertices) {
      Wb3dV3 p = vertex * t.scale;
      p = Wb3dV3(p.x, p.y + t.lift, p.z);
      p = p.rotateZ(rz).rotateY(ry).rotateX(rx);
      p = p.rotateY(cameraYaw).rotateX(cameraPitch);
      view.add(p);
    }
    final Wb3dV3 meshCenter = _average(view);
    double extent = 0.001;
    for (final Wb3dV3 p in view) {
      extent = math.max(extent, math.max(p.x.abs(), p.y.abs()));
    }
    final double k = math.min(size.width, size.height) * 0.34 / extent;
    final Offset center = Offset(size.width / 2, size.height / 2);
    final List<Offset> projected = <Offset>[
      for (final Wb3dV3 p in view) center + Offset(p.x * k, -p.y * k),
    ];

    final bool glass = scene.material == Wb3dMaterial.glass;
    final List<Wb3dProjectedFace> faces = <Wb3dProjectedFace>[];
    for (int fi = 0; fi < mesh.faces.length; fi++) {
      final List<int> face = mesh.faces[fi];
      if (face.length < 3) {
        continue;
      }
      final List<Wb3dV3> pts = <Wb3dV3>[for (final int i in face) view[i]];
      final Wb3dV3 centroid = _average(pts);
      Wb3dV3 normal = (pts[1] - pts[0]).cross(pts[2] - pts[0]).normalized();
      if (mesh.flipNormalsToOutward && normal.dot(centroid - meshCenter) < 0) {
        normal = normal * -1;
      }
      if (!glass && normal.z <= 0.001) {
        continue;
      }
      final Wb3dV3 toLight = switch (scene.lightType) {
        Wb3dLightType.directional => directionalLight.normalized(),
        Wb3dLightType.point => (pointLight - centroid).normalized(),
        Wb3dLightType.spot => (spotLight - centroid).normalized(),
      };
      final double lambert = math.max(0, normal.dot(toLight));
      double shade =
          scene.ambient + (1 - scene.ambient) * scene.lightIntensity * lambert;
      if (scene.material == Wb3dMaterial.emissive) {
        shade = 1;
      } else if (scene.material == Wb3dMaterial.metal) {
        shade = 0.16 + 0.84 * math.pow(shade.clamp(0, 1), 1.7).toDouble();
      }
      final Color fill;
      final Color stroke;
      final Color? painted = scene.faceColors[fi];
      if (painted != null) {
        // 用户涂色：平涂（保持所涂色相，不叠加明暗与玻璃透明度）。
        fill = painted;
        stroke = Color.lerp(painted, const Color(0xFF000000), 0.22)!;
      } else {
        fill = _shade(scene.color, shade, glass ? 0.52 : 1);
        stroke = _shade(scene.color, shade * 0.78, glass ? 0.7 : 1);
      }
      faces.add(
        Wb3dProjectedFace(
          points: <Offset>[for (final int i in face) projected[i]],
          faceIndex: fi,
          depth: centroid.z,
          fill: fill,
          stroke: stroke,
        ),
      );
    }
    faces.sort(
      (Wb3dProjectedFace a, Wb3dProjectedFace b) => a.depth.compareTo(b.depth),
    );

    return Wb3dProjection(vertices: projected, faces: faces);
  }

  /// 命中测试：返回包含 [localPoint] 的最近面索引（按 depth 降序近 → 远
  /// 取第一个 `path.contains` 命中）；未命中返回 null。
  static int? hitTest(List<Wb3dProjectedFace> faces, Offset localPoint) {
    final List<Wb3dProjectedFace> ordered = List<Wb3dProjectedFace>.of(faces)
      ..sort(
        (Wb3dProjectedFace a, Wb3dProjectedFace b) => b.depth.compareTo(a.depth),
      );
    for (final Wb3dProjectedFace face in ordered) {
      if (face.path.contains(localPoint)) {
        return face.faceIndex;
      }
    }
    return null;
  }

  static Wb3dV3 _average(List<Wb3dV3> points) {
    double x = 0;
    double y = 0;
    double z = 0;
    for (final Wb3dV3 p in points) {
      x += p.x;
      y += p.y;
      z += p.z;
    }
    final double n = math.max(points.length, 1).toDouble();
    return Wb3dV3(x / n, y / n, z / n);
  }

  /// 基础色 × 明暗系数（保持色相，调整亮度与透明度）。
  static Color _shade(Color base, double shade, double alpha) {
    final int argb = base.toARGB32();
    int channel(int shift) {
      final int raw = (argb >> shift) & 0xFF;
      return (raw * shade).round().clamp(0, 255);
    }

    return Color.fromARGB(
      (alpha * 255).round().clamp(0, 255),
      channel(16),
      channel(8),
      channel(0),
    );
  }
}
