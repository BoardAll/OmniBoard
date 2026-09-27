/// 3D 投影公共模块测试（纯函数：投影 / 涂色覆盖 / 命中测试）。
///
/// 口径与 `render3d_editor.dart` 的编辑器预览一致：正交投影 + 背面剔除 +
/// 画家算法（depth 升序）+ Lambert 明暗；不含 golden 断言。
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/wb3d_projection.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render3d_editor.dart';
import 'package:whiteboard_theme/theme.dart';

void main() {
  group('Wb3dProjector.project', () {
    test('七类对象均可投影：顶点 / 面非空、面索引合法、depth 升序', () {
      for (final Wb3dObjectType type in Wb3dObjectType.values) {
        final Wb3dProjection projection = Wb3dProjector.project(
          scene: Wb3dScene(objectType: type),
          size: const Size(300, 300),
          colors: WbThemeColors.lightDefaults,
        );
        expect(projection.vertices, isNotEmpty, reason: '${type.id} 顶点');
        expect(projection.faces, isNotEmpty, reason: '${type.id} 可见面非空');
        final Wb3dMesh mesh = Wb3dMeshFactory.build(type);
        for (final Wb3dProjectedFace face in projection.faces) {
          expect(face.points.length, greaterThanOrEqualTo(3));
          expect(
            face.faceIndex,
            inInclusiveRange(0, mesh.faces.length - 1),
            reason: '${type.id} 面索引越界',
          );
        }
        for (int i = 1; i < projection.faces.length; i++) {
          expect(
            projection.faces[i].depth,
            greaterThanOrEqualTo(projection.faces[i - 1].depth),
            reason: '${type.id} 面应按 depth 升序（远 → 近）',
          );
        }
      }
    });

    test('过小尺寸返回空投影', () {
      final Wb3dProjection projection = Wb3dProjector.project(
        scene: const Wb3dScene(),
        size: const Size(2, 2),
        colors: WbThemeColors.lightDefaults,
      );
      expect(projection.vertices, isEmpty);
      expect(projection.faces, isEmpty);
    });

    test('faceColors 覆盖：所涂面平涂为所涂色，其余面不受影响', () {
      const Wb3dScene base = Wb3dScene();
      final Wb3dProjection plain = Wb3dProjector.project(
        scene: base,
        size: const Size(300, 300),
        colors: WbThemeColors.lightDefaults,
      );
      final int target = plain.faces.first.faceIndex;
      const Color red = Color(0xFFFF0000);
      final Wb3dProjection painted = Wb3dProjector.project(
        scene: base.copyWith(faceColors: <int, Color>{target: red}),
        size: const Size(300, 300),
        colors: WbThemeColors.lightDefaults,
      );
      final Wb3dProjectedFace hit = painted.faces.firstWhere(
        (Wb3dProjectedFace face) => face.faceIndex == target,
      );
      expect(hit.fill, red);
      for (final Wb3dProjectedFace face in painted.faces) {
        if (face.faceIndex != target) {
          expect(face.fill, isNot(red));
        }
      }
    });

    test('contentFit 与 professional_painter 的 fit 公式一致（min 方向 + 钳制）',
        () {
      // 两边相等：fit = (300 - 32) / 300。
      expect(
        Wb3dProjector.contentFit(const Size(300, 300)),
        closeTo(268 / 300, 1e-12),
      );
      // 取小的一边（高度方向）：fit = (600 - 32) / 300。
      expect(
        Wb3dProjector.contentFit(const Size(800, 600)),
        closeTo(568 / 300, 1e-12),
      );
      // 超过上界钳制 4；低于下界钳制 0.05。
      expect(Wb3dProjector.contentFit(const Size(2400, 2400)), 4.0);
      expect(Wb3dProjector.contentFit(const Size(30, 30)), 0.05);
    });
  });

  group('Wb3dProjector.hitTest', () {
    test('box 中心命中；远处不命中', () {
      final Wb3dProjection projection = Wb3dProjector.project(
        scene: const Wb3dScene(),
        size: const Size(300, 300),
        colors: WbThemeColors.lightDefaults,
      );
      expect(
        Wb3dProjector.hitTest(projection.faces, const Offset(150, 150)),
        isNotNull,
      );
      expect(
        Wb3dProjector.hitTest(projection.faces, const Offset(1000, 1000)),
        isNull,
      );
    });
  });
}
