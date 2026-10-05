/// 3D 对象上下文编辑器（Wave 3.6）。
///
/// 依据《渲染引擎设计》§7.5（3D 渲染）与《白板软件设计文档》§6「3D 工具栏」实现：
/// - **对象类型**：立方体 / 圆柱 / 圆锥 / 球体 / 三棱柱 / 棱锥 / 圆环
///   （[Wb3dObjectType]，与引擎 §7.5 支持列表一致）；
/// - **材质与颜色**：标准 / 金属 / 玻璃 / 自发光（[Wb3dMaterial]），颜色取自
///   [WbContextPalette.swatches]（与画布元素同色板口径）；
/// - **光照**：平行光 / 点光源 / 聚光灯 + 环境光强度 + 主光强度 + 线框开关；
/// - **变换**：旋转 X/Y/Z（角度制）、均匀缩放、高度抬升。
///
/// 预览区为内置迷你软件渲染器（[Wb3dMeshPainter]）：正交投影 + 背面剔除 +
/// 画家算法排序 + Lambert 明暗，纯 Dart 实现、无第三方依赖；真实 3D 渲染由
/// FFI 引擎承载，本组件负责参数面板与演示级预览。
///
/// 投影数学（网格构建 / 正交投影 / 明暗 / 涂色覆盖）已平移至
/// [Wb3dProjector]（`../canvas/wb3d_projection.dart`），画布直绘预览与表面
/// 涂色命中复用同一模块；本文件只保留场景模型与画布绘制。
///
/// 组件自包含（无 Provider / FFI 依赖），通过 [WbRender3dEditor.onChanged]
/// 上报最新场景。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../canvas/wb3d_projection.dart';
import 'context_editor_shell.dart';

// ---------------------------------------------------------------------------
// 枚举与不可变模型
// ---------------------------------------------------------------------------

/// 3D 对象类型（对齐《渲染引擎设计》§7.5 的基础体 / 旋转体）。
enum Wb3dObjectType {
  /// 立方体。
  box('box', '立方体'),

  /// 圆柱。
  cylinder('cylinder', '圆柱'),

  /// 圆锥。
  cone('cone', '圆锥'),

  /// 球体。
  sphere('sphere', '球体'),

  /// 三棱柱。
  prism('prism', '三棱柱'),

  /// 棱锥。
  pyramid('pyramid', '棱锥'),

  /// 圆环。
  torus('torus', '圆环');

  const Wb3dObjectType(this.id, this.label);

  /// 稳定 id（跨端序列化用）。
  final String id;

  /// 中文显示名。
  final String label;
}

/// 材质（§7.5 材质通道的演示口径）。
enum Wb3dMaterial {
  /// 标准（漫反射）。
  standard('standard', '标准'),

  /// 金属（高对比度）。
  metal('metal', '金属'),

  /// 玻璃（半透明）。
  glass('glass', '玻璃'),

  /// 自发光（不参与明暗）。
  emissive('emissive', '自发光');

  const Wb3dMaterial(this.id, this.label);

  /// 稳定 id。
  final String id;

  /// 中文显示名。
  final String label;
}

/// 光源类型。
enum Wb3dLightType {
  /// 平行光。
  directional('directional', '平行光'),

  /// 点光源。
  point('point', '点光源'),

  /// 聚光灯。
  spot('spot', '聚光灯');

  const Wb3dLightType(this.id, this.label);

  /// 稳定 id。
  final String id;

  /// 中文显示名。
  final String label;
}

/// 对象变换（角度制旋转 / 均匀缩放 / 高度抬升）。
@immutable
class Wb3dTransform {
  /// 创建变换。
  const Wb3dTransform({
    this.rotationX = 0,
    this.rotationY = 0,
    this.rotationZ = 0,
    this.scale = 1,
    this.lift = 0,
  });

  /// 绕 X 轴旋转（度）。
  final double rotationX;

  /// 绕 Y 轴旋转（度）。
  final double rotationY;

  /// 绕 Z 轴旋转（度）。
  final double rotationZ;

  /// 均匀缩放。
  final double scale;

  /// 高度抬升（世界单位，作用于 Y 轴）。
  final double lift;

  /// 复制并覆盖字段。
  Wb3dTransform copyWith({
    double? rotationX,
    double? rotationY,
    double? rotationZ,
    double? scale,
    double? lift,
  }) {
    return Wb3dTransform(
      rotationX: rotationX ?? this.rotationX,
      rotationY: rotationY ?? this.rotationY,
      rotationZ: rotationZ ?? this.rotationZ,
      scale: scale ?? this.scale,
      lift: lift ?? this.lift,
    );
  }
}

/// 3D 场景（不可变）：对象 / 材质 / 颜色 / 变换 / 光照 / 线框 / 表面涂色。
@immutable
class Wb3dScene {
  /// 创建场景。
  const Wb3dScene({
    this.objectType = Wb3dObjectType.box,
    this.material = Wb3dMaterial.standard,
    this.color = WbContextPalette.defaultElementColor,
    this.transform = const Wb3dTransform(),
    this.lightType = Wb3dLightType.directional,
    this.ambient = 0.32,
    this.lightIntensity = 0.9,
    this.wireframe = false,
    this.faceColors = const <int, Color>{},
  });

  /// 对象类型。
  final Wb3dObjectType objectType;

  /// 材质。
  final Wb3dMaterial material;

  /// 基础颜色。
  final Color color;

  /// 变换参数。
  final Wb3dTransform transform;

  /// 光源类型。
  final Wb3dLightType lightType;

  /// 环境光强度（0..0.6）。
  final double ambient;

  /// 主光强度（0..1.4）。
  final double lightIntensity;

  /// 是否线框显示。
  final bool wireframe;

  /// 表面涂色（faceIndex → 颜色；投影时该面平涂覆盖，见 [Wb3dProjector]）。
  final Map<int, Color> faceColors;

  /// 复制并覆盖字段。
  Wb3dScene copyWith({
    Wb3dObjectType? objectType,
    Wb3dMaterial? material,
    Color? color,
    Wb3dTransform? transform,
    Wb3dLightType? lightType,
    double? ambient,
    double? lightIntensity,
    bool? wireframe,
    Map<int, Color>? faceColors,
  }) {
    return Wb3dScene(
      objectType: objectType ?? this.objectType,
      material: material ?? this.material,
      color: color ?? this.color,
      transform: transform ?? this.transform,
      lightType: lightType ?? this.lightType,
      ambient: ambient ?? this.ambient,
      lightIntensity: lightIntensity ?? this.lightIntensity,
      wireframe: wireframe ?? this.wireframe,
      faceColors: faceColors ?? this.faceColors,
    );
  }
}

// ---------------------------------------------------------------------------
// 画布绘制（投影数学见 `wb3d_projection.dart`）
// ---------------------------------------------------------------------------

/// 3D 预览绘制器（正交投影 + 背面剔除 + 画家算法 + Lambert 明暗）。
///
/// 投影与明暗计算在 [Wb3dProjector]；本类只做画布绘制（阴影 + 逐面填充 /
/// 描边），保持既有视觉口径（线框时描边用 [Wb3dScene.color]）。
class Wb3dMeshPainter extends CustomPainter {
  /// 创建绘制器。
  Wb3dMeshPainter({required this.scene, required this.colors});

  /// 场景参数。
  final Wb3dScene scene;

  /// 主题颜色。
  final WbThemeColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final Wb3dProjection projection = Wb3dProjector.project(
      scene: scene,
      size: size,
      colors: colors,
    );
    if (projection.vertices.isEmpty) {
      return;
    }
    _paintShadow(canvas, projection.vertices);

    for (final Wb3dProjectedFace face in projection.faces) {
      final Path path = face.path;
      if (!scene.wireframe) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.fill
            ..color = face.fill
            ..isAntiAlias = true,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = scene.wireframe ? 1.1 : 0.7
          ..strokeJoin = StrokeJoin.round
          ..color = scene.wireframe ? scene.color : face.stroke
          ..isAntiAlias = true,
      );
    }
  }

  void _paintShadow(Canvas canvas, List<Offset> projected) {
    if (scene.wireframe || projected.isEmpty) {
      return;
    }
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (final Offset p in projected) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
    final double width = math.max(maxX - minX, 8) * 0.82;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset((minX + maxX) / 2, maxY + 7),
        width: width,
        height: width * 0.2,
      ),
      Paint()..color = const Color(0x14101A2E),
    );
  }

  @override
  bool shouldRepaint(Wb3dMeshPainter oldDelegate) =>
      oldDelegate.scene != scene || oldDelegate.colors != colors;
}

// ---------------------------------------------------------------------------
// 编辑器组件
// ---------------------------------------------------------------------------

/// 3D 对象上下文编辑器。
class WbRender3dEditor extends StatefulWidget {
  /// 创建编辑器。
  const WbRender3dEditor({
    super.key,
    this.initialScene,
    this.onChanged,
    this.onClose,
    this.width = WbContextMetrics.defaultWidth,
  });

  /// 初始场景（null 使用默认场景）。
  final Wb3dScene? initialScene;

  /// 场景变更回调。
  final ValueChanged<Wb3dScene>? onChanged;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 面板宽度。
  final double width;

  @override
  State<WbRender3dEditor> createState() => _WbRender3dEditorState();
}

class _WbRender3dEditorState extends State<WbRender3dEditor> {
  late Wb3dScene _scene;

  @override
  void initState() {
    super.initState();
    _scene = widget.initialScene ?? const Wb3dScene();
  }

  void _apply(Wb3dScene next) {
    setState(() => _scene = next);
    widget.onChanged?.call(next);
  }

  void _reset() => _apply(const Wb3dScene());

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final String subtitle = '${_scene.objectType.label} · ${_scene.material.label} · '
        '${_scene.lightType.label}${_scene.wireframe ? ' · 线框' : ''}';
    return WbContextEditorShell(
      title: '3D 对象编辑器',
      subtitle: subtitle,
      icon: LinearIcons.cube,
      onClose: widget.onClose,
      width: widget.width,
      actions: <Widget>[
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-3d-reset'),
          icon: LinearIcons.refresh,
          tooltip: '重置场景参数',
          onTap: _reset,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(WbContextMetrics.controlRadius),
                child: Container(
                  key: const ValueKey<String>('wb-ctx-3d-preview'),
                  decoration: BoxDecoration(
                    color: colors.canvas,
                    border: Border.all(color: colors.cardBorder),
                    borderRadius:
                        BorderRadius.circular(WbContextMetrics.controlRadius),
                  ),
                  child: CustomPaint(
                    painter: Wb3dMeshPainter(scene: _scene, colors: colors),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const WbEditorSectionTitle(title: '对象类型'),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final Wb3dObjectType type in Wb3dObjectType.values)
                        WbEditorChip(
                          key: ValueKey<String>('wb-ctx-3d-type-${type.id}'),
                          label: type.label,
                          dense: true,
                          selected: _scene.objectType == type,
                          onTap: () => _apply(_scene.copyWith(objectType: type)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const WbEditorSectionTitle(title: '材质与颜色'),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final Wb3dMaterial material in Wb3dMaterial.values)
                        WbEditorChip(
                          key: ValueKey<String>(
                            'wb-ctx-3d-material-${material.id}',
                          ),
                          label: material.label,
                          dense: true,
                          selected: _scene.material == material,
                          onTap: () =>
                              _apply(_scene.copyWith(material: material)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  WbEditorColorRow(
                    colors: WbContextPalette.swatches,
                    selected: _scene.color,
                    keyPrefix: 'wb-ctx-3d-color',
                    swatchSize: 16,
                    onSelect: (Color color) =>
                        _apply(_scene.copyWith(color: color)),
                  ),
                  const SizedBox(height: 8),
                  const WbEditorSectionTitle(title: '光照'),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final Wb3dLightType light in Wb3dLightType.values)
                        WbEditorChip(
                          key: ValueKey<String>('wb-ctx-3d-light-${light.id}'),
                          label: light.label,
                          dense: true,
                          icon: LinearIcons.light,
                          selected: _scene.lightType == light,
                          onTap: () => _apply(_scene.copyWith(lightType: light)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  WbEditorSlider(
                    key: const ValueKey<String>('wb-ctx-3d-ambient'),
                    label: '环境光',
                    value: _scene.ambient,
                    min: 0,
                    max: 0.6,
                    divisions: 12,
                    onChanged: (double value) =>
                        _apply(_scene.copyWith(ambient: value)),
                  ),
                  WbEditorSlider(
                    key: const ValueKey<String>('wb-ctx-3d-light-intensity'),
                    label: '主光强度',
                    value: _scene.lightIntensity,
                    min: 0,
                    max: 1.4,
                    divisions: 14,
                    onChanged: (double value) =>
                        _apply(_scene.copyWith(lightIntensity: value)),
                  ),
                  WbEditorSwitchRow(
                    key: const ValueKey<String>('wb-ctx-3d-wireframe'),
                    label: '线框显示',
                    value: _scene.wireframe,
                    onChanged: (bool value) =>
                        _apply(_scene.copyWith(wireframe: value)),
                  ),
                  const SizedBox(height: 8),
                  const WbEditorSectionTitle(title: '变换'),
                  WbEditorSlider(
                    key: const ValueKey<String>('wb-ctx-3d-rotate-x'),
                    label: '旋转 X°',
                    value: _scene.transform.rotationX,
                    min: -180,
                    max: 180,
                    divisions: 72,
                    valueLabel: _scene.transform.rotationX.toStringAsFixed(0),
                    onChanged: (double value) => _apply(
                      _scene.copyWith(
                        transform: _scene.transform.copyWith(rotationX: value),
                      ),
                    ),
                  ),
                  WbEditorSlider(
                    key: const ValueKey<String>('wb-ctx-3d-rotate-y'),
                    label: '旋转 Y°',
                    value: _scene.transform.rotationY,
                    min: -180,
                    max: 180,
                    divisions: 72,
                    valueLabel: _scene.transform.rotationY.toStringAsFixed(0),
                    onChanged: (double value) => _apply(
                      _scene.copyWith(
                        transform: _scene.transform.copyWith(rotationY: value),
                      ),
                    ),
                  ),
                  WbEditorSlider(
                    key: const ValueKey<String>('wb-ctx-3d-rotate-z'),
                    label: '旋转 Z°',
                    value: _scene.transform.rotationZ,
                    min: -180,
                    max: 180,
                    divisions: 72,
                    valueLabel: _scene.transform.rotationZ.toStringAsFixed(0),
                    onChanged: (double value) => _apply(
                      _scene.copyWith(
                        transform: _scene.transform.copyWith(rotationZ: value),
                      ),
                    ),
                  ),
                  WbEditorSlider(
                    key: const ValueKey<String>('wb-ctx-3d-scale'),
                    label: '缩放',
                    value: _scene.transform.scale,
                    min: 0.4,
                    max: 2,
                    divisions: 16,
                    onChanged: (double value) => _apply(
                      _scene.copyWith(
                        transform: _scene.transform.copyWith(scale: value),
                      ),
                    ),
                  ),
                  WbEditorSlider(
                    key: const ValueKey<String>('wb-ctx-3d-lift'),
                    label: '高度',
                    value: _scene.transform.lift,
                    min: -0.8,
                    max: 0.8,
                    divisions: 16,
                    onChanged: (double value) => _apply(
                      _scene.copyWith(
                        transform: _scene.transform.copyWith(lift: value),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const WbEditorHint(
                    '预览为内置软件渲染演示；材质 / 光照 / 变换参数与引擎 §7.5 '
                    '字段一一对应，保存后由 FFI 引擎按真实管线渲染。',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
