/// 圆盘工具映射测试（问题 4 回归）：
/// - `RadialCatalog` 全部绘图工具 id 被 [WbRadialToolMapping] 覆盖（无死角）；
/// - 映射表不含目录外 id（防拼写漂移）；
/// - 关键映射口径：形状子类型 / 连线工具 / 上下文编辑器 / 降级提示 / 粘贴；
/// - 底部工具栏 9 类工具 id 与 `WbCanvasTool.id` 一致且均可解析。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/context_editors/quick_create.dart';
import 'package:whiteboard_desktop/widgets/radial/radial_models.dart';
import 'package:whiteboard_desktop/widgets/radial/radial_tool_mapping.dart';

/// 圆盘目录全部工具 id（含动作入口）。
Set<String> _allCatalogIds() {
  return <String>{
    for (final RadialTool tool in RadialCatalog.inner) tool.id,
    for (final RadialGroup group in RadialCatalog.groups)
      for (final RadialTool tool in group.tools) tool.id,
  };
}

/// 圆盘目录全部绘图工具 id（排除动作入口）。
Set<String> _drawingToolIds() {
  return <String>{
    for (final RadialTool tool in RadialCatalog.inner)
      if (!tool.isAction) tool.id,
    for (final RadialGroup group in RadialCatalog.groups)
      for (final RadialTool tool in group.tools)
        if (!tool.isAction) tool.id,
  };
}

void main() {
  group('映射表完整性', () {
    test('RadialCatalog 全部绘图工具 id 均已登记', () {
      final Set<String> ids = _drawingToolIds();
      expect(ids.length, greaterThanOrEqualTo(30), reason: '目录绘图工具应不少于 30 个');
      for (final String id in ids) {
        expect(
          WbRadialToolMapping.resolve(id),
          isNotNull,
          reason: '圆盘工具 "$id" 未登记映射',
        );
      }
    });

    test('映射表不含圆盘目录外 id（防拼写漂移）', () {
      final Set<String> ids = _allCatalogIds();
      for (final String id in WbRadialToolMapping.knownToolIds) {
        expect(ids, contains(id), reason: '映射 id "$id" 不在圆盘目录');
      }
    });

    test('动作入口与未知 id 不进入工具通道（resolve 返回 null）', () {
      expect(WbRadialToolMapping.resolve(kRadialMoreId), isNull);
      expect(WbRadialToolMapping.resolve(kRadialAiAssistantId), isNull);
      expect(WbRadialToolMapping.resolve(kRadialSettingsId), isNull);
      expect(WbRadialToolMapping.resolve('unknown.tool'), isNull);
    });
  });

  group('映射口径', () {
    test('选择 / 手 / 框选 / 套索：全部落在选择（框选内建）', () {
      expect(WbRadialToolMapping.resolve('select')!.tool, WbCanvasTool.select);
      expect(WbRadialToolMapping.resolve('hand')!.tool, WbCanvasTool.hand);
      expect(WbRadialToolMapping.resolve('marquee')!.tool, WbCanvasTool.select);
      expect(WbRadialToolMapping.resolve('lasso')!.tool, WbCanvasTool.select);
    });

    test('形状：矩形 / 圆 / 菱形 / 平行四边形 → shape + 子类型', () {
      expect(WbRadialToolMapping.resolve('rect')!.tool, WbCanvasTool.shape);
      expect(
        WbRadialToolMapping.resolve('rect')!.shapeKind,
        WbShapeKind.rect,
      );
      expect(WbRadialToolMapping.resolve('circle')!.tool, WbCanvasTool.shape);
      expect(
        WbRadialToolMapping.resolve('circle')!.shapeKind,
        WbShapeKind.ellipse,
      );
      expect(
        WbRadialToolMapping.resolve('diamond')!.shapeKind,
        WbShapeKind.diamond,
      );
      expect(
        WbRadialToolMapping.resolve('parallelogram')!.shapeKind,
        WbShapeKind.parallelogram,
      );
      expect(
        WbRadialToolMapping.resolve('parallelogram')!.tool,
        WbCanvasTool.shape,
      );
    });

    test('连线：箭头 / 连线 → 连线工具（拖拽画直线）', () {
      expect(
        WbRadialToolMapping.resolve('arrow')!.tool,
        WbCanvasTool.connector,
      );
      expect(
        WbRadialToolMapping.resolve('connector')!.tool,
        WbCanvasTool.connector,
      );
    });

    test('文本类：标题 / 列表 / 引用以文本工具承载', () {
      expect(WbRadialToolMapping.resolve('heading')!.tool, WbCanvasTool.text);
      expect(WbRadialToolMapping.resolve('list')!.tool, WbCanvasTool.text);
      expect(WbRadialToolMapping.resolve('quote')!.tool, WbCanvasTool.text);
    });

    test('激光笔降级为荧光笔', () {
      expect(
        WbRadialToolMapping.resolve('laser')!.tool,
        WbCanvasTool.highlighter,
      );
      expect(WbRadialToolMapping.resolve('laser')!.hint, isNotNull);
    });

    test('专业元素：打开对应上下文编辑器', () {
      expect(
        WbRadialToolMapping.resolve('mindmap')!.editorKind,
        WbQuickCreateKind.mindmap,
      );
      expect(
        WbRadialToolMapping.resolve('table')!.editorKind,
        WbQuickCreateKind.table,
      );
      expect(
        WbRadialToolMapping.resolve('kanban')!.editorKind,
        WbQuickCreateKind.table,
      );
      expect(
        WbRadialToolMapping.resolve('timeline')!.editorKind,
        WbQuickCreateKind.table,
      );
      expect(
        WbRadialToolMapping.resolve('fn')!.editorKind,
        WbQuickCreateKind.functionCurve,
      );
      expect(
        WbRadialToolMapping.resolve('axes')!.editorKind,
        WbQuickCreateKind.functionCurve,
      );
      expect(
        WbRadialToolMapping.resolve('render3d')!.editorKind,
        WbQuickCreateKind.render3d,
      );
      expect(
        WbRadialToolMapping.resolve('render2d')!.editorKind,
        WbQuickCreateKind.render2d,
      );
      expect(
        WbRadialToolMapping.resolve('flowchart')!.editorKind,
        WbQuickCreateKind.flowchart,
      );
      expect(
        WbRadialToolMapping.resolve('swimlane')!.editorKind,
        WbQuickCreateKind.flowchart,
      );
      expect(
        WbRadialToolMapping.resolve('stateMachine')!.editorKind,
        WbQuickCreateKind.flowchart,
      );
    });

    test('未实现能力给出轻提示（截图 / PDF / 文档）', () {
      expect(WbRadialToolMapping.resolve('screenshot')!.hint, isNotNull);
      expect(WbRadialToolMapping.resolve('pdf')!.hint, isNotNull);
      expect(WbRadialToolMapping.resolve('doc')!.hint, isNotNull);
    });

    test('贴图：paste 触发剪贴板粘贴且不切工具', () {
      final WbRadialToolPlan plan = WbRadialToolMapping.resolve('paste')!;
      expect(plan.pasteClipboard, isTrue);
      expect(plan.tool, isNull);
      expect(plan.editorKind, isNull);
    });

    test('WbCanvasTool 全部工具 id 均可解析（底部 / 顶部工具栏兼容）', () {
      for (final WbCanvasTool tool in WbCanvasTool.values) {
        expect(
          WbRadialToolMapping.resolve(tool.id),
          isNotNull,
          reason: '画布工具 "${tool.id}" 未被映射覆盖',
        );
      }
    });
  });
}
