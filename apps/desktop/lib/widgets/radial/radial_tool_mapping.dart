/// 圆盘工具 → 画布行为的纯映射表（问题 4：全量覆盖 `RadialCatalog`）。
///
/// 将「圆盘工具 id → 工具切换 / 形状子类型 / 粘贴 / 上下文编辑器 / 降级
/// 提示」的决策从页面状态中抽离为无副作用查表，便于单元测试断言全覆盖，
/// 顶部工具栏（B3「更多」菜单）也按同口径消费本映射。
///
/// id 口径见 `radial_models.dart` 的 `RadialCatalog`；纯动作工具
/// （`more` / `ai.assistant` / `app.settings`）由宿主走 `onAction` 分发，
/// 不登记在本表。
library;

import '../canvas/canvas_controller.dart';
import '../context_editors/quick_create.dart';

/// 单个圆盘工具的执行计划（字段为空表示该步骤跳过）。
class WbRadialToolPlan {
  /// 创建执行计划。
  const WbRadialToolPlan({
    this.tool,
    this.shapeKind,
    this.pasteClipboard = false,
    this.editorKind,
    this.hint,
  });

  /// 目标画布工具（null 不切换工具）。
  final WbCanvasTool? tool;

  /// 形状子类型（仅形状工具；null 保持现有子类型）。
  final WbShapeKind? shapeKind;

  /// 是否执行「粘贴剪贴板」。
  final bool pasteClipboard;

  /// 打开对应上下文编辑器（null 不打开）。
  final WbQuickCreateKind? editorKind;

  /// 降级 / 未实现功能的轻提示（null 不提示）。
  final String? hint;
}

/// 圆盘工具映射表（不可变查表；消费方拿到计划后按字段顺序执行）。
abstract final class WbRadialToolMapping {
  /// 工具 id → 执行计划（覆盖 `RadialCatalog` 全部绘图工具）。
  static const Map<String, WbRadialToolPlan> _plans = <String, WbRadialToolPlan>{
    // ---- 选择 / 手 ----
    'select': WbRadialToolPlan(tool: WbCanvasTool.select),
    'hand': WbRadialToolPlan(tool: WbCanvasTool.hand),
    'marquee': WbRadialToolPlan(
      tool: WbCanvasTool.select,
      hint: '框选：使用选择工具在空白处拖拽即可',
    ),
    'lasso': WbRadialToolPlan(
      tool: WbCanvasTool.select,
      hint: '套索暂以框选替代',
    ),
    // ---- 便签 / 文本 ----
    'sticky': WbRadialToolPlan(tool: WbCanvasTool.note),
    'text': WbRadialToolPlan(tool: WbCanvasTool.text),
    'heading': WbRadialToolPlan(
      tool: WbCanvasTool.text,
      hint: '标题暂以文本工具替代',
    ),
    'list': WbRadialToolPlan(
      tool: WbCanvasTool.text,
      hint: '列表暂以文本工具替代',
    ),
    'quote': WbRadialToolPlan(
      tool: WbCanvasTool.text,
      hint: '引用暂以文本工具替代',
    ),
    // ---- 形状 / 连线 ----
    'shape': WbRadialToolPlan(tool: WbCanvasTool.shape),
    'rect': WbRadialToolPlan(
      tool: WbCanvasTool.shape,
      shapeKind: WbShapeKind.rect,
    ),
    'circle': WbRadialToolPlan(
      tool: WbCanvasTool.shape,
      shapeKind: WbShapeKind.ellipse,
    ),
    'diamond': WbRadialToolPlan(
      tool: WbCanvasTool.shape,
      shapeKind: WbShapeKind.diamond,
    ),
    'parallelogram': WbRadialToolPlan(
      tool: WbCanvasTool.shape,
      shapeKind: WbShapeKind.parallelogram,
    ),
    'arrow': WbRadialToolPlan(tool: WbCanvasTool.connector),
    'connector': WbRadialToolPlan(tool: WbCanvasTool.connector),
    // ---- 画笔 / 橡皮 ----
    'pen': WbRadialToolPlan(tool: WbCanvasTool.pen),
    'highlighter': WbRadialToolPlan(tool: WbCanvasTool.highlighter),
    'eraser': WbRadialToolPlan(tool: WbCanvasTool.eraser),
    'laser': WbRadialToolPlan(
      tool: WbCanvasTool.highlighter,
      hint: '激光笔为演示笔，暂以荧光笔替代',
    ),
    // ---- 图片 / 文档 ----
    'image': WbRadialToolPlan(tool: WbCanvasTool.image),
    'pdf': WbRadialToolPlan(hint: 'PDF 导入即将支持'),
    'doc': WbRadialToolPlan(hint: '文档导入即将支持'),
    'screenshot': WbRadialToolPlan(hint: '截图即将支持（随捕获插件上线）'),
    'paste': WbRadialToolPlan(pasteClipboard: true),
    // ---- 导图 / 表格（看板 / 时间线复用表格编辑器） ----
    'mindmap': WbRadialToolPlan(editorKind: WbQuickCreateKind.mindmap),
    'table': WbRadialToolPlan(editorKind: WbQuickCreateKind.table),
    'kanban': WbRadialToolPlan(
      editorKind: WbQuickCreateKind.table,
      hint: '看板暂以表格编辑器创建',
    ),
    'timeline': WbRadialToolPlan(
      editorKind: WbQuickCreateKind.table,
      hint: '时间线暂以表格编辑器创建',
    ),
    // ---- 函数 / 3D / 2D（坐标系复用函数编辑器） ----
    'fn': WbRadialToolPlan(editorKind: WbQuickCreateKind.functionCurve),
    'axes': WbRadialToolPlan(
      editorKind: WbQuickCreateKind.functionCurve,
      hint: '坐标系暂以函数编辑器创建',
    ),
    'render3d': WbRadialToolPlan(editorKind: WbQuickCreateKind.render3d),
    'render2d': WbRadialToolPlan(editorKind: WbQuickCreateKind.render2d),
    // ---- 流程图 / AI（泳道 / 状态机复用流程图编辑器） ----
    'flowchart': WbRadialToolPlan(editorKind: WbQuickCreateKind.flowchart),
    'swimlane': WbRadialToolPlan(
      editorKind: WbQuickCreateKind.flowchart,
      hint: '泳道图暂以流程图编辑器创建',
    ),
    'stateMachine': WbRadialToolPlan(
      editorKind: WbQuickCreateKind.flowchart,
      hint: '状态机暂以流程图编辑器创建',
    ),
  };

  /// 解析工具 id 的执行计划；未登记返回 null。
  static WbRadialToolPlan? resolve(String toolId) => _plans[toolId];

  /// 已登记的绘图工具 id 集合（不含动作工具，供测试断言全覆盖）。
  static Set<String> get knownToolIds =>
      Set<String>.unmodifiable(_plans.keys);
}
