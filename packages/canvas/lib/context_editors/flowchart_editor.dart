/// 流程图上下文编辑器（ProcessOn 式交互改造）。
///
/// 依据《流程图模块设计》§10–11 与《白板软件设计文档》§6.7/§7 实现：
/// - **无限画布**：世界坐标不再钳制在预览区内（虚拟平面 ±5000），画布可
///   自由平移——滚轮 / 空格 + 拖拽 / 中键拖拽 / 触控板；Ctrl/⌘ + 滚轮以
///   指针为锚缩放（0.25x–3x）；工具条提供 - / 百分比 / + / 重置 / 适配
///   内容，双击空白 = 适配内容；
/// - **快速创建**：左图形库按「流程图 / 类图 / 时序图 / 用例图 / 状态图 /
///   数据流图 / 电路图 / 我的组件」分库并支持折叠，点击即在
///   当前视口中心添加节点，按住可拖拽到画布指定位置；从节点四边端口圆点
///   拖拽到目标节点创建连线，拖到空白处松手弹出形状选择并自动建节点连线
///   （§6.1）；「连线」模式（依次点击两节点）保留为替代操作；
/// - **选择与移动**：单击选中 / Shift 加选 / 空白拖拽框选；多选整体拖动，
///   拖动时显示与其他节点的对齐参考线并自动吸附；Delete 批量删除（连线
///   级联清理）、Ctrl+A 全选、方向键微调（Shift 步进 10px）；
/// - **双击改字**：双击节点在节点上原地编辑文本（Enter / 失焦提交、Esc
///   取消）；双击连线删除；
/// - **连线样式**：选中连线后可编辑标签与箭头样式（实心箭头 / 开放箭头 /
///   继承空心三角 / 组合实心菱形 / 聚合空心菱形，UML 与数据流图语义）；
/// - **自动布局**：内置纯 Dart 分层摆放算法（Kahn 拓扑分层 + 固定间距
///   80/60，见 [WbFlowAutoLayout]），布局后节点可继续自由拖拽微调；
/// - **泳道图**：泳道为世界坐标条带（纵 220 / 横 220），节点拖入即归类；
/// - **模板库**：内置 7 个模板（基础流程 / 审批流 / 登录流 / 泳道流程 /
///   分支流程 / UML 类图 / 数据流图），一键填充并自动布局。
///
/// 数据模型为不可变值对象（[WbFlowchartModel] 等），所有节点坐标均为
/// 世界坐标。组件不依赖 Provider / FFI，可在测试与演示环境中独立挂载。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import 'context_editor_shell.dart';
import 'editor_workspace.dart';
import 'flow_components.dart';

// ---------------------------------------------------------------------------
// 枚举
// ---------------------------------------------------------------------------

/// 图形库分组（ProcessOn 式分库：流程图 / UML 四子图 / 数据流图 /
/// 电路图 / 我的组件）。
enum WbFlowShapeLibrary {
  /// 流程图基础图形。
  flowchart('flowchart', '流程图'),

  /// UML 类图。
  umlClass('umlClass', '类图'),

  /// UML 时序图。
  umlSequence('umlSequence', '时序图'),

  /// UML 用例图。
  umlUseCase('umlUseCase', '用例图'),

  /// UML 状态图。
  umlState('umlState', '状态图'),

  /// 数据流图图形。
  dfd('dfd', '数据流图'),

  /// 电路图。
  circuit('circuit', '电路图'),

  /// 我的组件（导入 SVG / 图片）。
  custom('custom', '我的组件');

  const WbFlowShapeLibrary(this.id, this.label);

  /// 稳定 id（跨端序列化用）。
  final String id;

  /// 中文显示名。
  final String label;
}

/// 流程图节点类型（对齐《流程图模块设计》§3.1 / §4，并扩充 UML 全谱系 /
/// 数据流图 / 电路图 / 自定义组件）。
enum WbFlowNodeType {
  /// 开始。
  start('start', '开始', WbContextPalette.flowStart, LinearIcons.forward,
      WbFlowShapeLibrary.flowchart),

  /// 结束。
  end('end', '结束', WbContextPalette.flowEnd, LinearIcons.stop,
      WbFlowShapeLibrary.flowchart),

  /// 处理。
  process('process', '处理', WbContextPalette.flowProcess, LinearIcons.shape,
      WbFlowShapeLibrary.flowchart),

  /// 判断。
  decision('decision', '判断', WbContextPalette.flowDecision,
      LinearIcons.warning, WbFlowShapeLibrary.flowchart),

  /// 输入 / 输出。
  inputOutput('inputOutput', '输入/输出', WbContextPalette.flowInputOutput,
      LinearIcons.import, WbFlowShapeLibrary.flowchart),

  /// 文档。
  document('document', '文档', WbContextPalette.flowDocument, LinearIcons.page,
      WbFlowShapeLibrary.flowchart),

  /// 数据库。
  database('database', '数据库', WbContextPalette.flowDatabase,
      LinearIcons.layers, WbFlowShapeLibrary.flowchart),

  /// 手动操作。
  manualOperation('manualOperation', '手动操作', WbContextPalette.flowManual,
      LinearIcons.hand, WbFlowShapeLibrary.flowchart),

  /// 注释（开放矩形，虚线语义由绘制器用左侧色条表达）。
  annotation('annotation', '注释', WbContextPalette.flowDocument,
      LinearIcons.comment, WbFlowShapeLibrary.flowchart),

  // ---- UML 类图 ----

  /// UML 类（三段式：类名 / 属性 / 方法，见 [WbFlowNode.compartments]）。
  umlClass('umlClass', '类', WbContextPalette.flowProcess, LinearIcons.table,
      WbFlowShapeLibrary.umlClass, 160, 120),

  /// UML 接口（三段式，名称段带 «interface» 构造型）。
  umlInterface('umlInterface', '接口', WbContextPalette.flowProcess,
      LinearIcons.table, WbFlowShapeLibrary.umlClass, 160, 120),

  /// UML 简单类（单段名称框）。
  umlSimpleClass('umlSimpleClass', '简单类', WbContextPalette.flowProcess,
      LinearIcons.shape, WbFlowShapeLibrary.umlClass, 140, 50),

  /// UML 简单接口（单段名称框 + «interface»）。
  umlSimpleInterface('umlSimpleInterface', '简单接口',
      WbContextPalette.flowProcess, LinearIcons.table,
      WbFlowShapeLibrary.umlClass, 140, 56),

  /// UML 多实例类（三段式，名称段带 «多例» 构造型）。
  umlMultiton('umlMultiton', '多例类', WbContextPalette.flowProcess,
      LinearIcons.layers, WbFlowShapeLibrary.umlClass, 160, 120),

  /// UML 包（文件夹形）。
  umlPackage('umlPackage', '包', WbContextPalette.flowManual,
      LinearIcons.folder, WbFlowShapeLibrary.umlClass, 140, 80),

  /// UML 备注（折角便签）。
  umlNote('umlNote', '备注', WbContextPalette.flowManual,
      LinearIcons.stickyNote, WbFlowShapeLibrary.umlClass, 140, 70),

  // ---- UML 时序图 ----

  /// UML 生命线（头框 + 虚线生命线尾）。
  umlLifeline('umlLifeline', '生命线', WbContextPalette.flowInputOutput,
      LinearIcons.connector, WbFlowShapeLibrary.umlSequence, 120, 160),

  /// UML 激活条（窄矩形）。
  umlActivation('umlActivation', '激活条', WbContextPalette.flowInputOutput,
      LinearIcons.grid, WbFlowShapeLibrary.umlSequence, 14, 80),

  /// UML 对象（名称带下划线的类框）。
  umlObject('umlObject', '对象', WbContextPalette.flowInputOutput,
      LinearIcons.shape, WbFlowShapeLibrary.umlSequence, 140, 46),

  // ---- UML 用例图 ----

  /// UML 参与者（用例图小人）。
  umlActor('umlActor', '参与者', WbContextPalette.flowInputOutput,
      LinearIcons.members, WbFlowShapeLibrary.umlUseCase, 48, 78),

  /// UML 用例（椭圆）。
  umlUseCase('umlUseCase', '用例', WbContextPalette.flowInputOutput,
      LinearIcons.select, WbFlowShapeLibrary.umlUseCase, 140, 60),

  /// UML 系统边界（大矩形框，名称置顶）。
  umlSystem('umlSystem', '系统边界', WbContextPalette.flowManual,
      LinearIcons.board, WbFlowShapeLibrary.umlUseCase, 300, 220),

  // ---- UML 状态图 ----

  /// UML 状态（圆角矩形）。
  umlState('umlState', '状态', WbContextPalette.flowDecision,
      LinearIcons.shape, WbFlowShapeLibrary.umlState, 140, 60),

  /// UML 初态（实心圆）。
  umlInitial('umlInitial', '初态', WbContextPalette.flowStart,
      LinearIcons.forward, WbFlowShapeLibrary.umlState, 24, 24),

  /// UML 终态（牛眼圆）。
  umlFinal('umlFinal', '终态', WbContextPalette.flowEnd, LinearIcons.stop,
      WbFlowShapeLibrary.umlState, 28, 28),

  /// UML 选择（菱形，分支 / 合并）。
  umlChoice('umlChoice', '选择', WbContextPalette.flowDecision,
      LinearIcons.warning, WbFlowShapeLibrary.umlState, 48, 48),

  // ---- 数据流图（DFD）----

  /// 外部实体（双线矩形）。
  dfdExternal('dfdExternal', '外部实体', WbContextPalette.flowDocument,
      LinearIcons.board, WbFlowShapeLibrary.dfd, 140, 60),

  /// 处理（圆）。
  dfdProcess('dfdProcess', '处理', WbContextPalette.flowProcess,
      LinearIcons.sync, WbFlowShapeLibrary.dfd, 96, 96),

  /// 数据存储（开口矩形）。
  dfdStore('dfdStore', '数据存储', WbContextPalette.flowDatabase,
      LinearIcons.save, WbFlowShapeLibrary.dfd, 150, 50),

  // ---- 电路图 ----

  /// 电阻（锯齿折线）。
  circuitResistor('circuitResistor', '电阻', WbContextPalette.flowDocument,
      LinearIcons.shape, WbFlowShapeLibrary.circuit, 64, 24),

  /// 电容（双平行板）。
  circuitCapacitor('circuitCapacitor', '电容', WbContextPalette.flowDocument,
      LinearIcons.grid, WbFlowShapeLibrary.circuit, 64, 28),

  /// 电感（线圈）。
  circuitInductor('circuitInductor', '电感', WbContextPalette.flowDocument,
      LinearIcons.sync, WbFlowShapeLibrary.circuit, 64, 28),

  /// 二极管（三角 + 竖线）。
  circuitDiode('circuitDiode', '二极管', WbContextPalette.flowDocument,
      LinearIcons.connector, WbFlowShapeLibrary.circuit, 64, 28),

  /// 电池（长短线对）。
  circuitBattery('circuitBattery', '电池', WbContextPalette.flowStart,
      LinearIcons.power, WbFlowShapeLibrary.circuit, 48, 48),

  /// 直流电源（圆圈 + 正负号）。
  circuitDcSource('circuitDcSource', '直流电源', WbContextPalette.flowStart,
      LinearIcons.power, WbFlowShapeLibrary.circuit, 52, 52),

  /// 开关（断开的斜杆）。
  circuitSwitch('circuitSwitch', '开关', WbContextPalette.flowDocument,
      LinearIcons.select, WbFlowShapeLibrary.circuit, 64, 28),

  /// 灯泡（圆 + 交叉线）。
  circuitLamp('circuitLamp', '灯泡', WbContextPalette.flowDecision,
      LinearIcons.light, WbFlowShapeLibrary.circuit, 48, 48),

  /// 接地（三横线）。
  circuitGround('circuitGround', '接地', WbContextPalette.flowDocument,
      LinearIcons.layers, WbFlowShapeLibrary.circuit, 44, 28),

  /// 节点（实心圆点）。
  circuitJunction('circuitJunction', '节点', WbContextPalette.flowDocument,
      LinearIcons.grid, WbFlowShapeLibrary.circuit, 18, 18),

  // ---- 我的组件 ----

  /// 自定义组件（导入 SVG / 图片；无数据时绘制虚线占位框）。
  customComponent('customComponent', '组件', WbContextPalette.flowProcess,
      LinearIcons.image, WbFlowShapeLibrary.custom, 120, 120);

  const WbFlowNodeType(
    this.id,
    this.label,
    this.color,
    this.icon,
    this.library, [
    this.defaultWidth = WbContextMetrics.flowNodeWidth,
    this.defaultHeight = WbContextMetrics.flowNodeHeight,
  ]);

  /// 稳定 id（跨端序列化用）。
  final String id;

  /// 中文显示名。
  final String label;

  /// 节点主色（§12.1）。
  final Color color;

  /// 调色板图标。
  final IconData icon;

  /// 图形库分组。
  final WbFlowShapeLibrary library;

  /// 默认宽（新建节点时使用）。
  final double defaultWidth;

  /// 默认高。
  final double defaultHeight;

  /// 从 [id] 解析类型（未知回退 [process]）。
  static WbFlowNodeType fromId(String id) {
    for (final WbFlowNodeType type in WbFlowNodeType.values) {
      if (type.id == id) {
        return type;
      }
    }
    return WbFlowNodeType.process;
  }
}

/// 图形库拖拽 / 点击载荷：静态图形类型或「我的组件」条目。
///
/// 左面板图形库项统一以本类型作为拖拽数据；组件项额外携带 [component]
/// 数据，落点 / 点击创建 `WbFlowNodeType.customComponent` 节点时内嵌组件。
@immutable
class WbFlowShapeSpec {
  /// 创建载荷（静态图形 [component] 为空；组件项非空）。
  const WbFlowShapeSpec({required this.type, this.component});

  /// 节点类型（组件项为 [WbFlowNodeType.customComponent]）。
  final WbFlowNodeType type;

  /// 组件数据（仅「我的组件」项非空）。
  final WbFlowComponent? component;

  /// 创建节点时使用的尺寸（组件按长边 ≤160 等比，静态图形取默认尺寸）。
  Size get preferredSize {
    final WbFlowComponent? data = component;
    if (data != null) {
      return data.preferredNodeSize;
    }
    return Size(type.defaultWidth, type.defaultHeight);
  }
}

/// 连线箭头样式（ProcessOn / UML 语义）。
enum WbFlowArrowStyle {
  /// 实心箭头（默认，流程连线）。
  arrow('arrow', '箭头'),

  /// 开放箭头（V 形线，数据流图）。
  open('open', '开放箭头'),

  /// 继承（空心三角，画在终点端）。
  inherit('inherit', '继承'),

  /// 组合（实心菱形，画在起点端）。
  composition('composition', '组合'),

  /// 聚合（空心菱形，画在起点端）。
  aggregation('aggregation', '聚合');

  const WbFlowArrowStyle(this.id, this.label);

  /// 稳定 id。
  final String id;

  /// 中文显示名。
  final String label;

  /// 从 [id] 解析（未知回退 [arrow]）。
  static WbFlowArrowStyle fromId(String id) {
    for (final WbFlowArrowStyle style in WbFlowArrowStyle.values) {
      if (style.id == id) {
        return style;
      }
    }
    return WbFlowArrowStyle.arrow;
  }
}

/// 自动布局方向（§7.1）。
enum WbFlowLayoutDirection {
  /// 从上到下（默认）。
  topToBottom('tb', '从上到下'),

  /// 从左到右。
  leftToRight('lr', '从左到右');

  const WbFlowLayoutDirection(this.id, this.label);

  /// 稳定 id。
  final String id;

  /// 中文显示名。
  final String label;
}

/// 泳道方向（§8.3）。
enum WbSwimlaneOrientation {
  /// 纵向泳道（列，横向排列）。
  vertical('vertical', '纵向泳道'),

  /// 横向泳道（行，纵向排列）。
  horizontal('horizontal', '横向泳道');

  const WbSwimlaneOrientation(this.id, this.label);

  /// 稳定 id。
  final String id;

  /// 中文显示名。
  final String label;

  /// 取反方向。
  WbSwimlaneOrientation get flipped =>
      this == vertical ? horizontal : vertical;
}

// ---------------------------------------------------------------------------
// 不可变数据模型
// ---------------------------------------------------------------------------

/// 流程图节点（不可变）。
@immutable
class WbFlowNode {
  /// 创建节点。
  const WbFlowNode({
    required this.id,
    required this.x,
    required this.y,
    this.type = WbFlowNodeType.process,
    this.text = '',
    this.width = WbContextMetrics.flowNodeWidth,
    this.height = WbContextMetrics.flowNodeHeight,
    this.laneId,
    this.compartments = const <String>[],
    this.component,
  });

  /// 节点 id（图内唯一）。
  final String id;

  /// 左上角 x（世界坐标）。
  final double x;

  /// 左上角 y。
  final double y;

  /// 节点类型。
  final WbFlowNodeType type;

  /// 节点文本。
  final String text;

  /// 宽。
  final double width;

  /// 高。
  final double height;

  /// 所属泳道 id（null 表示未归类）。
  final String? laneId;

  /// 三段式分区内容（[WbFlowNodeType.umlClass] / [WbFlowNodeType.umlInterface]
  /// / [WbFlowNodeType.umlMultiton] 使用：类名 / 属性 / 方法；空列表表示
  /// 回退 [text] 单文本渲染）。
  final List<String> compartments;

  /// 内嵌组件数据（仅 [WbFlowNodeType.customComponent] 使用；null 时绘制
  /// 虚线占位框）。
  final WbFlowComponent? component;

  /// 外接矩形。
  Rect get bounds => Rect.fromLTWH(x, y, width, height);

  /// 中心点。
  Offset get center => Offset(x + width / 2, y + height / 2);

  /// 绘制用文本（UML 类按三段拼行，其余取 [text]）。
  String get displayText {
    if (compartments.isEmpty) {
      return text;
    }
    return compartments.where((String part) => part.isNotEmpty).join('\n');
  }

  /// 复制并覆盖字段。
  WbFlowNode copyWith({
    String? id,
    double? x,
    double? y,
    WbFlowNodeType? type,
    String? text,
    double? width,
    double? height,
    Object? laneId = _sentinel,
    List<String>? compartments,
    Object? component = _sentinel,
  }) {
    return WbFlowNode(
      id: id ?? this.id,
      x: x ?? this.x,
      y: y ?? this.y,
      type: type ?? this.type,
      text: text ?? this.text,
      width: width ?? this.width,
      height: height ?? this.height,
      laneId: identical(laneId, _sentinel) ? this.laneId : laneId as String?,
      compartments: compartments ?? this.compartments,
      component: identical(component, _sentinel)
          ? this.component
          : component as WbFlowComponent?,
    );
  }
}

/// 连接线（不可变；[autoRoute] 恒为 true，路由由绘制器按节点矩形推导）。
@immutable
class WbFlowConnector {
  /// 创建连线。
  const WbFlowConnector({
    required this.id,
    required this.fromId,
    required this.toId,
    this.label = '',
    this.autoRoute = true,
    this.arrow = WbFlowArrowStyle.arrow,
  });

  /// 连线 id。
  final String id;

  /// 起点节点 id。
  final String fromId;

  /// 终点节点 id。
  final String toId;

  /// 连线标签（如「是 / 否」）。
  final String label;

  /// 是否自动路由（当前恒 true，折线由绘制器生成）。
  final bool autoRoute;

  /// 箭头样式（UML / 数据流图语义，见 [WbFlowArrowStyle]）。
  final WbFlowArrowStyle arrow;

  /// 复制并覆盖字段。
  WbFlowConnector copyWith({
    String? id,
    String? fromId,
    String? toId,
    String? label,
    WbFlowArrowStyle? arrow,
  }) {
    return WbFlowConnector(
      id: id ?? this.id,
      fromId: fromId ?? this.fromId,
      toId: toId ?? this.toId,
      label: label ?? this.label,
      arrow: arrow ?? this.arrow,
    );
  }
}

/// 泳道（不可变）。
@immutable
class WbFlowLane {
  /// 创建泳道。
  const WbFlowLane({
    required this.id,
    required this.name,
    this.orientation = WbSwimlaneOrientation.vertical,
  });

  /// 泳道 id。
  final String id;

  /// 泳道名称。
  final String name;

  /// 方向。
  final WbSwimlaneOrientation orientation;

  /// 复制并覆盖字段。
  WbFlowLane copyWith({String? id, String? name, WbSwimlaneOrientation? orientation}) {
    return WbFlowLane(
      id: id ?? this.id,
      name: name ?? this.name,
      orientation: orientation ?? this.orientation,
    );
  }
}

/// 流程图模型（不可变；所有编辑操作返回新实例，便于撤销快照）。
@immutable
class WbFlowchartModel {
  /// 创建模型。
  const WbFlowchartModel({
    this.nodes = const <WbFlowNode>[],
    this.connectors = const <WbFlowConnector>[],
    this.lanes = const <WbFlowLane>[],
    this.direction = WbFlowLayoutDirection.topToBottom,
    this.templateId,
  });

  /// 演示用示例流程（开始 → 处理 → 结束，位置按默认面板宽度摆放）。
  factory WbFlowchartModel.sample() {
    return const WbFlowchartModel(
      nodes: <WbFlowNode>[
        WbFlowNode(id: 'n1', x: 134, y: 14, type: WbFlowNodeType.start, text: '开始'),
        WbFlowNode(id: 'n2', x: 134, y: 92, type: WbFlowNodeType.process, text: '处理'),
        WbFlowNode(id: 'n3', x: 134, y: 170, type: WbFlowNodeType.end, text: '结束'),
      ],
      connectors: <WbFlowConnector>[
        WbFlowConnector(id: 'c1', fromId: 'n1', toId: 'n2'),
        WbFlowConnector(id: 'c2', fromId: 'n2', toId: 'n3'),
      ],
    );
  }

  /// 节点列表（顺序即插入顺序）。
  final List<WbFlowNode> nodes;

  /// 连线列表。
  final List<WbFlowConnector> connectors;

  /// 泳道列表。
  final List<WbFlowLane> lanes;

  /// 自动布局方向。
  final WbFlowLayoutDirection direction;

  /// 来源模板 id（手动编辑后仍保留，便于溯源；null 表示非模板创建）。
  final String? templateId;

  /// 按 id 查找节点（不存在返回 null）。
  WbFlowNode? nodeById(String id) {
    for (final WbFlowNode node in nodes) {
      if (node.id == id) {
        return node;
      }
    }
    return null;
  }

  /// 按 id 查找泳道（不存在返回 null）。
  WbFlowLane? laneById(String id) {
    for (final WbFlowLane lane in lanes) {
      if (lane.id == id) {
        return lane;
      }
    }
    return null;
  }

  /// 与指定节点相连的连线。
  List<WbFlowConnector> connectorsOf(String nodeId) {
    return <WbFlowConnector>[
      for (final WbFlowConnector c in connectors)
        if (c.fromId == nodeId || c.toId == nodeId) c,
    ];
  }

  /// 泳道内节点。
  List<WbFlowNode> nodesOfLane(String laneId) {
    return <WbFlowNode>[
      for (final WbFlowNode n in nodes)
        if (n.laneId == laneId) n,
    ];
  }

  /// 复制并覆盖字段。
  WbFlowchartModel copyWith({
    List<WbFlowNode>? nodes,
    List<WbFlowConnector>? connectors,
    List<WbFlowLane>? lanes,
    WbFlowLayoutDirection? direction,
    Object? templateId = _sentinel,
  }) {
    return WbFlowchartModel(
      nodes: nodes ?? this.nodes,
      connectors: connectors ?? this.connectors,
      lanes: lanes ?? this.lanes,
      direction: direction ?? this.direction,
      templateId:
          identical(templateId, _sentinel) ? this.templateId : templateId as String?,
    );
  }

  /// 添加或替换节点（按 id）。
  WbFlowchartModel upsertNode(WbFlowNode node) {
    final List<WbFlowNode> next = <WbFlowNode>[];
    bool replaced = false;
    for (final WbFlowNode n in nodes) {
      if (n.id == node.id) {
        next.add(node);
        replaced = true;
      } else {
        next.add(n);
      }
    }
    if (!replaced) {
      next.add(node);
    }
    return copyWith(nodes: next);
  }

  /// 更新节点若干字段（节点不存在返回自身）。
  WbFlowchartModel updateNode(
    String id, {
    double? x,
    double? y,
    String? text,
    WbFlowNodeType? type,
    Object? laneId = _sentinel,
    List<String>? compartments,
  }) {
    final WbFlowNode? node = nodeById(id);
    if (node == null) {
      return this;
    }
    return upsertNode(
      node.copyWith(
        x: x,
        y: y,
        text: text,
        type: type,
        laneId: laneId,
        compartments: compartments,
      ),
    );
  }

  /// 整体平移 [ids] 中各节点（不存在 / 空集返回自身）。
  WbFlowchartModel translateNodes(Set<String> ids, Offset delta) {
    if (ids.isEmpty || (delta.dx == 0 && delta.dy == 0)) {
      return this;
    }
    bool changed = false;
    final List<WbFlowNode> next = <WbFlowNode>[
      for (final WbFlowNode n in nodes)
        if (ids.contains(n.id))
          (() {
            changed = true;
            return n.copyWith(x: n.x + delta.dx, y: n.y + delta.dy);
          })()
        else
          n,
    ];
    return changed ? copyWith(nodes: next) : this;
  }

  /// 删除节点及其关联连线（不存在返回自身）。
  WbFlowchartModel removeNode(String id) {
    if (nodeById(id) == null) {
      return this;
    }
    return copyWith(
      nodes: <WbFlowNode>[
        for (final WbFlowNode n in nodes)
          if (n.id != id) n,
      ],
      connectors: <WbFlowConnector>[
        for (final WbFlowConnector c in connectors)
          if (c.fromId != id && c.toId != id) c,
      ],
    );
  }

  /// 批量删除节点（含级联清理连线；空集或全部不存在返回自身）。
  WbFlowchartModel removeNodes(Set<String> ids) {
    if (ids.isEmpty) {
      return this;
    }
    final bool hit = nodes.any((WbFlowNode n) => ids.contains(n.id));
    if (!hit) {
      return this;
    }
    return copyWith(
      nodes: <WbFlowNode>[
        for (final WbFlowNode n in nodes)
          if (!ids.contains(n.id)) n,
      ],
      connectors: <WbFlowConnector>[
        for (final WbFlowConnector c in connectors)
          if (!ids.contains(c.fromId) && !ids.contains(c.toId)) c,
      ],
    );
  }

  /// 内容包围盒（无节点返回 null）。
  Rect? contentBounds() {
    Rect? bounds;
    for (final WbFlowNode n in nodes) {
      bounds = bounds == null ? n.bounds : bounds.expandToInclude(n.bounds);
    }
    return bounds;
  }

  /// 添加连线（重复或自环返回自身）。
  WbFlowchartModel addConnector(WbFlowConnector connector) {
    if (connector.fromId == connector.toId || nodeById(connector.fromId) == null ||
        nodeById(connector.toId) == null) {
      return this;
    }
    for (final WbFlowConnector c in connectors) {
      if (c.fromId == connector.fromId && c.toId == connector.toId) {
        return this;
      }
    }
    return copyWith(connectors: <WbFlowConnector>[...connectors, connector]);
  }

  /// 删除连线。
  WbFlowchartModel removeConnector(String id) {
    return copyWith(
      connectors: <WbFlowConnector>[
        for (final WbFlowConnector c in connectors)
          if (c.id != id) c,
      ],
    );
  }

  /// 更新连线若干字段（连线不存在返回自身）。
  WbFlowchartModel updateConnector(
    String id, {
    String? label,
    WbFlowArrowStyle? arrow,
  }) {
    bool changed = false;
    final List<WbFlowConnector> next = <WbFlowConnector>[
      for (final WbFlowConnector c in connectors)
        if (c.id == id)
          (() {
            changed = true;
            return c.copyWith(label: label, arrow: arrow);
          })()
        else
          c,
    ];
    return changed ? copyWith(connectors: next) : this;
  }

  /// 添加泳道。
  WbFlowchartModel addLane(WbFlowLane lane) =>
      copyWith(lanes: <WbFlowLane>[...lanes, lane]);

  /// 删除泳道（泳道内节点自动变为未归类）。
  WbFlowchartModel removeLane(String laneId) {
    if (laneById(laneId) == null) {
      return this;
    }
    return copyWith(
      lanes: <WbFlowLane>[
        for (final WbFlowLane lane in lanes)
          if (lane.id != laneId) lane,
      ],
      nodes: <WbFlowNode>[
        for (final WbFlowNode n in nodes)
          if (n.laneId == laneId) n.copyWith(laneId: null) else n,
      ],
    );
  }

  /// 重命名泳道。
  WbFlowchartModel renameLane(String laneId, String name) {
    return copyWith(
      lanes: <WbFlowLane>[
        for (final WbFlowLane lane in lanes)
          if (lane.id == laneId) lane.copyWith(name: name) else lane,
      ],
    );
  }

  /// 切换全部泳道方向。
  WbFlowchartModel flipLaneOrientation() {
    if (lanes.isEmpty) {
      return this;
    }
    final WbSwimlaneOrientation target =
        lanes.first.orientation.flipped;
    return copyWith(
      lanes: <WbFlowLane>[
        for (final WbFlowLane lane in lanes)
          lane.copyWith(orientation: target),
      ],
    );
  }
}

/// `copyWith` 的哨兵值（区分「未传参」与「显式传 null」）。
const Object _sentinel = Object();

// ---------------------------------------------------------------------------
// 自动布局（纯 Dart 分层摆放）
// ---------------------------------------------------------------------------

/// 自动布局引擎：Kahn 拓扑分层 + 层内稳定排序 + 固定间距摆放到世界坐标。
///
/// 算法步骤（简化版 Sugiyama，不做交叉最小化/图形优化）：
/// 1. 构图并统计入度；
/// 2. Kahn 拓扑分层（`layer[v] = max(layer[u] + 1)`），环上节点回退为
///    「上游最大层 + 1」，保证不丢节点、不挂死；
/// 3. 层内排序：有泳道时按泳道序，否则按插入序（稳定）；
/// 4. 分方向分配坐标：间距固定（同层 80 / 层间 60，见《流程图模块设计》
///    §7.3），不再压缩或钳制（无限画布）；轴向锚点取现有内容包围盒顶边
///    与 [canvas] 宽度中线。
abstract final class WbFlowAutoLayout {
  /// 对 [model] 执行布局并返回新模型（节点为空时原样返回）。
  ///
  /// [canvas] 仅用于轴向锚点（宽度中线），节点坐标不再钳制进画布；
  /// [padding] 为无内容时的起始留白。
  static WbFlowchartModel apply(
    WbFlowchartModel model, {
    required Size canvas,
    double padding = 14,
    double minGapX = 80,
    double minGapY = 60,
  }) {
    if (model.nodes.isEmpty) {
      return model;
    }
    final double width = math.max(canvas.width, 120);

    // 1. 邻接表与入度。
    final Map<String, List<String>> outgoing = <String, List<String>>{};
    final Map<String, int> indegree = <String, int>{};
    for (final WbFlowNode n in model.nodes) {
      outgoing[n.id] = <String>[];
      indegree[n.id] = 0;
    }
    for (final WbFlowConnector c in model.connectors) {
      final List<String>? outs = outgoing[c.fromId];
      if (outs != null && indegree.containsKey(c.toId)) {
        outs.add(c.toId);
        indegree[c.toId] = indegree[c.toId]! + 1;
      }
    }

    // 2. Kahn 分层。
    final Map<String, int> layer = <String, int>{};
    final List<String> queue = <String>[];
    for (final WbFlowNode n in model.nodes) {
      if (indegree[n.id] == 0) {
        layer[n.id] = 0;
        queue.add(n.id);
      }
    }
    int head = 0;
    while (head < queue.length) {
      final String id = queue[head++];
      final int base = layer[id] ?? 0;
      for (final String to in outgoing[id]!) {
        if ((layer[to] ?? -1) < base + 1) {
          layer[to] = base + 1;
        }
        final int left = indegree[to]! - 1;
        indegree[to] = left;
        if (left == 0) {
          queue.add(to);
        }
      }
    }

    // 2b. 环 / 断裂图回退：挂到上游最大层之后。
    int maxLayer = 0;
    for (final int value in layer.values) {
      maxLayer = math.max(maxLayer, value);
    }
    for (final WbFlowNode n in model.nodes) {
      if (layer.containsKey(n.id)) {
        continue;
      }
      int? best;
      for (final WbFlowConnector c in model.connectors) {
        if (c.toId == n.id) {
          final int? up = layer[c.fromId];
          if (up != null && (best == null || up + 1 < best)) {
            best = up + 1;
          }
        }
      }
      final int value = best ?? (maxLayer + 1);
      layer[n.id] = value;
      maxLayer = math.max(maxLayer, value);
    }

    // 3. 层内排序：泳道序优先，其次插入序。
    final Map<String, int> laneIndex = <String, int>{};
    for (int i = 0; i < model.lanes.length; i++) {
      laneIndex[model.lanes[i].id] = i;
    }
    final Map<String, int> order = <String, int>{};
    for (int i = 0; i < model.nodes.length; i++) {
      order[model.nodes[i].id] = i;
    }
    final List<WbFlowNode> sorted = List<WbFlowNode>.of(model.nodes)
      ..sort((WbFlowNode a, WbFlowNode b) {
        final int la = layer[a.id] ?? 0;
        final int lb = layer[b.id] ?? 0;
        if (la != lb) {
          return la.compareTo(lb);
        }
        final int na = a.laneId == null ? -1 : (laneIndex[a.laneId!] ?? -1);
        final int nb = b.laneId == null ? -1 : (laneIndex[b.laneId!] ?? -1);
        if (na != nb) {
          return na.compareTo(nb);
        }
        return (order[a.id] ?? 0).compareTo(order[b.id] ?? 0);
      });

    // 4. 逐层求坐标：世界坐标固定间距摆放（同层 80 / 层间 60，§7.3），
    //    不再钳制进画布；锚点取现有内容包围盒顶边（无内容取 [padding]）。
    final Map<String, List<WbFlowNode>> byLayer = <String, List<WbFlowNode>>{};
    for (final WbFlowNode n in sorted) {
      byLayer.putIfAbsent('${layer[n.id] ?? 0}', () => <WbFlowNode>[]).add(n);
    }
    final int layerCount = maxLayer + 1;
    final bool withLanes = model.lanes.isNotEmpty;
    final int laneCount = math.max(model.lanes.length, 1);
    final bool vertical = !withLanes ||
        model.lanes.first.orientation == WbSwimlaneOrientation.vertical;
    final double axis = width / 2;
    final double anchorTop = model.contentBounds()?.top ?? padding;

    final Map<String, Offset> placed = <String, Offset>{};
    if (model.direction == WbFlowLayoutDirection.topToBottom) {
      // 主方向：y（层），次方向：x（泳道条带或居中）。
      final List<double> layerHeights = List<double>.filled(layerCount, 0);
      for (int l = 0; l < layerCount; l++) {
        double h = WbContextMetrics.flowNodeHeight;
        for (final WbFlowNode n in byLayer['$l'] ?? const <WbFlowNode>[]) {
          h = math.max(h, n.height);
        }
        layerHeights[l] = h;
      }
      final List<double> layerY = List<double>.filled(layerCount, anchorTop);
      for (int l = 1; l < layerCount; l++) {
        layerY[l] = layerY[l - 1] + layerHeights[l - 1] + minGapY;
      }
      if (withLanes && vertical) {
        // 纵向泳道：节点居中于各自泳道条带（条带宽 220）。
        final double groupLeft =
            axis - laneCount * WbContextMetrics.flowLaneWidth / 2;
        for (int l = 0; l < layerCount; l++) {
          for (final WbFlowNode n in byLayer['$l'] ?? const <WbFlowNode>[]) {
            final int lane = n.laneId == null ? 0 : (laneIndex[n.laneId!] ?? 0);
            final double laneLeft =
                groupLeft + WbContextMetrics.flowLaneWidth * lane;
            placed[n.id] = Offset(
              laneLeft + (WbContextMetrics.flowLaneWidth - n.width) / 2,
              layerY[l],
            );
          }
        }
      } else if (withLanes) {
        // 横向泳道：节点按泳道行摆放（行高 220），层内居中。
        for (int l = 0; l < layerCount; l++) {
          final List<WbFlowNode> rowNodes = byLayer['$l'] ?? const <WbFlowNode>[];
          final double totalWidth = rowNodes.fold(
            0,
            (double a, WbFlowNode n) => a + n.width,
          );
          double x = axis -
              (totalWidth + minGapX * math.max(rowNodes.length - 1, 0)) / 2;
          for (final WbFlowNode n in rowNodes) {
            final int lane = n.laneId == null ? 0 : (laneIndex[n.laneId!] ?? 0);
            final double rowTop =
                anchorTop + WbContextMetrics.flowLaneHeight * lane;
            placed[n.id] = Offset(
              x,
              rowTop + (WbContextMetrics.flowLaneHeight - n.height) / 2,
            );
            x += n.width + minGapX;
          }
        }
      } else {
        for (int l = 0; l < layerCount; l++) {
          final List<WbFlowNode> rowNodes = byLayer['$l'] ?? const <WbFlowNode>[];
          final double totalWidth = rowNodes.fold(
            0,
            (double a, WbFlowNode n) => a + n.width,
          );
          double x = axis -
              (totalWidth + minGapX * math.max(rowNodes.length - 1, 0)) / 2;
          for (final WbFlowNode n in rowNodes) {
            placed[n.id] = Offset(x, layerY[l]);
            x += n.width + minGapX;
          }
        }
      }
    } else {
      // 从左到右：主方向 x（层），次方向 y（泳道行或顺排）。
      final List<double> layerWidths = List<double>.filled(layerCount, 0);
      for (int l = 0; l < layerCount; l++) {
        double w = WbContextMetrics.flowNodeWidth;
        for (final WbFlowNode n in byLayer['$l'] ?? const <WbFlowNode>[]) {
          w = math.max(w, n.width);
        }
        layerWidths[l] = w;
      }
      final List<double> layerX = List<double>.filled(layerCount, axis);
      for (int l = 1; l < layerCount; l++) {
        layerX[l] = layerX[l - 1] + layerWidths[l - 1] + minGapX;
      }
      if (withLanes) {
        for (int l = 0; l < layerCount; l++) {
          for (final WbFlowNode n in byLayer['$l'] ?? const <WbFlowNode>[]) {
            final int lane = n.laneId == null ? 0 : (laneIndex[n.laneId!] ?? 0);
            final double rowTop =
                anchorTop + WbContextMetrics.flowLaneHeight * lane;
            placed[n.id] = Offset(
              layerX[l],
              rowTop + (WbContextMetrics.flowLaneHeight - n.height) / 2,
            );
          }
        }
      } else {
        for (int l = 0; l < layerCount; l++) {
          final List<WbFlowNode> columnNodes =
              byLayer['$l'] ?? const <WbFlowNode>[];
          double y = anchorTop;
          for (final WbFlowNode n in columnNodes) {
            placed[n.id] = Offset(layerX[l], y);
            y += n.height + minGapY;
          }
        }
      }
    }

    return model.copyWith(
      nodes: <WbFlowNode>[
        for (final WbFlowNode n in model.nodes)
          n.copyWith(
            x: placed[n.id]?.dx ?? n.x,
            y: placed[n.id]?.dy ?? n.y,
          ),
      ],
    );
  }

}

/// 泳道几何（世界坐标条带，§8.3）：渲染、命中与自动布局共用同一口径。
///
/// 纵向泳道为等宽列条带（宽 [WbContextMetrics.flowLaneWidth]），
/// 横向泳道为等高行条带（高 [WbContextMetrics.flowLaneHeight]）；
/// 条带长度按内容包围盒外扩（空内容取 320 兜底）。
abstract final class WbFlowLaneGeometry {
  /// 条带长度：[contentExtent] 外扩 48，最小 320。
  static double extentFor(double contentExtent) =>
      math.max(contentExtent + 48, 320);

  /// 第 [index] 条泳道的世界矩形。
  ///
  /// [axis] 为组轴心（横向 = 画布水平中心），[top] 为条带世界起点
  /// （纵向条带的 y / 横向条带首行顶边），[count] 为泳道总数。
  static Rect rect({
    required int index,
    required int count,
    required bool vertical,
    required double axis,
    required double top,
    required double extent,
  }) {
    final int safeCount = math.max(count, 1);
    final int safeIndex = index.clamp(0, safeCount - 1);
    if (vertical) {
      final double total = safeCount * WbContextMetrics.flowLaneWidth;
      return Rect.fromLTWH(
        axis - total / 2 + safeIndex * WbContextMetrics.flowLaneWidth,
        top,
        WbContextMetrics.flowLaneWidth,
        extent,
      );
    }
    return Rect.fromLTWH(
      axis - extent / 2,
      top + safeIndex * WbContextMetrics.flowLaneHeight,
      extent,
      WbContextMetrics.flowLaneHeight,
    );
  }
}

// ---------------------------------------------------------------------------
// 模板库（§9：内置模板，一键填充）
// ---------------------------------------------------------------------------

/// 流程图模板定义。
class WbFlowTemplate {
  /// 创建模板。
  const WbFlowTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.build,
  });

  /// 模板 id。
  final String id;

  /// 模板名。
  final String name;

  /// 说明文本。
  final String description;

  /// 图标。
  final IconData icon;

  /// 构建模型（节点位置为占位 0，由编辑器套用自动布局）。
  final WbFlowchartModel Function() build;
}

WbFlowNode _node(
  String id,
  WbFlowNodeType type,
  String text, {
  String? laneId,
  double? width,
  double? height,
  List<String> compartments = const <String>[],
}) {
  return WbFlowNode(
    id: id,
    x: 0,
    y: 0,
    type: type,
    text: text,
    laneId: laneId,
    width: width ?? type.defaultWidth,
    height: height ?? type.defaultHeight,
    compartments: compartments,
  );
}

WbFlowConnector _link(
  String id,
  String from,
  String to, {
  String label = '',
  WbFlowArrowStyle arrow = WbFlowArrowStyle.arrow,
}) {
  return WbFlowConnector(
    id: id,
    fromId: from,
    toId: to,
    label: label,
    arrow: arrow,
  );
}

/// 内置模板列表（7 个：基础流程 / 审批流 / 登录流 / 泳道流程 / 分支流程 /
/// UML 类图 / 数据流图）。
final List<WbFlowTemplate> wbFlowTemplates = <WbFlowTemplate>[
  WbFlowTemplate(
    id: 'basic',
    name: '基础流程',
    description: '开始 → 处理 → 判断 → 结束',
    icon: LinearIcons.flowchart,
    build: () => WbFlowchartModel(
      templateId: 'basic',
      nodes: <WbFlowNode>[
        _node('n1', WbFlowNodeType.start, '开始'),
        _node('n2', WbFlowNodeType.process, '调研需求'),
        _node('n3', WbFlowNodeType.decision, '方案可行?'),
        _node('n4', WbFlowNodeType.process, '实施方案'),
        _node('n5', WbFlowNodeType.end, '结束'),
      ],
      connectors: <WbFlowConnector>[
        _link('c1', 'n1', 'n2'),
        _link('c2', 'n2', 'n3'),
        _link('c3', 'n3', 'n4', label: '是'),
        _link('c4', 'n4', 'n5'),
      ],
    ),
  ),
  WbFlowTemplate(
    id: 'approval',
    name: '审批流程',
    description: '提交 → 审批 → 通过 / 驳回',
    icon: LinearIcons.check,
    build: () => WbFlowchartModel(
      templateId: 'approval',
      nodes: <WbFlowNode>[
        _node('n1', WbFlowNodeType.start, '发起申请'),
        _node('n2', WbFlowNodeType.process, '提交申请单'),
        _node('n3', WbFlowNodeType.decision, '主管审批通过?'),
        _node('n4', WbFlowNodeType.process, '归档存档'),
        _node('n5', WbFlowNodeType.process, '驳回并修改'),
        _node('n6', WbFlowNodeType.end, '结束'),
      ],
      connectors: <WbFlowConnector>[
        _link('c1', 'n1', 'n2'),
        _link('c2', 'n2', 'n3'),
        _link('c3', 'n3', 'n4', label: '通过'),
        _link('c4', 'n4', 'n6'),
        _link('c5', 'n3', 'n5', label: '驳回'),
        _link('c6', 'n5', 'n2', label: '重新提交'),
      ],
    ),
  ),
  WbFlowTemplate(
    id: 'login',
    name: '登录流程',
    description: '输入 → 校验 → 成功 / 失败',
    icon: LinearIcons.permission,
    build: () => WbFlowchartModel(
      templateId: 'login',
      nodes: <WbFlowNode>[
        _node('n1', WbFlowNodeType.start, '开始登录'),
        _node('n2', WbFlowNodeType.inputOutput, '输入账号密码'),
        _node('n3', WbFlowNodeType.process, '服务端校验'),
        _node('n4', WbFlowNodeType.decision, '校验通过?'),
        _node('n5', WbFlowNodeType.process, '进入首页'),
        _node('n6', WbFlowNodeType.end, '登录成功'),
        _node('n7', WbFlowNodeType.process, '提示错误信息'),
        _node('n8', WbFlowNodeType.end, '登录失败'),
      ],
      connectors: <WbFlowConnector>[
        _link('c1', 'n1', 'n2'),
        _link('c2', 'n2', 'n3'),
        _link('c3', 'n3', 'n4'),
        _link('c4', 'n4', 'n5', label: '是'),
        _link('c5', 'n5', 'n6'),
        _link('c6', 'n4', 'n7', label: '否'),
        _link('c7', 'n7', 'n8'),
      ],
    ),
  ),
  WbFlowTemplate(
    id: 'swimlane',
    name: '泳道流程',
    description: '用户 / 产品 / 开发 / 测试 多角色协作',
    icon: LinearIcons.members,
    build: () => WbFlowchartModel(
      templateId: 'swimlane',
      lanes: const <WbFlowLane>[
        WbFlowLane(id: 'lane-user', name: '用户'),
        WbFlowLane(id: 'lane-pm', name: '产品'),
        WbFlowLane(id: 'lane-dev', name: '开发'),
        WbFlowLane(id: 'lane-qa', name: '测试'),
      ],
      nodes: <WbFlowNode>[
        _node('n1', WbFlowNodeType.start, '提出需求', laneId: 'lane-user'),
        _node('n2', WbFlowNodeType.process, '需求评审', laneId: 'lane-pm'),
        _node('n3', WbFlowNodeType.process, '排期计划', laneId: 'lane-pm'),
        _node('n4', WbFlowNodeType.process, '编码开发', laneId: 'lane-dev'),
        _node('n5', WbFlowNodeType.process, '功能测试', laneId: 'lane-qa'),
        _node('n6', WbFlowNodeType.end, '发布上线', laneId: 'lane-dev'),
      ],
      connectors: <WbFlowConnector>[
        _link('c1', 'n1', 'n2'),
        _link('c2', 'n2', 'n3'),
        _link('c3', 'n3', 'n4'),
        _link('c4', 'n4', 'n5'),
        _link('c5', 'n5', 'n6'),
      ],
    ),
  ),
  WbFlowTemplate(
    id: 'branch',
    name: '分支流程',
    description: '条件判断 → 分支 A / B → 汇合',
    icon: LinearIcons.ungroup,
    build: () => WbFlowchartModel(
      templateId: 'branch',
      nodes: <WbFlowNode>[
        _node('n1', WbFlowNodeType.start, '开始'),
        _node('n2', WbFlowNodeType.decision, '条件判断'),
        _node('n3', WbFlowNodeType.process, '处理分支 A'),
        _node('n4', WbFlowNodeType.process, '处理分支 B'),
        _node('n5', WbFlowNodeType.process, '汇合处理'),
        _node('n6', WbFlowNodeType.end, '结束'),
      ],
      connectors: <WbFlowConnector>[
        _link('c1', 'n1', 'n2'),
        _link('c2', 'n2', 'n3', label: '是'),
        _link('c3', 'n2', 'n4', label: '否'),
        _link('c4', 'n3', 'n5'),
        _link('c5', 'n4', 'n5'),
        _link('c6', 'n5', 'n6'),
      ],
    ),
  ),
  WbFlowTemplate(
    id: 'uml',
    name: 'UML 类图',
    description: '类 / 继承关系（空心三角箭头）示例',
    icon: LinearIcons.table,
    build: () => WbFlowchartModel(
      templateId: 'uml',
      nodes: <WbFlowNode>[
        _node(
          'n1',
          WbFlowNodeType.umlClass,
          'Animal',
          compartments: <String>[
            'Animal',
            '+ name: String',
            '+ eat(): void',
          ],
        ),
        _node(
          'n2',
          WbFlowNodeType.umlClass,
          'Dog',
          compartments: <String>['Dog', '+ breed: String', '+ bark(): void'],
        ),
        _node(
          'n3',
          WbFlowNodeType.umlClass,
          'Cat',
          compartments: <String>['Cat', '+ indoor: bool', '+ meow(): void'],
        ),
        _node('n4', WbFlowNodeType.umlNote, 'Dog / Cat 继承 Animal'),
      ],
      connectors: <WbFlowConnector>[
        _link('c1', 'n2', 'n1', label: '继承', arrow: WbFlowArrowStyle.inherit),
        _link('c2', 'n3', 'n1', label: '继承', arrow: WbFlowArrowStyle.inherit),
      ],
    ),
  ),
  WbFlowTemplate(
    id: 'dfd',
    name: '数据流图',
    description: '外部实体 → 处理 → 数据存储（开放箭头）',
    icon: LinearIcons.sync,
    build: () => WbFlowchartModel(
      templateId: 'dfd',
      nodes: <WbFlowNode>[
        _node('n1', WbFlowNodeType.dfdExternal, '用户'),
        _node('n2', WbFlowNodeType.dfdProcess, '登录处理'),
        _node('n3', WbFlowNodeType.dfdStore, '用户表'),
        _node('n4', WbFlowNodeType.dfdExternal, '管理后台'),
      ],
      connectors: <WbFlowConnector>[
        _link('c1', 'n1', 'n2',
            label: '账号密码', arrow: WbFlowArrowStyle.open),
        _link('c2', 'n2', 'n3', label: '查询', arrow: WbFlowArrowStyle.open),
        _link('c3', 'n4', 'n2', label: '配置', arrow: WbFlowArrowStyle.open),
      ],
    ),
  ),
];

// ---------------------------------------------------------------------------
// 编辑器 Widget
// ---------------------------------------------------------------------------

/// 流程图上下文编辑器（全窗三区工作区：左图形库 / 中间画布 / 右属性面板）。
///
/// 自包含：内部维护编辑状态（模型 / 选中 / 连线模式 / 拖拽连线 / 模板展开 /
/// 画布缩放），通过 [onChanged] 上报每次变更后的不可变 [WbFlowchartModel]。
/// 挂载时由外层提供全窗约束（见 `ElementEditorPage` 的全窗分支）；[onClose]
/// 与 [width] 保留为兼容参数——全窗工作区不渲染内嵌关闭按钮，关闭由宿主
/// 页面承担；[width] 不再参与布局。
class WbFlowchartEditor extends StatefulWidget {
  /// 创建编辑器。
  const WbFlowchartEditor({
    super.key,
    this.initialModel,
    this.onChanged,
    this.onClose,
    this.width = WbContextMetrics.defaultWidth,
    this.libraryStore,
    this.componentImporter,
  });

  /// 初始模型（null 使用 [WbFlowchartModel.sample] 并按预览尺寸自动分层）。
  final WbFlowchartModel? initialModel;

  /// 变更回调（每次模型变更后调用）。
  final ValueChanged<WbFlowchartModel>? onChanged;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 面板宽度（兼容保留，不再参与布局）。
  final double width;

  /// 图形库偏好持久化（勾选 / 折叠 / 我的组件；null = 内存模式）。
  final WbFlowLibraryStore? libraryStore;

  /// 组件导入源（宿主文件选择；null 时「我的组件」导入入口隐藏）。
  final Future<WbFlowComponentAsset?> Function()? componentImporter;

  @override
  State<WbFlowchartEditor> createState() => _WbFlowchartEditorState();
}

class _WbFlowchartEditorState extends State<WbFlowchartEditor> {
  /// 双击判定窗口（毫秒）。
  static const int _doubleTapWindowMs = 320;

  /// 画布缩放最小值（25%）。
  static const double _minViewScale = 0.25;

  /// 画布缩放最大值（300%）。
  static const double _maxViewScale = 3.0;

  /// 缩放步进（工具条 +/- 每次按倍数缩放，与画布视图控件风格一致）。
  static const double _zoomStep = 1.2;

  /// 拖拽对齐参考线吸附阈值（世界 px）。
  static const double _snapThreshold = 6;

  late WbFlowchartModel _model;
  final TextEditingController _textController = TextEditingController();

  /// 三段式类系（类 / 接口 / 多例类）右面板分段编辑：类名 / 属性 / 方法。
  final TextEditingController _classNameController = TextEditingController();
  final TextEditingController _attrsController = TextEditingController();
  final TextEditingController _methodsController = TextEditingController();
  final TextEditingController _laneNameController = TextEditingController();
  final TextEditingController _connectorLabelController =
      TextEditingController();

  /// 预览区（世界坐标）渲染盒 key：用于把全局指针位置换算为画布坐标。
  final GlobalKey _canvasKey = GlobalKey(debugLabel: 'wb-flow-canvas');

  /// 编辑器焦点（选中节点 / 连线后接管 Delete / Backspace）。
  final FocusNode _editorFocus = FocusNode(debugLabel: 'wb-flow-editor');

  /// 当前选中的节点 id 集合（支持多选；连线 / 泳道保持单选）。
  Set<String> _selectedNodeIds = <String>{};

  String? _selectedLaneId;
  String? _selectedConnectorId;

  /// 单选节点 id 访问器（恰好选中 1 个时返回，否则 null）。
  String? get _selectedNodeId =>
      _selectedNodeIds.length == 1 ? _selectedNodeIds.first : null;

  /// 连线模式起点（工具栏「连线」按钮 + 依次点击两节点）。
  String? _linkFromId;

  /// 端口拖拽连线：起点节点与所在边、当前指针（世界坐标）、悬停目标节点。
  String? _linkDragFromId;
  WbFlowPortSide? _linkDragSide;
  Offset? _linkDragPoint;
  String? _linkDragTargetId;

  /// 快速建节点（端口拖到空白松手）：起点 / 落点（世界坐标）。
  String? _quickShapeFromId;
  Offset? _quickShapePoint;

  /// 双击检测：节点 / 连线 / 空白的最近一次点击。
  String? _lastNodeTapId;
  int _lastNodeTapAt = 0;
  String? _lastConnectorTapId;
  int _lastConnectorTapAt = 0;
  int _lastBlankTapAt = 0;

  /// 悬停节点（端口圆点显隐）。
  String? _hoveredNodeId;

  /// 内联文本编辑中的节点 id（双击节点进入，Enter / 失焦提交，Esc 取消）。
  String? _editingNodeId;
  final TextEditingController _editingController = TextEditingController();

  WbFlowNodeType _pendingType = WbFlowNodeType.process;
  bool _linking = false;
  bool _templatesOpen = false;

  /// 图形库偏好（勾选显示的库 / 折叠的库 / 我的组件；initState 读入，
  /// 变更即写回 [WbFlowchartEditor.libraryStore]）。
  late WbFlowLibraryPrefs _libraryPrefs;

  /// 组件导入进行中（防重复触发）。
  bool _importingComponent = false;

  /// 画布缩放比例（0.25~3.0；1.0 = 100%）。只影响绘制与指针换算，
  /// 模型坐标始终是世界坐标。
  double _viewScale = 1.0;

  /// 相机平移（场景原点在视口中的屏幕像素位置）。
  ///
  /// 场景坐标 = 世界坐标 + ([WbContextMetrics.flowWorldExtent], ...)，
  /// 初值使世界原点位于视口左上角（“无平移”基线）。
  Offset _panOffset = const Offset(
    -WbContextMetrics.flowWorldExtent,
    -WbContextMetrics.flowWorldExtent,
  );

  /// 空格键按下（按住 + 左键拖拽 = 平移画布）。
  bool _spacePressed = false;

  /// 画布手势：平移模式标记与框选起止点（世界坐标）。
  bool _canvasPanActive = false;
  Offset? _marqueeStart;
  Offset? _marqueeEnd;

  /// 多选拖拽基线（拖动开始时的节点位置快照）与累计位移。
  Map<String, Offset>? _dragBasePositions;
  Offset _dragTotalDelta = Offset.zero;

  /// 当前对齐参考线（世界坐标：竖线取 x、横线取 y）。
  final List<double> _guideXs = <double>[];
  final List<double> _guideYs = <double>[];

  /// 最近一次指针按下的键位（中键拖拽平移判定）。
  int _pressButtons = 0;

  /// 中键拖拽平移进行中（顶层 Listener 直接监听：手势识别器默认只接受
  /// 主键，中键需在指针层单独跟踪）。
  bool _middlePanActive = false;

  bool _layoutPending = false;
  bool _layoutScheduled = false;
  Size? _canvasSize;
  int _idSeq = 0;

  @override
  void initState() {
    super.initState();
    final WbFlowchartModel? initial = widget.initialModel;
    _model = initial ?? WbFlowchartModel.sample();
    // 内部示例模型先按预览尺寸自动分层；外部注入模型尊重其坐标。
    _layoutPending = initial == null;
    _idSeq = _model.nodes.length + 32;
    _libraryPrefs =
        widget.libraryStore?.read() ??
            WbFlowLibraryPrefs(enabledLibraries: _allLibraries);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _textController.dispose();
    _classNameController.dispose();
    _attrsController.dispose();
    _methodsController.dispose();
    _laneNameController.dispose();
    _connectorLabelController.dispose();
    _editingController.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  /// 键盘监听：空格按下 / 抬起（按住空格 + 左键拖拽平移画布）。
  bool _onHardwareKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.space) {
      return false;
    }
    if (event is KeyDownEvent && !_spacePressed) {
      setState(() => _spacePressed = true);
    } else if (event is KeyUpEvent && _spacePressed) {
      setState(() => _spacePressed = false);
    }
    return false;
  }

  // ---- 基础工具 -----------------------------------------------------------

  /// 全部库 id（「更多图形」默认全选集合）。
  static Set<String> get _allLibraries => <String>{
        for (final WbFlowShapeLibrary library in WbFlowShapeLibrary.values)
          library.id,
      };

  String _nextId(String prefix) => '$prefix${++_idSeq}';

  void _emit() => widget.onChanged?.call(_model);

  void _updateModel(WbFlowchartModel next) {
    setState(() => _model = next);
    _emit();
  }

  /// 按 id 查找连线（未命中返回 null）。
  WbFlowConnector? _connectorById(String id) {
    for (final WbFlowConnector connector in _model.connectors) {
      if (connector.id == id) {
        return connector;
      }
    }
    return null;
  }

  /// 更新选中连线标签。
  void _updateConnectorLabel(String value) {
    final String? id = _selectedConnectorId;
    if (id == null) {
      return;
    }
    setState(() => _model = _model.updateConnector(id, label: value));
    _emit();
  }

  /// 有效画布尺寸（未测量时回退默认值）。
  Size _canvas() => _canvasSize ?? WbContextMetrics.flowFallbackCanvas;

  /// 预览区渲染盒（用于全局坐标 → 世界坐标换算）。
  RenderBox? _canvasBox() {
    final BuildContext? ctx = _canvasKey.currentContext;
    final RenderObject? object = ctx?.findRenderObject();
    return object is RenderBox ? object : null;
  }

  /// 全局指针位置 → 世界坐标（经相机逆变换）。
  Offset? _globalToCanvas(Offset globalPosition) {
    final RenderBox? box = _canvasBox();
    if (box == null) {
      return null;
    }
    return _screenToWorld(box.globalToLocal(globalPosition));
  }

  /// 视口局部坐标 → 世界坐标。
  Offset _screenToWorld(Offset local) =>
      (local - _panOffset) / _viewScale -
      const Offset(
        WbContextMetrics.flowWorldExtent,
        WbContextMetrics.flowWorldExtent,
      );

  /// 世界坐标 → 视口局部坐标。
  Offset _worldToScreen(Offset world) =>
      (world +
          const Offset(
            WbContextMetrics.flowWorldExtent,
            WbContextMetrics.flowWorldExtent,
          )) *
      _viewScale +
      _panOffset;

  /// 当前视口中心的世界坐标。
  Offset _viewportCenterWorld() =>
      _screenToWorld(Offset(_canvas().width / 2, _canvas().height / 2));

  void _handleViewport(Size size) {
    _canvasSize = size;
    if (!_layoutPending || _layoutScheduled) {
      return;
    }
    if (size.width <= 1 || size.height <= 1) {
      return;
    }
    _layoutScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _layoutScheduled = false;
      if (!mounted || !_layoutPending) {
        return;
      }
      _runAutoLayout();
    });
  }

  void _runAutoLayout() {
    final Size canvas = _canvas();
    if (canvas.width <= 1 || canvas.height <= 1 || _model.nodes.isEmpty) {
      _layoutPending = false;
      return;
    }
    _layoutPending = false;
    _updateModel(WbFlowAutoLayout.apply(_model, canvas: canvas));
  }

  void _requestRelayout() {
    _layoutPending = true;
    final Size? size = _canvasSize;
    if (size != null && size.width > 1 && size.height > 1) {
      _runAutoLayout();
    }
  }

  // ---- 相机：平移 / 缩放 / 适配 --------------------------------------------

  /// 视口中心锚定缩放（工具条 +/-）。
  void _zoomBy(double factor) =>
      _zoomAt(Offset(_canvas().width / 2, _canvas().height / 2), factor);

  /// 以视口局部点 [anchor] 为锚点按 [factor] 缩放（锚点世界坐标不动）。
  void _zoomAt(Offset anchor, double factor) {
    final double next =
        (_viewScale * factor).clamp(_minViewScale, _maxViewScale);
    if ((next - _viewScale).abs() < 0.0001) {
      return;
    }
    final double ratio = next / _viewScale;
    setState(() {
      _panOffset = anchor - (anchor - _panOffset) * ratio;
      _viewScale = next;
    });
  }

  /// 重置视图：100% 且世界原点回到视口左上角。
  void _resetView() {
    setState(() {
      _viewScale = 1.0;
      _panOffset = const Offset(
        -WbContextMetrics.flowWorldExtent,
        -WbContextMetrics.flowWorldExtent,
      );
    });
  }

  /// 平移画布（视口像素增量），并做世界平面钳制。
  void _panBy(Offset delta) {
    setState(() {
      _panOffset += delta;
      _clampPan();
    });
  }

  /// 结束中键平移（指针抬起 / 取消）。
  void _endMiddlePan() {
    if (!_middlePanActive) {
      return;
    }
    setState(() => _middlePanActive = false);
  }

  /// 钳制：视口中心的世界坐标必须落在 ±[flowWorldExtent] 平面内。
  void _clampPan() {
    final Size viewport = _canvas();
    final Offset center = _screenToWorld(
      Offset(viewport.width / 2, viewport.height / 2),
    );
    const double extent = WbContextMetrics.flowWorldExtent;
    final double cx = center.dx.clamp(-extent, extent);
    final double cy = center.dy.clamp(-extent, extent);
    _panOffset -= Offset(cx - center.dx, cy - center.dy) * _viewScale;
  }

  /// 适配内容：内容包围盒 → 缩放 + 平移（padding 40，scale 上限 1.0
  /// 不放大）；无内容时重置视图。
  void _fitContent() {
    final Size viewport = _canvas();
    if (viewport.width <= 1 || viewport.height <= 1) {
      return;
    }
    final Rect? bounds = _model.contentBounds();
    if (bounds == null || bounds.isEmpty) {
      _resetView();
      return;
    }
    const double padding = 40;
    const double extent = WbContextMetrics.flowWorldExtent;
    final double scale = math.min(
      math.min(
        (viewport.width - padding * 2) / bounds.width,
        (viewport.height - padding * 2) / bounds.height,
      ),
      1.0,
    ).clamp(_minViewScale, _maxViewScale);
    setState(() {
      _viewScale = scale;
      _panOffset = Offset(viewport.width / 2, viewport.height / 2) -
          (bounds.center + const Offset(extent, extent)) * scale;
      _clampPan();
    });
  }

  /// 滚轮：平移（Shift 横移）；Ctrl/⌘ + 滚轮以指针为锚缩放
  /// （factor = exp(-dy / 320)，与黑板视图一致）。
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final double dy = event.scrollDelta.dy;
    if (dy == 0) {
      return;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      _zoomAt(event.localPosition, math.exp(-dy / 320));
      return;
    }
    final Offset delta = keyboard.isShiftPressed
        ? Offset(dy + event.scrollDelta.dx, 0)
        : Offset(event.scrollDelta.dx, dy);
    _panBy(delta);
  }

  /// 泳道世界条带（渲染 / 命中 / 布局共用 [WbFlowLaneGeometry] 口径）。
  ///
  /// 条带组轴心取视口水平中心的世界坐标，起点取内容包围盒顶边
  /// （无内容取 14），长度按内容外扩（空内容 320 兜底）。
  Rect _laneRectFor(int laneIndex) {
    final List<WbFlowLane> lanes = _model.lanes;
    if (lanes.isEmpty) {
      return Rect.zero;
    }
    final bool vertical =
        lanes.first.orientation == WbSwimlaneOrientation.vertical;
    final Rect? content = _model.contentBounds();
    return WbFlowLaneGeometry.rect(
      index: laneIndex,
      count: lanes.length,
      vertical: vertical,
      axis: _canvas().width / 2,
      top: content?.top ?? 14,
      extent: WbFlowLaneGeometry.extentFor(
        content == null ? 0 : (vertical ? content.height : content.width),
      ),
    );
  }

  /// 世界坐标 [local] 所在的泳道 id（不在任何泳道内返回 null）。
  String? _laneIdAt(Offset local) {
    for (int i = 0; i < _model.lanes.length; i++) {
      if (_laneRectFor(i).contains(local)) {
        return _model.lanes[i].id;
      }
    }
    return null;
  }

  /// 视口中心附近寻找不与现有节点重叠的空位（世界坐标网格避让扫描；
  /// 全部冲突时按插入序向外堆叠）。
  Offset _findFreeSpot(double w, double h) {
    final Offset center = _viewportCenterWorld();
    final double baseX = center.dx - w / 2;
    final double baseY = center.dy - h / 2;
    for (int row = 0; row < 14; row++) {
      for (int col = 0; col < 6; col++) {
        final int half = (col + 1) ~/ 2;
        final double dx = (col.isEven ? -1 : 1) * half * (w + 26);
        final Offset candidate = Offset(baseX + dx, baseY + row * (h + 20));
        final Rect rect = candidate & Size(w, h);
        bool clash = false;
        for (final WbFlowNode node in _model.nodes) {
          if (rect.overlaps(node.bounds.inflate(6))) {
            clash = true;
            break;
          }
        }
        if (!clash) {
          return candidate;
        }
      }
    }
    final int index = _model.nodes.length;
    return Offset(
      baseX + (index % 3) * (w + 26),
      baseY + (index ~/ 3) * (h + 20),
    );
  }

  /// 画布坐标 [point] 附近的节点 id（容差 [margin]；[excludeId] 排除自身）。
  String? _nodeIdNear(Offset point, {String? excludeId, double margin = 8}) {
    for (final WbFlowNode node in _model.nodes.reversed) {
      if (node.id == excludeId) {
        continue;
      }
      if (node.bounds.inflate(margin).contains(point)) {
        return node.id;
      }
    }
    return null;
  }

  // ---- 节点操作 -----------------------------------------------------------

  void _selectNode(String? id) {
    setState(() {
      _selectedNodeIds = id == null ? <String>{} : <String>{id};
      _selectedLaneId = null;
      _selectedConnectorId = null;
      _syncInspectorControllers(id);
    });
    if (id != null) {
      _editorFocus.requestFocus();
    }
  }

  void _selectLane(String id) {
    final WbFlowLane? lane = _model.laneById(id);
    setState(() {
      _selectedLaneId = id;
      _selectedNodeIds = <String>{};
      _selectedConnectorId = null;
      _laneNameController.text = lane?.name ?? '';
    });
    _editorFocus.requestFocus();
  }

  /// 添加指定类型节点（世界坐标，钳制在 ±[flowWorldExtent] 平面内）：
  /// [at] 非空 = 拖拽 / 快速建节点落点（节点中心对齐）；无泳道时放在
  /// 当前视口中心附近的空位；有泳道时放入当前泳道条带；
  /// [connectFromId] 非空时同时建立起点到新节点的连线。
  /// 同时记为待添加类型：工具条「添加节点」按钮复用最近创建的类型。
  void _addNodeOfType(WbFlowNodeType type, {Offset? at, String? connectFromId}) {
    if (type != _pendingType) {
      setState(() => _pendingType = type);
    }
    _addNodeOfSpec(
      WbFlowShapeSpec(type: type),
      at: at,
      connectFromId: connectFromId,
    );
  }

  /// 添加节点（载荷泛化：静态图形或「我的组件」）：[at] 非空 = 拖拽 /
  /// 快速建节点落点（节点中心对齐）；无泳道时放在当前视口中心附近的
  /// 空位；有泳道时放入当前泳道条带；组件节点带组件数据，放置尺寸取
  /// 长边 160 等比；[connectFromId] 非空时同时建立起点到新节点的连线。
  void _addNodeOfSpec(
    WbFlowShapeSpec spec, {
    Offset? at,
    String? connectFromId,
  }) {
    const double extent = WbContextMetrics.flowWorldExtent;
    final Size preferred = spec.preferredSize;
    final double w = preferred.width;
    final double h = preferred.height;
    final String id = _nextId('n');
    double x;
    double y;
    String? laneId;
    if (at != null) {
      laneId = _laneIdAt(at);
      x = (at.dx - w / 2).clamp(-extent, extent - w);
      y = (at.dy - h / 2).clamp(-extent, extent - h);
    } else if (_model.lanes.isNotEmpty) {
      laneId = _selectedLaneId ?? _model.lanes.first.id;
      final int laneIndex = _model.lanes.indexWhere(
        (WbFlowLane lane) => lane.id == laneId,
      );
      final Rect rect = _laneRectFor(laneIndex < 0 ? 0 : laneIndex);
      final bool vertical =
          _model.lanes.first.orientation == WbSwimlaneOrientation.vertical;
      final int count = _model.nodesOfLane(laneId).length;
      if (vertical) {
        x = rect.left + (rect.width - w) / 2;
        y = rect.top + 10 + count * (h + 26);
      } else {
        x = rect.left + 10 + count * (w + 26);
        y = rect.top + (rect.height - h) / 2;
      }
    } else {
      final Offset spot = _findFreeSpot(w, h);
      x = spot.dx;
      y = spot.dy;
    }
    final WbFlowNode node = WbFlowNode(
      id: id,
      type: spec.type,
      text: spec.component?.name ?? spec.type.label,
      x: x,
      y: y,
      width: w,
      height: h,
      laneId: laneId,
      component: spec.component,
    );
    WbFlowchartModel next = _model.upsertNode(node);
    if (connectFromId != null && connectFromId != id) {
      next = next.addConnector(
        WbFlowConnector(id: _nextId('c'), fromId: connectFromId, toId: id),
      );
    }
    _updateModel(next);
    _selectNode(id);
  }

  /// 「添加节点」按钮：使用最近创建的类型。
  void _addNode() => _addNodeOfType(_pendingType);

  /// 图形库拖拽落点：在画布指定位置添加节点（静态图形 / 组件同路）。
  void _handleShapeDrop(WbFlowShapeSpec spec, Offset globalOffset) {
    final Offset? local = _globalToCanvas(globalOffset);
    if (local == null) {
      return;
    }
    _addNodeOfSpec(spec, at: local);
  }

  void _removeSelectedNode() {
    if (_selectedNodeIds.isEmpty) {
      return;
    }
    _updateModel(_model.removeNodes(Set<String>.of(_selectedNodeIds)));
    _selectNode(null);
  }

  void _updateNodeText(String value) {
    final String? id = _selectedNodeId;
    if (id == null) {
      return;
    }
    setState(() => _model = _model.updateNode(id, text: value));
    _emit();
  }

  /// 三段式分区当前值（类名 / 属性 / 方法）；类名段在 compartments 空时
  /// 回退 [WbFlowNode.text]，与节点文本渲染口径一致。
  static List<String> _effectiveCompartments(WbFlowNode node) {
    return <String>[
      node.compartments.isNotEmpty ? node.compartments[0] : node.text,
      node.compartments.length > 1 ? node.compartments[1] : '',
      node.compartments.length > 2 ? node.compartments[2] : '',
    ];
  }

  /// 同步右面板控制器：[id] 为三段式类系时拆分写入类名 / 属性 / 方法，
  /// 其余类型写入单行文本控制器；[id] 为 null 时全部清空。
  void _syncInspectorControllers(String? id) {
    final WbFlowNode? node = id == null ? null : _model.nodeById(id);
    _textController.text = node?.text ?? '';
    final bool threeSegment =
        node != null && WbFlowUmlClassLayout.isThreeSegment(node.type);
    final List<String> parts = threeSegment
        ? _effectiveCompartments(node)
        : const <String>['', '', ''];
    _classNameController.text = parts[0];
    _attrsController.text = parts[1];
    _methodsController.text = parts[2];
  }

  /// 右面板三段编辑写回：仅覆盖非空参数段（类名 / 属性 / 方法），其余段
  /// 保持现值（compartments 恒为 3 段，空段在展示时被过滤）。
  void _updateNodeCompartments({
    String? name,
    String? attrs,
    String? methods,
  }) {
    final String? id = _selectedNodeId;
    if (id == null) {
      return;
    }
    final WbFlowNode? node = _model.nodeById(id);
    if (node == null) {
      return;
    }
    final List<String> parts = _effectiveCompartments(node);
    if (name != null) {
      parts[0] = name;
    }
    if (attrs != null) {
      parts[1] = attrs;
    }
    if (methods != null) {
      parts[2] = methods;
    }
    setState(() => _model = _model.updateNode(id, compartments: parts));
    _emit();
  }

  /// 节点拖拽开始：未选中节点先单选；记录整体位移基线（含尺寸）。
  void _handleNodeDragStart(String id) {
    if (!_selectedNodeIds.contains(id)) {
      _selectNode(id);
    }
    _dragBasePositions = <String, Offset>{
      for (final String nodeId in _selectedNodeIds)
        if (_model.nodeById(nodeId) != null)
          nodeId: Offset(_model.nodeById(nodeId)!.x, _model.nodeById(nodeId)!.y),
    };
    _dragTotalDelta = Offset.zero;
    _editorFocus.requestFocus();
  }

  /// 多选整体拖动：累计位移 + 对齐参考线吸附（阈值 6 世界 px）。
  void _dragNode(String id, Offset delta) {
    if (!_selectedNodeIds.contains(id)) {
      _selectNode(id);
    }
    if (_dragBasePositions == null) {
      _handleNodeDragStart(id);
    }
    _dragTotalDelta += delta;
    _applyDrag();
  }

  /// 拖拽结束：清除参考线与基线。
  void _handleNodeDragEnd() {
    final bool hadGuides = _guideXs.isNotEmpty || _guideYs.isNotEmpty;
    _dragBasePositions = null;
    _dragTotalDelta = Offset.zero;
    if (!hadGuides) {
      return;
    }
    setState(() {
      _guideXs.clear();
      _guideYs.clear();
    });
  }

  /// 选中集合（按基线 + 位移）的联合包围盒（世界坐标）。
  Rect _unionOfBase(Map<String, Offset> base) {
    Rect? union;
    for (final MapEntry<String, Offset> entry in base.entries) {
      final WbFlowNode? node = _model.nodeById(entry.key);
      if (node == null) {
        continue;
      }
      final Rect rect = entry.value & Size(node.width, node.height);
      union = union == null ? rect : union.expandToInclude(rect);
    }
    return union ?? Rect.zero;
  }

  /// 应用当前拖动位移（对齐吸附 + 世界平面钳制）。
  void _applyDrag() {
    final Map<String, Offset>? base = _dragBasePositions;
    if (base == null || base.isEmpty) {
      return;
    }
    const double extent = WbContextMetrics.flowWorldExtent;
    Offset delta = _dragTotalDelta;
    final _WbFlowSnap snap =
        _computeSnap(_unionOfBase(base).shift(delta), base.keys.toSet());
    delta += snap.delta;
    final Rect moved = _unionOfBase(base).shift(delta);
    if (moved.left < -extent) {
      delta += Offset(-extent - moved.left, 0);
    }
    if (moved.right > extent) {
      delta -= Offset(moved.right - extent, 0);
    }
    if (moved.top < -extent) {
      delta += Offset(0, -extent - moved.top);
    }
    if (moved.bottom > extent) {
      delta -= Offset(0, moved.bottom - extent);
    }
    setState(() {
      _guideXs
        ..clear()
        ..addAll(snap.guideXs);
      _guideYs
        ..clear()
        ..addAll(snap.guideYs);
      WbFlowchartModel next = _model;
      for (final MapEntry<String, Offset> entry in base.entries) {
        final Offset at = entry.value + delta;
        next = next.updateNode(entry.key, x: at.dx, y: at.dy);
      }
      _model = next;
    });
    _emit();
  }

  /// 对齐参考线：候选 = 其余节点 L/C/R × T/M/B；取最小偏移 ≤ 阈值。
  _WbFlowSnap _computeSnap(Rect moving, Set<String> selectedIds) {
    double? bestDx;
    double? bestDy;
    double? guideX;
    double? guideY;
    void considerX(double target, double source) {
      final double offset = target - source;
      if (offset.abs() <= _snapThreshold &&
          (bestDx == null || offset.abs() < bestDx!.abs())) {
        bestDx = offset;
        guideX = target;
      }
    }

    void considerY(double target, double source) {
      final double offset = target - source;
      if (offset.abs() <= _snapThreshold &&
          (bestDy == null || offset.abs() < bestDy!.abs())) {
        bestDy = offset;
        guideY = target;
      }
    }

    for (final WbFlowNode node in _model.nodes) {
      if (selectedIds.contains(node.id)) {
        continue;
      }
      final Rect r = node.bounds;
      considerX(r.left, moving.left);
      considerX(r.left, moving.center.dx);
      considerX(r.left, moving.right);
      considerX(r.center.dx, moving.left);
      considerX(r.center.dx, moving.center.dx);
      considerX(r.center.dx, moving.right);
      considerX(r.right, moving.left);
      considerX(r.right, moving.center.dx);
      considerX(r.right, moving.right);
      considerY(r.top, moving.top);
      considerY(r.top, moving.center.dy);
      considerY(r.top, moving.bottom);
      considerY(r.center.dy, moving.top);
      considerY(r.center.dy, moving.center.dy);
      considerY(r.center.dy, moving.bottom);
      considerY(r.bottom, moving.top);
      considerY(r.bottom, moving.center.dy);
      considerY(r.bottom, moving.bottom);
    }
    return _WbFlowSnap(
      delta: Offset(bestDx ?? 0, bestDy ?? 0),
      guideXs: guideX == null ? const <double>[] : <double>[guideX!],
      guideYs: guideY == null ? const <double>[] : <double>[guideY!],
    );
  }

  void _handleNodeTap(String id) {
    if (_linking) {
      // 兼容模式：依次点击两个节点建立连线。
      final String? from = _linkFromId;
      if (from == null) {
        setState(() => _linkFromId = id);
        return;
      }
      if (from != id) {
        _updateModel(
          _model.addConnector(
            WbFlowConnector(id: _nextId('c'), fromId: from, toId: id),
          ),
        );
      }
      setState(() => _linkFromId = null);
      return;
    }
    // 手动双击检测：避免 onDoubleTap 与 onTap 竞争导致单击延迟。
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (_lastNodeTapId == id && now - _lastNodeTapAt < _doubleTapWindowMs) {
      _lastNodeTapId = null;
      _selectNode(id);
      _startInlineEdit(id);
      return;
    }
    _lastNodeTapId = id;
    _lastNodeTapAt = now;
    // Shift 点选：加选 / 取消单个节点（多选）。
    if (HardwareKeyboard.instance.isShiftPressed) {
      setState(() {
        if (!_selectedNodeIds.add(id)) {
          _selectedNodeIds.remove(id);
        }
        _selectedLaneId = null;
        _selectedConnectorId = null;
        _syncInspectorControllers(null);
      });
      _editorFocus.requestFocus();
      return;
    }
    _selectNode(id);
  }

  /// 双击节点：进入节点内联文本编辑（Enter / 失焦提交，Esc 取消）；
  /// 三段式类系编辑第一段（类名）。
  void _startInlineEdit(String id) {
    final WbFlowNode? node = _model.nodeById(id);
    if (node == null) {
      return;
    }
    final String initial = WbFlowUmlClassLayout.isThreeSegment(node.type)
        ? _effectiveCompartments(node)[0]
        : node.text;
    _editingController.text = initial;
    _editingController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: initial.length,
    );
    setState(() => _editingNodeId = id);
  }

  /// 提交内联编辑（Enter / 失焦）；三段式类系写回类名段。
  void _submitInlineEdit() {
    final String? id = _editingNodeId;
    if (id == null) {
      return;
    }
    final String value = _editingController.text;
    setState(() {
      _editingNodeId = null;
      final WbFlowNode? node = _model.nodeById(id);
      if (node != null && WbFlowUmlClassLayout.isThreeSegment(node.type)) {
        final List<String> parts = _effectiveCompartments(node);
        parts[0] = value;
        _model = _model.updateNode(id, compartments: parts);
      } else {
        _model = _model.updateNode(id, text: value);
      }
    });
    if (id == _selectedNodeId) {
      _syncInspectorControllers(id);
    }
    _emit();
  }

  /// 取消内联编辑（Esc）。
  void _cancelInlineEdit() {
    if (_editingNodeId == null) {
      return;
    }
    setState(() => _editingNodeId = null);
  }

  void _toggleLinkMode() {
    setState(() {
      _linking = !_linking;
      _linkFromId = null;
    });
  }

  void _setDirection(WbFlowLayoutDirection direction) {
    if (_model.direction == direction) {
      return;
    }
    setState(() => _model = _model.copyWith(direction: direction));
    _requestRelayout();
  }

  // ---- 端口拖拽连线（四向） ------------------------------------------------

  void _handlePortDragStart(
    String nodeId,
    WbFlowPortSide side,
    Offset globalPosition,
  ) {
    final Offset? local = _globalToCanvas(globalPosition);
    if (local == null) {
      return;
    }
    setState(() {
      _linkDragFromId = nodeId;
      _linkDragSide = side;
      _linkDragPoint = local;
      _linkDragTargetId = _nodeIdNear(local, excludeId: nodeId);
      _linkFromId = null;
    });
  }

  void _handlePortDragUpdate(Offset globalPosition) {
    if (_linkDragFromId == null) {
      return;
    }
    final Offset? local = _globalToCanvas(globalPosition);
    if (local == null) {
      return;
    }
    setState(() {
      _linkDragPoint = local;
      _linkDragTargetId = _nodeIdNear(local, excludeId: _linkDragFromId);
    });
  }

  /// 松手：落目标节点 = 建连线；落空白 = 弹出形状选择浮层（快速建节点）。
  void _handlePortDragEnd() {
    final String? from = _linkDragFromId;
    final String? target = _linkDragTargetId;
    final Offset? point = _linkDragPoint;
    setState(() {
      _linkDragFromId = null;
      _linkDragSide = null;
      _linkDragPoint = null;
      _linkDragTargetId = null;
    });
    if (from == null) {
      return;
    }
    // 未直接落在目标节点时，用更大的容差做一次最近命中兜底。
    final String? to = target ??
        (point == null
            ? null
            : _nodeIdNear(point, excludeId: from, margin: 18));
    if (to != null && to != from) {
      _updateModel(
        _model.addConnector(
          WbFlowConnector(id: _nextId('c'), fromId: from, toId: to),
        ),
      );
      return;
    }
    // 落在空白处：弹出快速建节点浮层（选中即建节点并连线）。
    if (point != null) {
      setState(() {
        _quickShapeFromId = from;
        _quickShapePoint = point;
      });
    }
  }

  void _handlePortDragCancel() {
    if (_linkDragFromId == null) {
      return;
    }
    setState(() {
      _linkDragFromId = null;
      _linkDragSide = null;
      _linkDragPoint = null;
      _linkDragTargetId = null;
    });
  }

  /// 快速建节点：在浮层选择类型 → 落点处建节点并自动连线。
  void _handleQuickShapePick(WbFlowNodeType type) {
    final String? from = _quickShapeFromId;
    final Offset? at = _quickShapePoint;
    setState(() {
      _quickShapeFromId = null;
      _quickShapePoint = null;
    });
    if (from == null || at == null) {
      return;
    }
    _addNodeOfType(type, at: at, connectFromId: from);
  }

  /// 取消快速建节点浮层（Esc / 点空白）。
  void _cancelQuickShape() {
    if (_quickShapeFromId == null) {
      return;
    }
    setState(() {
      _quickShapeFromId = null;
      _quickShapePoint = null;
    });
  }

  // ---- 连线选择 / 删除 ------------------------------------------------------

  /// 命中检测：返回距离 [local] 最近且不超过容差的连线 id。
  String? _hitConnectorId(Offset local) {
    String? best;
    double bestDistance = 9;
    for (final WbFlowConnector connector in _model.connectors) {
      final WbFlowNode? from = _model.nodeById(connector.fromId);
      final WbFlowNode? to = _model.nodeById(connector.toId);
      if (from == null || to == null) {
        continue;
      }
      final List<Offset> points = _connectorRoute(from.bounds, to.bounds);
      for (int i = 0; i + 1 < points.length; i++) {
        final double distance =
            _distanceToSegment(local, points[i], points[i + 1]);
        if (distance < bestDistance) {
          bestDistance = distance;
          best = connector.id;
        }
      }
    }
    return best;
  }

  /// 画布点击：命中连线则选中（同一条连线快速二次点击 = 双击删除），
  /// 否则清空选择并退出连线模式起点。
  /// 画布点击：命中连线则选中（同一条连线快速二次点击 = 双击删除）；
  /// 空白单击清空选择，空白双击 = 适配内容。
  void _handleCanvasTap(Offset local) {
    final String? hit = _hitConnectorId(local);
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (hit != null) {
      if (_lastConnectorTapId == hit &&
          now - _lastConnectorTapAt < _doubleTapWindowMs) {
        _lastConnectorTapId = null;
        _removeConnector(hit);
        return;
      }
      _lastConnectorTapId = hit;
      _lastConnectorTapAt = now;
      setState(() {
        _selectedConnectorId = hit;
        _selectedNodeIds = <String>{};
        _selectedLaneId = null;
        _connectorLabelController.text = _connectorById(hit)?.label ?? '';
      });
      _editorFocus.requestFocus();
      return;
    }
    // 空白：快速二次点击 = 双击空白，适配内容。
    if (now - _lastBlankTapAt < _doubleTapWindowMs) {
      _lastBlankTapAt = 0;
      _fitContent();
      return;
    }
    _lastBlankTapAt = now;
    if (_selectedConnectorId == null &&
        _selectedNodeIds.isEmpty &&
        _selectedLaneId == null &&
        _linkFromId == null &&
        _quickShapeFromId == null) {
      return;
    }
    setState(() {
      _selectedConnectorId = null;
      _selectedNodeIds = <String>{};
      _selectedLaneId = null;
      _linkFromId = null;
      _quickShapeFromId = null;
      _quickShapePoint = null;
    });
  }

  // ---- 画布手势：框选 / 平移 ------------------------------------------------

  /// 画布拖拽开始：[panMode] 为真（空格 / 中键）进入平移，否则框选。
  void _handleCanvasDragStart(Offset world, bool panMode) {
    if (panMode) {
      _canvasPanActive = true;
      return;
    }
    setState(() {
      _marqueeStart = world;
      _marqueeEnd = world;
    });
  }

  /// 画布拖拽更新（世界坐标增量）。
  void _handleCanvasDragUpdate(Offset worldDelta) {
    if (_canvasPanActive) {
      _panBy(worldDelta * _viewScale);
      return;
    }
    final Offset? start = _marqueeStart;
    if (start == null) {
      return;
    }
    setState(() => _marqueeEnd = (_marqueeEnd ?? start) + worldDelta);
  }

  /// 画布拖拽结束：结束平移或应用框选（相交即选；Shift 加选）。
  void _handleCanvasDragEnd() {
    if (_canvasPanActive) {
      _canvasPanActive = false;
      return;
    }
    final Offset? start = _marqueeStart;
    final Offset? end = _marqueeEnd;
    if (start == null || end == null) {
      return;
    }
    final Rect rect = Rect.fromPoints(start, end);
    final bool additive = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      _marqueeStart = null;
      _marqueeEnd = null;
      if (rect.size.shortestSide < 2 && !additive) {
        // 几乎无位移：视为点选空白（不清空，由 tap 路径处理）。
        return;
      }
      if (!additive) {
        _selectedNodeIds = <String>{};
      }
      for (final WbFlowNode node in _model.nodes) {
        if (rect.overlaps(node.bounds)) {
          _selectedNodeIds.add(node.id);
        }
      }
      _selectedConnectorId = null;
      _selectedLaneId = null;
    });
    if (_selectedNodeIds.isNotEmpty) {
      _editorFocus.requestFocus();
    }
  }

  void _removeConnector(String id) {
    _updateModel(_model.removeConnector(id));
    setState(() => _selectedConnectorId = null);
  }

  // ---- 键盘：删除 / 全选 / 微调 / 取消 ---------------------------------------

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (_isEditingText()) {
      // 文本输入中：Esc 取消内联编辑，其余交给输入框处理。
      if (event is KeyDownEvent && key == LogicalKeyboardKey.escape) {
        _cancelInlineEdit();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    // Ctrl/⌘ + A：全选节点。
    if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
        key == LogicalKeyboardKey.keyA) {
      _selectAllNodes();
      return KeyEventResult.handled;
    }
    // 方向键：微调选中节点（1px；Shift 步进 10px）。
    final Map<LogicalKeyboardKey, Offset> arrows =
        <LogicalKeyboardKey, Offset>{
      LogicalKeyboardKey.arrowLeft: const Offset(-1, 0),
      LogicalKeyboardKey.arrowRight: const Offset(1, 0),
      LogicalKeyboardKey.arrowUp: const Offset(0, -1),
      LogicalKeyboardKey.arrowDown: const Offset(0, 1),
    };
    final Offset? arrow = arrows[key];
    if (arrow != null && _selectedNodeIds.isNotEmpty) {
      _nudgeSelectedNodes(arrow * (keyboard.isShiftPressed ? 10 : 1));
      return KeyEventResult.handled;
    }
    // Esc：退出快速建节点浮层 / 连线模式。
    if (key == LogicalKeyboardKey.escape) {
      if (_quickShapeFromId != null || _linking || _linkFromId != null) {
        setState(() {
          _quickShapeFromId = null;
          _quickShapePoint = null;
          _linking = false;
          _linkFromId = null;
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.delete &&
        key != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    final String? connectorId = _selectedConnectorId;
    if (connectorId != null) {
      _removeConnector(connectorId);
      return KeyEventResult.handled;
    }
    if (_selectedNodeIds.isNotEmpty) {
      _removeSelectedNode();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 全选所有节点（Ctrl/⌘ + A）。
  void _selectAllNodes() {
    if (_model.nodes.isEmpty) {
      return;
    }
    setState(() {
      _selectedNodeIds = <String>{
        for (final WbFlowNode node in _model.nodes) node.id,
      };
      _selectedLaneId = null;
      _selectedConnectorId = null;
      _syncInspectorControllers(null);
    });
    _editorFocus.requestFocus();
  }

  /// 方向键微调选中节点（世界坐标）。
  void _nudgeSelectedNodes(Offset delta) {
    if (_selectedNodeIds.isEmpty) {
      return;
    }
    _updateModel(
      _model.translateNodes(Set<String>.of(_selectedNodeIds), delta),
    );
  }

  /// 当前主焦点是否落在文本输入框（含双击编辑弹窗）内。
  bool _isEditingText() {
    final BuildContext? primary = FocusManager.instance.primaryFocus?.context;
    if (primary == null) {
      return false;
    }
    return primary.widget is EditableText ||
        primary.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  // ---- 泳道操作 -----------------------------------------------------------

  void _addLane() {
    final String id = _nextId('lane');
    final WbFlowLane lane = WbFlowLane(
      id: id,
      name: '泳道 ${_model.lanes.length + 1}',
    );
    _updateModel(_model.addLane(lane));
    _selectLane(id);
    _requestRelayout();
  }

  void _removeSelectedLane() {
    final String? id = _selectedLaneId;
    if (id == null) {
      return;
    }
    _updateModel(_model.removeLane(id));
    _selectLane('');
    _requestRelayout();
  }

  void _renameSelectedLane(String name) {
    final String? id = _selectedLaneId;
    if (id == null || id.isEmpty) {
      return;
    }
    setState(() => _model = _model.renameLane(id, name));
    _emit();
  }

  void _moveNodeToLane(String nodeId, String? laneId) {
    setState(() => _model = _model.updateNode(nodeId, laneId: laneId));
    _emit();
    _requestRelayout();
  }

  void _flipLaneOrientation() {
    if (_model.lanes.isEmpty) {
      return;
    }
    setState(() => _model = _model.flipLaneOrientation());
    _emit();
    _requestRelayout();
  }

  // ---- 模板 ---------------------------------------------------------------

  void _applyTemplate(WbFlowTemplate template) {
    final WbFlowchartModel built = template.build();
    setState(() {
      _model = built;
      _idSeq = built.nodes.length + 32;
      _selectedNodeIds = <String>{};
      _selectedLaneId = null;
      _selectedConnectorId = null;
      _linkFromId = null;
      _linkDragFromId = null;
      _linkDragSide = null;
      _linkDragPoint = null;
      _linkDragTargetId = null;
      _templatesOpen = false;
      _layoutPending = true;
    });
    _emit();
    _requestRelayout();
  }

  // ---- 构建 ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final WbFlowNode? selectedNode = _selectedNodeId == null
        ? null
        : _model.nodeById(_selectedNodeId!);
    final WbFlowLane? selectedLane =
        _selectedLaneId == null ? null : _model.laneById(_selectedLaneId!);
    final WbFlowConnector? selectedConnector = _selectedConnectorId == null
        ? null
        : _connectorById(_selectedConnectorId!);
    return Focus(
      focusNode: _editorFocus,
      onKeyEvent: _handleKeyEvent,
      child: WbEditorWorkspace(
        toolbar: _buildToolbar(context),
        child: WbEditorPanes(
          left: _buildLeftPanel(context),
          center: _buildCanvasArea(context),
          right: _buildRightPanel(
            context,
            selectedNode,
            selectedLane,
            selectedConnector,
          ),
        ),
      ),
    );
  }

  /// 左面板：图形库（垂直滚动列表）+ 模板库（展开时，位于图形库下方）。
  Widget _buildLeftPanel(BuildContext context) {
    return Container(
      key: const ValueKey<String>('wb-ctx-flow-left-panel'),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        children: <Widget>[
          _buildShapeLibrary(context),
          if (_templatesOpen) _buildTemplatePanel(context),
        ],
      ),
    );
  }

  /// 右面板：选中节点 / 连线 / 泳道属性（垂直可滚动）。
  Widget _buildRightPanel(
    BuildContext context,
    WbFlowNode? selectedNode,
    WbFlowLane? selectedLane,
    WbFlowConnector? selectedConnector,
  ) {
    return Container(
      key: const ValueKey<String>('wb-ctx-flow-right-panel'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: _buildInspector(
          context,
          selectedNode,
          selectedLane,
          selectedConnector,
        ),
      ),
    );
  }

  /// 中间画布区：无限画布（虚拟平面 ±5000）+ 点阵网格 + 滚轮平移 /
  /// Ctrl+滚轮缩放 + 空格与中键拖拽平移 + 快速建节点浮层。
  Widget _buildCanvasArea(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _handlePointerSignal,
      onPointerDown: (PointerDownEvent event) {
        _pressButtons = event.buttons;
        if (event.buttons & kMiddleMouseButton != 0 && !_middlePanActive) {
          setState(() => _middlePanActive = true);
        }
      },
      onPointerMove: (PointerMoveEvent event) {
        if (_middlePanActive) {
          _panBy(event.delta);
        }
      },
      onPointerUp: (PointerUpEvent _) => _endMiddlePan(),
      onPointerCancel: (PointerCancelEvent _) => _endMiddlePan(),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = Size(constraints.maxWidth, constraints.maxHeight);
          if (size.width > 1 && size.height > 1) {
            _handleViewport(size);
          }
          const double extent = WbContextMetrics.flowWorldExtent;
          return MouseRegion(
            cursor: _spacePressed || _middlePanActive
                ? SystemMouseCursors.grab
                : SystemMouseCursors.basic,
            child: ClipRect(
              child: Container(
                key: _canvasKey,
                color: context.wbColors.canvas,
                child: DragTarget<WbFlowShapeSpec>(
                  onAcceptWithDetails:
                      (DragTargetDetails<WbFlowShapeSpec> details) =>
                          _handleShapeDrop(details.data, details.offset),
                  builder: (
                    BuildContext context,
                    List<WbFlowShapeSpec?> candidates,
                    List<dynamic> rejected,
                  ) {
                    return Container(
                      foregroundDecoration: candidates.isEmpty
                          ? null
                          : BoxDecoration(
                              border: Border.all(
                                color: context.wbColors.primary,
                                width: 1.6,
                              ),
                            ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          // 屏幕空间点阵网格（世界对齐；scale < 0.5 不绘制）。
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _FlowGridPainter(
                                  scale: _viewScale,
                                  origin: _panOffset +
                                      const Offset(extent, extent) * _viewScale,
                                  color: context.wbColors.icon
                                      .withValues(alpha: 0.16),
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: 0,
                              minHeight: 0,
                              maxWidth: double.infinity,
                              maxHeight: double.infinity,
                              child: Transform(
                                key: const ValueKey<String>(
                                  'wb-ctx-flow-preview-transform',
                                ),
                                transform: Matrix4.identity()
                                  ..translateByDouble(
                                    _panOffset.dx,
                                    _panOffset.dy,
                                    0,
                                    1,
                                  )
                                  ..scaleByDouble(
                                    _viewScale,
                                    _viewScale,
                                    1,
                                    1,
                                  ),
                                child: _FlowPreview(
                                  model: _model,
                                  sceneExtent: extent,
                                  laneAxis: size.width / 2,
                                  selectedNodeIds: _selectedNodeIds,
                                  selectedLaneId: _selectedLaneId,
                                  selectedConnectorId: _selectedConnectorId,
                                  linkFromId: _linkFromId,
                                  pendingFromId: _linkDragFromId,
                                  pendingSide: _linkDragSide,
                                  pendingPoint: _linkDragPoint,
                                  pendingTargetId: _linkDragTargetId,
                                  marqueeStart: _marqueeStart,
                                  marqueeEnd: _marqueeEnd,
                                  guideXs: _guideXs,
                                  guideYs: _guideYs,
                                  hoveredNodeId: _hoveredNodeId,
                                  editingNodeId: _editingNodeId,
                                  editingController: _editingController,
                                  spacePressed: _spacePressed,
                                  pressButtons: _pressButtons,
                                  onNodeTap: _handleNodeTap,
                                  onNodeDragStart: _handleNodeDragStart,
                                  onNodeDrag: _dragNode,
                                  onNodeDragEnd: _handleNodeDragEnd,
                                  onNodeHover: (String? id) {
                                    if (id != _hoveredNodeId) {
                                      setState(() => _hoveredNodeId = id);
                                    }
                                  },
                                  onInlineEditSubmit: _submitInlineEdit,
                                  onLaneTap: _selectLane,
                                  onCanvasTap: _handleCanvasTap,
                                  onCanvasDragStart: _handleCanvasDragStart,
                                  onCanvasDragUpdate: _handleCanvasDragUpdate,
                                  onCanvasDragEnd: _handleCanvasDragEnd,
                                  onPortDragStart: _handlePortDragStart,
                                  onPortDragUpdate: _handlePortDragUpdate,
                                  onPortDragEnd: _handlePortDragEnd,
                                  onPortDragCancel: _handlePortDragCancel,
                                ),
                              ),
                            ),
                          ),
                          if (_quickShapeFromId != null &&
                              _quickShapePoint != null)
                            Positioned.fill(
                              child: _buildQuickShapeOverlay(context),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 快速建节点浮层：在松手点附近弹出形状选择（选中即建节点并连线）。
  Widget _buildQuickShapeOverlay(BuildContext context) {
    final Offset? world = _quickShapePoint;
    if (world == null || _quickShapeFromId == null) {
      return const SizedBox.shrink();
    }
    final Size viewport = _canvas();
    final Offset screen = _worldToScreen(world);
    final WbThemeColors colors = context.wbColors;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // 点击浮层外空白 = 取消。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _cancelQuickShape,
          ),
        ),
        Positioned(
          left: (screen.dx + 8).clamp(8.0, math.max(8.0, viewport.width - 248)),
          top: (screen.dy + 8)
              .clamp(8.0, math.max(8.0, viewport.height - 296)),
          width: 240,
          child: Material(
            elevation: 4,
            color: colors.elevated,
            borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 288),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '快速创建并连线',
                        style: WbTypography.caption.copyWith(
                          color: colors.icon,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final WbFlowShapeLibrary library
                        in WbFlowShapeLibrary.values)
                      if (library != WbFlowShapeLibrary.custom) ...<Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 4),
                          child: Text(
                            library.label,
                            style: WbTypography.caption.copyWith(
                              color: colors.icon.withValues(alpha: 0.6),
                              fontSize: 10,
                            ),
                          ),
                        ),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: <Widget>[
                            for (final WbFlowNodeType type
                                in WbFlowNodeType.values)
                              if (type.library == library)
                                WbEditorChip(
                                  key: ValueKey<String>(
                                    'wb-ctx-flow-quick-shape-${type.id}',
                                  ),
                                  label: type.label,
                                  dense: true,
                                  onTap: () => _handleQuickShapePick(type),
                                ),
                          ],
                        ),
                      ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-flow-auto-layout'),
          icon: LinearIcons.grid,
          tooltip: '自动布局（分层摆放）',
          onTap: _runAutoLayout,
        ),
        WbEditorChip(
          key: const ValueKey<String>('wb-ctx-flow-direction-tb'),
          label: WbFlowLayoutDirection.topToBottom.label,
          dense: true,
          selected: _model.direction == WbFlowLayoutDirection.topToBottom,
          onTap: () => _setDirection(WbFlowLayoutDirection.topToBottom),
        ),
        WbEditorChip(
          key: const ValueKey<String>('wb-ctx-flow-direction-lr'),
          label: WbFlowLayoutDirection.leftToRight.label,
          dense: true,
          selected: _model.direction == WbFlowLayoutDirection.leftToRight,
          onTap: () => _setDirection(WbFlowLayoutDirection.leftToRight),
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-flow-add-node'),
          icon: LinearIcons.add,
          tooltip: '添加节点（${_pendingType.label}）',
          onTap: _addNode,
        ),
        WbEditorChip(
          key: const ValueKey<String>('wb-ctx-flow-link-mode'),
          label: '连线',
          icon: LinearIcons.connector,
          dense: true,
          selected: _linking,
          onTap: _toggleLinkMode,
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-flow-lane-add'),
          icon: LinearIcons.addPage,
          tooltip: '添加泳道',
          onTap: _addLane,
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-flow-lane-orientation'),
          icon: LinearIcons.distributeVertical,
          tooltip: '切换泳道方向',
          enabled: _model.lanes.isNotEmpty,
          onTap: _flipLaneOrientation,
        ),
        WbEditorChip(
          key: const ValueKey<String>('wb-ctx-flow-template-toggle'),
          label: '模板库',
          icon: LinearIcons.copy,
          dense: true,
          selected: _templatesOpen,
          onTap: () => setState(() => _templatesOpen = !_templatesOpen),
        ),
        // 画布缩放控件：- / 当前百分比 / + / 重置（100%）。
        _buildZoomControls(context),
      ],
    );
  }

  /// 缩放控件（工具条末尾）：缩小 / 百分比文本 / 放大 / 重置 100%。
  Widget _buildZoomControls(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-flow-zoom-out'),
          icon: LinearIcons.zoomOut,
          tooltip: '缩小画布',
          onTap: () => _zoomBy(1 / _zoomStep),
        ),
        SizedBox(
          width: 46,
          child: Text(
            '${(_viewScale * 100).round()}%',
            textAlign: TextAlign.center,
            style: WbTypography.caption.copyWith(color: context.wbColors.icon),
          ),
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-flow-zoom-in'),
          icon: LinearIcons.zoomIn,
          tooltip: '放大画布',
          onTap: () => _zoomBy(_zoomStep),
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-flow-zoom-reset'),
          icon: LinearIcons.refresh,
          tooltip: '重置缩放（100%）',
          onTap: _resetView,
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-flow-fit'),
          icon: LinearIcons.fitScreen,
          tooltip: '适配内容（缩放并居中）',
          onTap: _fitContent,
        ),
      ],
    );
  }

  /// 写回图形库偏好（未注入存储时静默）。
  void _persistLibraryPrefs() {
    widget.libraryStore?.write(_libraryPrefs);
  }

  /// 切换库显示（「更多图形」对话框即时生效并持久化）。
  void _setLibraryEnabled(
    WbFlowShapeLibrary library,
    bool enabled, [
    StateSetter? dialogSetState,
  ]) {
    final Set<String> next = Set<String>.of(_libraryPrefs.enabledLibraries);
    if (enabled) {
      next.add(library.id);
    } else {
      next.remove(library.id);
    }
    setState(
      () => _libraryPrefs = _libraryPrefs.copyWith(enabledLibraries: next),
    );
    _persistLibraryPrefs();
    dialogSetState?.call(() {});
  }

  /// 切换库折叠（折叠态持久化）。
  void _toggleLibraryCollapsed(WbFlowShapeLibrary library) {
    final Set<String> next = Set<String>.of(_libraryPrefs.collapsedLibraries);
    if (!next.remove(library.id)) {
      next.add(library.id);
    }
    setState(
      () => _libraryPrefs = _libraryPrefs.copyWith(collapsedLibraries: next),
    );
    _persistLibraryPrefs();
  }

  /// 导入组件（宿主文件选择 → 归一化 → 追加到「我的组件」并持久化）。
  ///
  /// 导入器未注入 / 用户取消时静默；数量超限与格式错误经对话框提示。
  Future<void> _importComponent([StateSetter? dialogSetState]) async {
    final Future<WbFlowComponentAsset?> Function()? importer =
        widget.componentImporter;
    if (importer == null || _importingComponent) {
      return;
    }
    if (_libraryPrefs.components.length >= WbFlowComponent.maxComponents) {
      await _showComponentMessage(
        '组件数量已达上限（${WbFlowComponent.maxComponents} 个），请先删除不再使用的组件',
      );
      return;
    }
    setState(() => _importingComponent = true);
    try {
      final WbFlowComponentAsset? asset = await importer();
      if (asset == null) {
        return;
      }
      final WbFlowComponent component = await WbFlowComponent.fromAsset(asset);
      if (!mounted) {
        return;
      }
      final List<WbFlowComponent> next = <WbFlowComponent>[
        ..._libraryPrefs.components,
        component,
      ];
      setState(() => _libraryPrefs = _libraryPrefs.copyWith(components: next));
      _persistLibraryPrefs();
      dialogSetState?.call(() {});
    } on FormatException catch (error) {
      if (mounted) {
        await _showComponentMessage(error.message.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _importingComponent = false);
      }
    }
  }

  /// 删除组件（已放置的组件节点保留内嵌数据，不受影响）。
  void _removeComponent(WbFlowComponent component) {
    final List<WbFlowComponent> next = <WbFlowComponent>[
      for (final WbFlowComponent item in _libraryPrefs.components)
        if (item.id != component.id) item,
    ];
    setState(() => _libraryPrefs = _libraryPrefs.copyWith(components: next));
    _persistLibraryPrefs();
  }

  /// 组件导入提示（错误 / 上限；独立对话框，无 Scaffold 依赖）。
  Future<void> _showComponentMessage(String message) {
    final WbThemeColors colors = context.wbColors;
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const ValueKey<String>('wb-ctx-flow-component-message'),
        backgroundColor: colors.elevated,
        content: Text(
          message,
          style: WbTypography.body.copyWith(color: colors.icon),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 统计某库静态图形数量。
  static int _countLibraryTypes(WbFlowShapeLibrary library) {
    int count = 0;
    for (final WbFlowNodeType type in WbFlowNodeType.values) {
      if (type.library == library) {
        count++;
      }
    }
    return count;
  }

  /// 图形库（左面板垂直滚动列表）：按启用库分折叠分组（「我的组件」分组
  /// 单独渲染），点击在当前视口中心添加；按住可拖拽到画布指定位置；
  /// 末尾「更多图形」打开库勾选对话框。
  Widget _buildShapeLibrary(BuildContext context) {
    final Set<String> collapsed = _libraryPrefs.collapsedLibraries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        WbEditorSectionTitle(
          title: '图形库',
          trailing: WbEditorHint('${WbFlowNodeType.values.length - 1} 种图形'),
        ),
        for (final WbFlowShapeLibrary library in WbFlowShapeLibrary.values)
          if (library == WbFlowShapeLibrary.custom)
            if (_libraryPrefs.enabledLibraries.contains(library.id))
              _buildComponentLibraryGroup(
                context,
                collapsed: collapsed.contains(library.id),
              )
            else
              const SizedBox.shrink()
          else if (_libraryPrefs.enabledLibraries.contains(library.id))
            _buildShapeLibraryGroup(
              context,
              library,
              collapsed: collapsed.contains(library.id),
            ),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: WbEditorChip(
              key: const ValueKey<String>('wb-ctx-flow-more-shapes'),
              label: '更多图形',
              icon: LinearIcons.grid,
              dense: true,
              onTap: _openMoreShapesDialog,
            ),
          ),
        ),
      ],
    );
  }

  /// 图形库折叠分组：头部行（旋转箭头 + 库名 + 图形数）与可折叠图形项。
  Widget _buildShapeLibraryGroup(
    BuildContext context,
    WbFlowShapeLibrary library, {
    required bool collapsed,
  }) {
    final List<WbFlowNodeType> types = <WbFlowNodeType>[
      for (final WbFlowNodeType type in WbFlowNodeType.values)
        if (type.library == library) type,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          key: ValueKey<String>('wb-ctx-flow-lib-toggle-${library.id}'),
          onTap: () => _toggleLibraryCollapsed(library),
          borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              children: <Widget>[
                AnimatedRotation(
                  turns: collapsed ? 0 : 0.25,
                  duration: const Duration(milliseconds: 120),
                  child: Icon(
                    LinearIcons.forward,
                    size: 14,
                    color: context.wbColors.icon.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    library.label,
                    style: WbTypography.caption.copyWith(
                      color: context.wbColors.icon.withValues(alpha: 0.65),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${types.length}',
                  style: WbTypography.caption.copyWith(
                    color: context.wbColors.icon.withValues(alpha: 0.45),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          for (final WbFlowNodeType type in types)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _FlowShapeLibraryItem(
                key: ValueKey<String>('wb-ctx-flow-shape-${type.id}'),
                type: type,
                primary: context.wbColors.primary,
                onAdd: () => _addNodeOfType(type),
              ),
            ),
      ],
    );
  }

  /// 「我的组件」分组：组件项（点击 / 拖拽创建组件节点，悬停可删除）；
  /// 组尾导入入口（未注入导入器时隐藏；空列表显示引导文案）。
  Widget _buildComponentLibraryGroup(
    BuildContext context, {
    required bool collapsed,
  }) {
    final List<WbFlowComponent> components = _libraryPrefs.components;
    final bool canImport = widget.componentImporter != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          key: const ValueKey<String>('wb-ctx-flow-lib-toggle-custom'),
          onTap: () => _toggleLibraryCollapsed(WbFlowShapeLibrary.custom),
          borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              children: <Widget>[
                AnimatedRotation(
                  turns: collapsed ? 0 : 0.25,
                  duration: const Duration(milliseconds: 120),
                  child: Icon(
                    LinearIcons.forward,
                    size: 14,
                    color: context.wbColors.icon.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    WbFlowShapeLibrary.custom.label,
                    style: WbTypography.caption.copyWith(
                      color: context.wbColors.icon.withValues(alpha: 0.65),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${components.length}',
                  style: WbTypography.caption.copyWith(
                    color: context.wbColors.icon.withValues(alpha: 0.45),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed) ...<Widget>[
          for (final WbFlowComponent component in components)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _FlowComponentLibraryItem(
                key: ValueKey<String>('wb-ctx-flow-component-${component.id}'),
                component: component,
                primary: context.wbColors.primary,
                onAdd: () => _addNodeOfSpec(
                  WbFlowShapeSpec(
                    type: WbFlowNodeType.customComponent,
                    component: component,
                  ),
                ),
                onRemove: () => _removeComponent(component),
              ),
            ),
          if (components.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '暂无组件，可导入 SVG / 图片作为可复用图形',
                style: WbTypography.caption.copyWith(
                  color: context.wbColors.icon.withValues(alpha: 0.5),
                  fontSize: 10,
                ),
              ),
            ),
          if (canImport)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: WbEditorChip(
                  key: const ValueKey<String>('wb-ctx-flow-component-import'),
                  label: _importingComponent ? '导入中…' : '导入组件',
                  icon: LinearIcons.import,
                  dense: true,
                  onTap: _importingComponent ? null : _importComponent,
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// 「更多图形」对话框：勾选哪些图形库显示在图形库面板（即时生效并持久化）。
  Future<void> _openMoreShapesDialog() async {
    final WbThemeColors colors = context.wbColors;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              key: const ValueKey<String>('wb-ctx-flow-more-shapes-dialog'),
              backgroundColor: colors.elevated,
              title: Text(
                '更多图形',
                style: WbTypography.title.copyWith(color: colors.icon),
              ),
              contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              content: SizedBox(
                width: 320,
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final WbFlowShapeLibrary library
                        in WbFlowShapeLibrary.values)
                      CheckboxListTile(
                        key: ValueKey<String>(
                          'wb-ctx-flow-lib-check-${library.id}',
                        ),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _libraryPrefs.enabledLibraries
                            .contains(library.id),
                        onChanged: (bool? checked) => _setLibraryEnabled(
                          library,
                          checked ?? false,
                          setDialogState,
                        ),
                        title: Text(
                          library.label,
                          style: WbTypography.body.copyWith(
                            color: colors.icon,
                          ),
                        ),
                        subtitle: Text(
                          library == WbFlowShapeLibrary.custom
                              ? '${_libraryPrefs.components.length} 个组件'
                              : '${_countLibraryTypes(library)} 种图形',
                          style: WbTypography.caption.copyWith(
                            color: colors.icon.withValues(alpha: 0.6),
                            fontSize: 10,
                          ),
                        ),
                        secondary: library != WbFlowShapeLibrary.custom
                            ? null
                            : IconButton(
                                key: const ValueKey<String>(
                                  'wb-ctx-flow-component-import-dialog',
                                ),
                                icon: const Icon(LinearIcons.import, size: 18),
                                tooltip: '导入组件（SVG / 图片）',
                                onPressed: widget.componentImporter == null
                                    ? null
                                    : () => _importComponent(setDialogState),
                              ),
                      ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  key: const ValueKey<String>(
                    'wb-ctx-flow-more-shapes-close',
                  ),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('完成'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTemplatePanel(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          WbEditorSectionTitle(
            title: '模板库（点击一键填充，自动布局）',
            trailing: WbEditorHint('${wbFlowTemplates.length} 个内置模板'),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final WbFlowTemplate template in wbFlowTemplates)
                WbEditorChip(
                  key: ValueKey<String>('wb-ctx-flow-template-${template.id}'),
                  label: template.name,
                  icon: template.icon,
                  dense: true,
                  onTap: () => _applyTemplate(template),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInspector(
    BuildContext context,
    WbFlowNode? selectedNode,
    WbFlowLane? selectedLane,
    WbFlowConnector? selectedConnector,
  ) {
    if (_selectedNodeIds.length > 1) {
      // 多选：显示数量 + 批量删除。
      return Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '已选 ${_selectedNodeIds.length} 个节点',
              style: WbTypography.body.copyWith(color: context.wbColors.icon),
            ),
          ),
          WbEditorIconButton(
            key: const ValueKey<String>('wb-ctx-flow-nodes-remove'),
            icon: LinearIcons.delete,
            tooltip: '删除所选节点（连线自动清理）',
            onTap: _removeSelectedNode,
          ),
        ],
      );
    }
    if (selectedConnector != null) {
      return _buildConnectorInspector(context, selectedConnector);
    }
    if (selectedNode != null) {
      final List<Widget> actions = _buildNodeInspectorActions(
        context,
        selectedNode,
      );
      if (WbFlowUmlClassLayout.isThreeSegment(selectedNode.type)) {
        // 三段式类系（类 / 接口 / 多例类）：类名 / 属性 / 方法分段编辑。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('wb-ctx-flow-node-name'),
              controller: _classNameController,
              style: WbTypography.body.copyWith(color: context.wbColors.icon),
              decoration: wbEditorInputDecoration(
                context,
                hint: '${selectedNode.type.label}名',
              ),
              onChanged: (String value) => _updateNodeCompartments(name: value),
            ),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey<String>('wb-ctx-flow-node-attrs'),
              controller: _attrsController,
              style: WbTypography.body.copyWith(color: context.wbColors.icon),
              minLines: 2,
              maxLines: 4,
              decoration: wbEditorInputDecoration(context, hint: '属性（每行一条）'),
              onChanged: (String value) => _updateNodeCompartments(attrs: value),
            ),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey<String>('wb-ctx-flow-node-methods'),
              controller: _methodsController,
              style: WbTypography.body.copyWith(color: context.wbColors.icon),
              minLines: 2,
              maxLines: 4,
              decoration: wbEditorInputDecoration(context, hint: '方法（每行一条）'),
              onChanged: (String value) =>
                  _updateNodeCompartments(methods: value),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[const Spacer(), ...actions],
            ),
          ],
        );
      }
      if (selectedNode.type == WbFlowNodeType.customComponent) {
        // 自定义组件：无文本编辑，仅显示组件名（数据缺失时占位提示）。
        final WbFlowComponent? component = selectedNode.component;
        return Row(
          children: <Widget>[
            Expanded(
              child: Text(
                component == null
                    ? '组件数据缺失（占位显示）'
                    : '组件：${component.name}',
                key: const ValueKey<String>('wb-ctx-flow-node-component'),
                style: WbTypography.body.copyWith(color: context.wbColors.icon),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            ...actions,
          ],
        );
      }
      return Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const ValueKey<String>('wb-ctx-flow-node-text'),
              controller: _textController,
              style: WbTypography.body.copyWith(color: context.wbColors.icon),
              decoration: wbEditorInputDecoration(
                context,
                hint: '节点文本（${selectedNode.type.label}）',
              ),
              onChanged: _updateNodeText,
            ),
          ),
          const SizedBox(width: 6),
          ...actions,
        ],
      );
    }
    if (selectedLane != null) {
      return Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const ValueKey<String>('wb-ctx-flow-lane-name'),
              controller: _laneNameController,
              style: WbTypography.body.copyWith(color: context.wbColors.icon),
              decoration: wbEditorInputDecoration(context, hint: '泳道名称'),
              onChanged: _renameSelectedLane,
            ),
          ),
          const SizedBox(width: 6),
          WbEditorIconButton(
            key: const ValueKey<String>('wb-ctx-flow-lane-remove'),
            icon: LinearIcons.delete,
            tooltip: '删除泳道（节点保留为未分组）',
            onTap: _removeSelectedLane,
          ),
        ],
      );
    }
    return const WbEditorHint(
      '单击选中 / Shift 加选 / 空白拖拽框选；拖拽移动自动对齐参考线；'
      '从节点四边圆点拖拽连线，拖到空白快速建节点；双击节点改字、双击连线删除、'
      '双击空白适配内容；滚轮平移、Ctrl+滚轮缩放、空格拖拽平移。',
    );
  }

  /// 节点属性行尾操作按钮（移动到泳道 + 删除）；节点三种编辑布局共用。
  List<Widget> _buildNodeInspectorActions(
    BuildContext context,
    WbFlowNode node,
  ) {
    return <Widget>[
      if (_model.lanes.isNotEmpty)
        PopupMenuButton<String>(
          key: const ValueKey<String>('wb-ctx-flow-node-lane'),
          tooltip: '移动到泳道',
          icon: Icon(
            LinearIcons.layers,
            size: 16,
            color: context.wbColors.toolbarIcon,
          ),
          onSelected: (String value) =>
              _moveNodeToLane(node.id, value.isEmpty ? null : value),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            const PopupMenuItem<String>(value: '', child: Text('未分组')),
            for (final WbFlowLane lane in _model.lanes)
              PopupMenuItem<String>(value: lane.id, child: Text(lane.name)),
          ],
        ),
      WbEditorIconButton(
        key: const ValueKey<String>('wb-ctx-flow-node-remove'),
        icon: LinearIcons.delete,
        tooltip: '删除节点（连线自动清理）',
        onTap: _removeSelectedNode,
      ),
    ];
  }

  /// 连线属性：标签 + 箭头样式（实心箭头 / 开放箭头 / 继承 / 组合 / 聚合）+ 删除。
  Widget _buildConnectorInspector(
    BuildContext context,
    WbFlowConnector connector,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('wb-ctx-flow-connector-label'),
                controller: _connectorLabelController,
                style: WbTypography.body.copyWith(color: context.wbColors.icon),
                decoration: wbEditorInputDecoration(context, hint: '连线标签'),
                onChanged: _updateConnectorLabel,
              ),
            ),
            const SizedBox(width: 6),
            WbEditorIconButton(
              key: const ValueKey<String>('wb-ctx-flow-connector-remove'),
              icon: LinearIcons.delete,
              tooltip: '删除连线',
              onTap: () => _removeConnector(connector.id),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const WbEditorHint('箭头样式'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final WbFlowArrowStyle style in WbFlowArrowStyle.values)
              WbEditorChip(
                key: ValueKey<String>('wb-ctx-flow-arrow-${style.id}'),
                label: style.label,
                dense: true,
                selected: connector.arrow == style,
                onTap: () => setState(
                  () => _model = _model.updateConnector(connector.id, arrow: style),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 预览区
// ---------------------------------------------------------------------------

/// 画布预览：泳道世界条带 + 连线层 + 画布手势层（框选 / 平移）+
/// 节点 + 四向端口 + 框选/参考线覆盖层 + 内联编辑层。
class _FlowPreview extends StatelessWidget {
  const _FlowPreview({
    required this.model,
    required this.sceneExtent,
    required this.laneAxis,
    required this.selectedNodeIds,
    required this.selectedLaneId,
    required this.selectedConnectorId,
    required this.linkFromId,
    required this.pendingFromId,
    required this.pendingSide,
    required this.pendingPoint,
    required this.pendingTargetId,
    required this.marqueeStart,
    required this.marqueeEnd,
    required this.guideXs,
    required this.guideYs,
    required this.hoveredNodeId,
    required this.editingNodeId,
    required this.editingController,
    required this.spacePressed,
    required this.pressButtons,
    required this.onNodeTap,
    required this.onNodeDragStart,
    required this.onNodeDrag,
    required this.onNodeDragEnd,
    required this.onNodeHover,
    required this.onInlineEditSubmit,
    required this.onLaneTap,
    required this.onCanvasTap,
    required this.onCanvasDragStart,
    required this.onCanvasDragUpdate,
    required this.onCanvasDragEnd,
    required this.onPortDragStart,
    required this.onPortDragUpdate,
    required this.onPortDragEnd,
    required this.onPortDragCancel,
  });

  /// 流程图模型。
  final WbFlowchartModel model;

  /// 虚拟世界平面半径（场景 = 2×extent 见方）。
  final double sceneExtent;

  /// 泳道组轴心（视口水平中心，世界坐标）。
  final double laneAxis;

  /// 选中节点集合（多选）。
  final Set<String> selectedNodeIds;

  /// 选中泳道 id（单选）。
  final String? selectedLaneId;

  /// 选中连线 id（单选）。
  final String? selectedConnectorId;

  /// 兼容模式连线起点（依次点击两节点）。
  final String? linkFromId;

  /// 端口拖拽起点节点 id。
  final String? pendingFromId;

  /// 端口拖拽起始侧。
  final WbFlowPortSide? pendingSide;

  /// 端口拖拽当前指针位置（世界坐标）。
  final Offset? pendingPoint;

  /// 端口拖拽悬停目标节点 id。
  final String? pendingTargetId;

  /// 框选起点 / 终点（世界坐标）。
  final Offset? marqueeStart;
  final Offset? marqueeEnd;

  /// 对齐参考线（世界坐标）。
  final List<double> guideXs;
  final List<double> guideYs;

  /// 当前悬停节点 id（显示四向端口）。
  final String? hoveredNodeId;

  /// 内联编辑中的节点 id。
  final String? editingNodeId;

  /// 内联编辑控制器。
  final TextEditingController editingController;

  /// 空格是否按下（拖拽 = 平移）。
  final bool spacePressed;

  /// 当前按下的鼠标键位（中键拖拽 = 平移）。
  final int pressButtons;

  /// 点选（Shift 加选 / 双击改字由状态层判别）。
  final ValueChanged<String> onNodeTap;

  /// 拖拽开始（选中 + 记录基线）。
  final ValueChanged<String> onNodeDragStart;

  /// 拖拽增量（世界坐标）。
  final void Function(String id, Offset delta) onNodeDrag;

  /// 拖拽结束（清理参考线）。
  final VoidCallback onNodeDragEnd;

  /// 悬停变化（null = 离开全部节点）。
  final ValueChanged<String?> onNodeHover;

  /// 内联编辑提交（Enter / 失焦）。
  final VoidCallback onInlineEditSubmit;

  /// 泳道表头点击。
  final ValueChanged<String> onLaneTap;

  /// 画布点击（世界坐标；双击空白适配内容）。
  final ValueChanged<Offset> onCanvasTap;

  /// 画布拖拽开始（世界坐标 + 是否平移模式）。
  final void Function(Offset world, bool panMode) onCanvasDragStart;

  /// 画布拖拽更新（世界坐标增量）。
  final ValueChanged<Offset> onCanvasDragUpdate;

  /// 画布拖拽结束（结束平移 / 应用框选）。
  final VoidCallback onCanvasDragEnd;

  /// 端口拖拽开始（节点 id + 侧 + 全局坐标）。
  final void Function(
    String nodeId,
    WbFlowPortSide side,
    Offset globalPosition,
  ) onPortDragStart;

  /// 端口拖拽更新（全局坐标）。
  final ValueChanged<Offset> onPortDragUpdate;

  /// 端口拖拽结束。
  final VoidCallback onPortDragEnd;

  /// 端口拖拽取消。
  final VoidCallback onPortDragCancel;

  /// 场景坐标 → 世界坐标。
  Offset _toWorld(Offset scene) => scene - Offset(sceneExtent, sceneExtent);

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final double scene = sceneExtent * 2;
    final Offset shift = Offset(sceneExtent, sceneExtent);
    return SizedBox(
      width: scene,
      height: scene,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ..._buildLaneBands(context, shift),
          // 连线层：世界坐标绘制（painter 内部整体平移 sceneOrigin）。
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: WbFlowConnectorPainter(
                  model: model,
                  sceneOrigin: shift,
                  selectedNodeIds: selectedNodeIds,
                  selectedConnectorId: selectedConnectorId,
                  pendingFromId: pendingFromId,
                  pendingSide: pendingSide,
                  pendingPoint: pendingPoint,
                  pendingTargetId: pendingTargetId,
                  colors: colors,
                ),
              ),
            ),
          ),
          // 画布手势层：点选连线/空白（双击空白适配内容）；越 slop 拖拽
          // = 框选；空格 / 中键拖拽 = 平移。场景 = 世界 + shift，故
          // delta 无需换算，起点经 [_toWorld] 归一。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (TapUpDetails details) =>
                  onCanvasTap(_toWorld(details.localPosition)),
              onPanStart: (DragStartDetails details) => onCanvasDragStart(
                _toWorld(details.localPosition),
                spacePressed || (pressButtons & kMiddleMouseButton) != 0,
              ),
              onPanUpdate: (DragUpdateDetails details) =>
                  onCanvasDragUpdate(details.delta),
              onPanEnd: (DragEndDetails details) => onCanvasDragEnd(),
              onPanCancel: onCanvasDragEnd,
            ),
          ),
          ..._buildLaneHeaders(context, shift),
          // 节点层：点选 / 拖拽 / 悬停 / 双击内联改字。
          for (final WbFlowNode node in model.nodes)
            Positioned(
              left: node.x + shift.dx,
              top: node.y + shift.dy,
              width: node.width,
              height: node.height,
              child: WbFlowNodeView(
                key: ValueKey<String>('wb-ctx-flow-node-${node.id}'),
                node: node,
                selected: selectedNodeIds.contains(node.id),
                highlighted: node.id == linkFromId ||
                    node.id == pendingFromId ||
                    node.id == pendingTargetId,
                editing: node.id == editingNodeId,
                onTap: () => onNodeTap(node.id),
                onDragStart: () => onNodeDragStart(node.id),
                onDragDelta: (Offset delta) => onNodeDrag(node.id, delta),
                onDragEnd: onNodeDragEnd,
                onHover: (bool inside) => onNodeHover(inside ? node.id : null),
              ),
            ),
          // 四向端口层：悬停或选中节点时显示，按住圆点拖拽建立连线。
          for (final WbFlowNode node in model.nodes)
            if (_portsVisible(node))
              for (final WbFlowPortSide side in WbFlowPortSide.values)
                Positioned.fromRect(
                  rect: _portDotRect(node, side).shift(shift),
                  child: _FlowPortDot(
                    key: ValueKey<String>(
                      'wb-ctx-flow-port-${node.id}-${side.id}',
                    ),
                    color: colors.primary,
                    active: node.id == pendingFromId && side == pendingSide,
                    onHover: (bool inside) =>
                        onNodeHover(inside ? node.id : null),
                    onDragStart: (Offset global) =>
                        onPortDragStart(node.id, side, global),
                    onDragUpdate: onPortDragUpdate,
                    onDragEnd: onPortDragEnd,
                    onDragCancel: onPortDragCancel,
                  ),
                ),
          // 框选 / 对齐参考线 / 悬停描边覆盖层（忽略指针）。
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _FlowOverlayPainter(
                  sceneOrigin: shift,
                  primary: colors.primary,
                  marqueeStart: marqueeStart,
                  marqueeEnd: marqueeEnd,
                  guideXs: guideXs,
                  guideYs: guideYs,
                  hoveredBounds: _hoveredBounds(),
                ),
              ),
            ),
          ),
          // 内联编辑层：TextField 覆盖编辑中的节点原位。
          if (_editingNode != null)
            Positioned(
              left: _editingNode!.x + shift.dx,
              top: _editingNode!.y + shift.dy,
              width: _editingNode!.width,
              height: _editingNode!.height,
              child: _FlowInlineEditor(
                controller: editingController,
                onSubmit: onInlineEditSubmit,
              ),
            ),
          // 空画布提示（贴近世界原点，初始视口左上角附近可见）。
          if (model.nodes.isEmpty)
            Positioned(
              left: shift.dx + 10,
              top: shift.dy + 36,
              width: 320,
              child: const IgnorePointer(
                child: WbEditorHint(
                  '画布为空：点击左侧图形库或拖拽图形到此处开始绘制；'
                  '滚轮平移、Ctrl+滚轮缩放、双击空白适配内容。',
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 内联编辑中的节点（null = 未编辑）。
  WbFlowNode? get _editingNode {
    final String? id = editingNodeId;
    return id == null ? null : model.nodeById(id);
  }

  /// 端口是否可见：悬停、选中或作为连线拖拽起点。
  bool _portsVisible(WbFlowNode node) =>
      hoveredNodeId == node.id ||
      selectedNodeIds.contains(node.id) ||
      pendingFromId == node.id;

  /// 端口圆点（18×18，中心位于节点边中点，世界坐标）。
  Rect _portDotRect(WbFlowNode node, WbFlowPortSide side) =>
      Rect.fromCenter(center: side.anchorOn(node.bounds), width: 18, height: 18);

  /// 悬停节点的世界矩形（覆盖层描边；已选中节点由节点本身表达）。
  Rect? _hoveredBounds() {
    final String? id = hoveredNodeId;
    if (id == null || selectedNodeIds.contains(id)) {
      return null;
    }
    return model.nodeById(id)?.bounds;
  }

  /// 泳道世界条带（背景，忽略指针）。
  List<Widget> _buildLaneBands(BuildContext context, Offset shift) {
    final List<WbFlowLane> lanes = model.lanes;
    if (lanes.isEmpty) {
      return const <Widget>[];
    }
    final bool vertical =
        lanes.first.orientation == WbSwimlaneOrientation.vertical;
    final Rect? content = model.contentBounds();
    final double extent = WbFlowLaneGeometry.extentFor(
      content == null ? 0 : (vertical ? content.height : content.width),
    );
    final double top = content?.top ?? 14;
    return <Widget>[
      for (int i = 0; i < lanes.length; i++)
        Positioned.fromRect(
          rect: WbFlowLaneGeometry.rect(
            index: i,
            count: lanes.length,
            vertical: vertical,
            axis: laneAxis,
            top: top,
            extent: extent,
          ).shift(shift),
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: WbContextPalette.flowLaneBackground,
                border: Border(
                  right: vertical
                      ? const BorderSide(color: WbContextPalette.flowLaneBorder)
                      : BorderSide.none,
                  bottom: vertical
                      ? BorderSide.none
                      : const BorderSide(color: WbContextPalette.flowLaneBorder),
                ),
              ),
            ),
          ),
        ),
    ];
  }

  /// 泳道表头（世界条带起点，点击选中泳道）。
  List<Widget> _buildLaneHeaders(BuildContext context, Offset shift) {
    final List<WbFlowLane> lanes = model.lanes;
    if (lanes.isEmpty) {
      return const <Widget>[];
    }
    final bool vertical =
        lanes.first.orientation == WbSwimlaneOrientation.vertical;
    final Rect? content = model.contentBounds();
    final double extent = WbFlowLaneGeometry.extentFor(
      content == null ? 0 : (vertical ? content.height : content.width),
    );
    final double top = content?.top ?? 14;
    final List<Widget> headers = <Widget>[];
    for (int i = 0; i < lanes.length; i++) {
      final WbFlowLane lane = lanes[i];
      final Rect rect = WbFlowLaneGeometry.rect(
        index: i,
        count: lanes.length,
        vertical: vertical,
        axis: laneAxis,
        top: top,
        extent: extent,
      );
      headers.add(
        Positioned(
          left: rect.left + shift.dx,
          top: rect.top + shift.dy,
          width: vertical ? rect.width : 168,
          child: GestureDetector(
            key: ValueKey<String>('wb-ctx-flow-lane-${lane.id}'),
            onTap: () => onLaneTap(lane.id),
            child: _FlowLaneHeader(
              lane: lane,
              count: model.nodesOfLane(lane.id).length,
              selected: lane.id == selectedLaneId,
            ),
          ),
        ),
      );
    }
    return headers;
  }
}

// ---------------------------------------------------------------------------
// 图形库 / 拖拽反馈 / 连线端口
// ---------------------------------------------------------------------------

/// 图形库单项：点击在画布空位添加节点；按住拖拽可放到画布指定位置。
class _FlowShapeLibraryItem extends StatelessWidget {
  const _FlowShapeLibraryItem({
    super.key,
    required this.type,
    required this.primary,
    required this.onAdd,
  });

  /// 图形类型。
  final WbFlowNodeType type;

  /// 主题主色（选中描边）。
  final Color primary;

  /// 点击添加回调。
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Widget content = Material(
      color: colors.cardHover.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      child: InkWell(
        onTap: onAdd,
        borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
        hoverColor: colors.cardHover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            children: <Widget>[
              CustomPaint(
                size: const Size(38, 20),
                painter: WbFlowNodePainter(
                  type: type,
                  selected: false,
                  primary: primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  type.label,
                  overflow: TextOverflow.ellipsis,
                  style: WbTypography.caption
                      .copyWith(color: colors.icon, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Draggable<WbFlowShapeSpec>(
      data: WbFlowShapeSpec(type: type),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _FlowNodeGhost(
        spec: WbFlowShapeSpec(type: type),
        primary: primary,
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: content),
      child: content,
    );
  }
}

/// 图形拖拽反馈：节点尺寸的半透明幽灵，中心对齐指针（静态图形 / 组件
/// 共用；组件按缓存图片渲染，未命中为占位框）。
class _FlowNodeGhost extends StatelessWidget {
  const _FlowNodeGhost({required this.spec, required this.primary});

  final WbFlowShapeSpec spec;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    final Size size = spec.preferredSize;
    return FractionalTranslation(
      translation: const Offset(-0.5, -0.5),
      child: Opacity(
        opacity: 0.85,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: CustomPaint(
            painter: WbFlowNodePainter(
              type: spec.type,
              selected: true,
              primary: primary,
              component: spec.component,
            ),
            child: Center(
              child: Text(
                spec.component?.name ?? spec.type.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF1F2933),
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「我的组件」单项：预览 + 名称 + 悬停删除；点击 / 拖拽创建组件节点。
class _FlowComponentLibraryItem extends StatefulWidget {
  const _FlowComponentLibraryItem({
    super.key,
    required this.component,
    required this.primary,
    required this.onAdd,
    required this.onRemove,
  });

  /// 组件数据。
  final WbFlowComponent component;

  /// 主题主色。
  final Color primary;

  /// 点击添加回调。
  final VoidCallback onAdd;

  /// 删除回调（列表移除；已放置节点不受影响）。
  final VoidCallback onRemove;

  @override
  State<_FlowComponentLibraryItem> createState() =>
      _FlowComponentLibraryItemState();
}

class _FlowComponentLibraryItemState
    extends State<_FlowComponentLibraryItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbFlowShapeSpec spec = WbFlowShapeSpec(
      type: WbFlowNodeType.customComponent,
      component: widget.component,
    );
    final Widget content = Material(
      color: colors.cardHover.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      child: InkWell(
        onTap: widget.onAdd,
        borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
        hoverColor: colors.cardHover,
        child: MouseRegion(
          onEnter: (PointerEnterEvent _) => setState(() => _hovered = true),
          onExit: (PointerExitEvent _) => setState(() => _hovered = false),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              children: <Widget>[
                CustomPaint(
                  size: const Size(38, 20),
                  painter: WbFlowNodePainter(
                    type: WbFlowNodeType.customComponent,
                    selected: false,
                    primary: widget.primary,
                    component: widget.component,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.component.name,
                    overflow: TextOverflow.ellipsis,
                    style: WbTypography.caption
                        .copyWith(color: colors.icon, fontSize: 11),
                  ),
                ),
                if (_hovered)
                  GestureDetector(
                    key: ValueKey<String>(
                      'wb-ctx-flow-component-remove-${widget.component.id}',
                    ),
                    onTap: widget.onRemove,
                    child: Icon(
                      LinearIcons.delete,
                      size: 14,
                      color: colors.icon.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return Draggable<WbFlowShapeSpec>(
      data: spec,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _FlowNodeGhost(spec: spec, primary: widget.primary),
      childWhenDragging: Opacity(opacity: 0.35, child: content),
      child: content,
    );
  }
}

/// 连线端口圆点（节点右侧中点）：按住拖拽即进入连线建立流程。
class _FlowPortDot extends StatelessWidget {
  const _FlowPortDot({
    super.key,
    required this.color,
    required this.active,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    this.onHover,
  });

  /// 主色。
  final Color color;

  /// 激活态（选中 / 作为拖拽起点）。
  final bool active;

  /// 拖拽开始（全局坐标）。
  final ValueChanged<Offset> onDragStart;

  /// 拖拽更新（全局坐标）。
  final ValueChanged<Offset> onDragUpdate;

  /// 拖拽结束（松手时没有可用的结束坐标，目标以最新位置判定）。
  final VoidCallback onDragEnd;

  /// 拖拽取消。
  final VoidCallback onDragCancel;

  /// 悬停变化（可选：悬停端口时保持所属节点的端口可见）。
  final ValueChanged<bool>? onHover;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onEnter: onHover == null
          ? null
          : (PointerEnterEvent _) => onHover!(true),
      onExit:
          onHover == null ? null : (PointerExitEvent _) => onHover!(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (DragStartDetails details) =>
            onDragStart(details.globalPosition),
        onPanUpdate: (DragUpdateDetails details) =>
            onDragUpdate(details.globalPosition),
        onPanEnd: (DragEndDetails _) => onDragEnd(),
        onPanCancel: onDragCancel,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: active ? 12 : 9,
            height: active ? 12 : 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: active ? 1 : 0.55),
              border: Border.all(color: Colors.white, width: 1.2),
            ),
          ),
        ),
      ),
    );
  }
}

/// 泳道标题（名称 + 节点计数）。
class _FlowLaneHeader extends StatelessWidget {
  const _FlowLaneHeader({
    required this.lane,
    required this.count,
    required this.selected,
  });

  final WbFlowLane lane;
  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: selected
            ? colors.primary.withValues(alpha: 0.12)
            : colors.elevated.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              lane.name,
              overflow: TextOverflow.ellipsis,
              style: WbTypography.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? colors.primary : colors.icon,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: WbTypography.caption.copyWith(
              color: colors.icon.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 画布覆盖层（点阵网格 / 框选与参考线 / 内联编辑）
// ---------------------------------------------------------------------------

/// 屏幕空间点阵网格（世界对齐；scale < 0.5 时隐藏）。
class _FlowGridPainter extends CustomPainter {
  const _FlowGridPainter({
    required this.scale,
    required this.origin,
    required this.color,
  });

  /// 当前画布缩放（世界 → 屏幕）。
  final double scale;

  /// 世界原点在视口局部坐标中的位置。
  final Offset origin;

  /// 点阵颜色。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale < 0.5 || size.isEmpty) {
      return;
    }
    final double spacing = 20 * scale;
    if (spacing < 2) {
      return;
    }
    final Paint dot = Paint()..color = color;
    final double x0 = origin.dx % spacing;
    final double y0 = origin.dy % spacing;
    for (double x = x0; x < size.width; x += spacing) {
      for (double y = y0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1.1, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_FlowGridPainter oldDelegate) =>
      oldDelegate.scale != scale ||
      oldDelegate.origin != origin ||
      oldDelegate.color != color;
}

/// 框选 / 对齐参考线 / 悬停描边覆盖层（世界坐标，内部整体平移 sceneOrigin）。
class _FlowOverlayPainter extends CustomPainter {
  const _FlowOverlayPainter({
    required this.sceneOrigin,
    required this.primary,
    this.marqueeStart,
    this.marqueeEnd,
    this.guideXs = const <double>[],
    this.guideYs = const <double>[],
    this.hoveredBounds,
  });

  /// 场景内世界原点平移量。
  final Offset sceneOrigin;

  /// 主题主色（框选 / 参考线 / 悬停描边）。
  final Color primary;

  /// 框选起点 / 终点（世界坐标）。
  final Offset? marqueeStart;
  final Offset? marqueeEnd;

  /// 对齐参考线（世界坐标）。
  final List<double> guideXs;
  final List<double> guideYs;

  /// 悬停节点世界矩形（描边高亮）。
  final Rect? hoveredBounds;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(sceneOrigin.dx, sceneOrigin.dy);
    final Rect? hover = hoveredBounds;
    if (hover != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          hover.inflate(1.5),
          const Radius.circular(WbContextMetrics.flowNodeRadius),
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = primary.withValues(alpha: 0.45),
      );
    }
    final Paint guidePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = primary.withValues(alpha: 0.85);
    for (final double x in guideXs) {
      _drawDashedLine(
        canvas,
        Offset(x, 0),
        Offset(x, size.height),
        guidePaint,
        dash: 5,
        gap: 4,
      );
    }
    for (final double y in guideYs) {
      _drawDashedLine(
        canvas,
        Offset(0, y),
        Offset(size.width, y),
        guidePaint,
        dash: 5,
        gap: 4,
      );
    }
    final Offset? start = marqueeStart;
    final Offset? end = marqueeEnd;
    if (start != null && end != null) {
      final Rect rect = Rect.fromPoints(start, end);
      canvas.drawRect(rect, Paint()..color = primary.withValues(alpha: 0.10));
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = primary.withValues(alpha: 0.9),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FlowOverlayPainter oldDelegate) =>
      oldDelegate.sceneOrigin != sceneOrigin ||
      oldDelegate.primary != primary ||
      oldDelegate.marqueeStart != marqueeStart ||
      oldDelegate.marqueeEnd != marqueeEnd ||
      !listEquals(oldDelegate.guideXs, guideXs) ||
      !listEquals(oldDelegate.guideYs, guideYs) ||
      oldDelegate.hoveredBounds != hoveredBounds;
}

/// 内联编辑框：覆盖节点原位的小型 TextField（Enter / 失焦提交；
/// Esc 取消由编辑器快捷键层处理）。
class _FlowInlineEditor extends StatelessWidget {
  const _FlowInlineEditor({
    required this.controller,
    required this.onSubmit,
  });

  /// 编辑控制器。
  final TextEditingController controller;

  /// 提交回调（Enter / 失焦）。
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: BorderRadius.circular(WbContextMetrics.flowNodeRadius),
          border: Border.all(color: colors.primary, width: 1.6),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: colors.icon.withValues(alpha: 0.16),
              blurRadius: 8,
            ),
          ],
        ),
        child: TextField(
          key: const ValueKey<String>('wb-ctx-flow-node-editor-field'),
          controller: controller,
          autofocus: true,
          expands: true,
          maxLines: null,
          textAlign: TextAlign.center,
          textAlignVertical: TextAlignVertical.center,
          style: WbTypography.label.copyWith(color: colors.icon, fontSize: 12),
          cursorColor: colors.primary,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            border: InputBorder.none,
          ),
          onSubmitted: (String _) => onSubmit(),
          onTapOutside: (PointerDownEvent _) => onSubmit(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 节点视图与绘制
// ---------------------------------------------------------------------------

/// 单个流程图节点（可点选 / 拖拽 / 悬停出端口 / 双击内联改字）。
class WbFlowNodeView extends StatelessWidget {
  /// 创建节点视图。
  const WbFlowNodeView({
    super.key,
    required this.node,
    required this.selected,
    required this.highlighted,
    required this.editing,
    required this.onTap,
    required this.onDragStart,
    required this.onDragDelta,
    required this.onDragEnd,
    required this.onHover,
  });

  /// 节点数据。
  final WbFlowNode node;

  /// 是否选中。
  final bool selected;

  /// 是否处于连线起点 / 目标高亮。
  final bool highlighted;

  /// 是否内联编辑中（编辑层接管文本渲染）。
  final bool editing;

  /// 点选回调（Shift 加选 / 双击改字由状态层判别）。
  final VoidCallback onTap;

  /// 拖拽开始（选中 + 记录基线 / 进入对齐吸附）。
  final VoidCallback onDragStart;

  /// 拖拽增量回调（世界坐标增量）。
  final ValueChanged<Offset> onDragDelta;

  /// 拖拽结束（清理参考线与基线）。
  final VoidCallback onDragEnd;

  /// 悬停变化回调（true 进入 / false 离开）。
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      onEnter: (PointerEnterEvent _) => onHover(true),
      onExit: (PointerExitEvent _) => onHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onPanStart: (DragStartDetails _) => onDragStart(),
        onPanUpdate: (DragUpdateDetails details) => onDragDelta(details.delta),
        onPanEnd: (DragEndDetails _) => onDragEnd(),
        onPanCancel: onDragEnd,
        child: CustomPaint(
          painter: WbFlowNodePainter(
            type: node.type,
            selected: selected,
            highlighted: highlighted,
            primary: colors.primary,
            component: node.component,
          ),
          child: editing ? const SizedBox.expand() : _buildText(colors),
        ),
      ),
    );
  }

  /// 节点文本：类系三段（类 / 接口 / 多例类）按 compartments 渲染（与
  /// 绘制器分隔线对齐）；简单接口带构造型、对象名下划线；参与者名居底、
  /// 包名贴顶、系统边界与生命线名贴顶，其余居中显示 [WbFlowNode.displayText]。
  Widget _buildText(WbThemeColors colors) {
    final TextStyle base = WbTypography.label.copyWith(
      color: colors.icon,
      fontSize: 12,
    );
    if (WbFlowUmlClassLayout.isThreeSegment(node.type)) {
      final List<String> parts = <String>[
        node.compartments.isNotEmpty ? node.compartments[0] : node.text,
        node.compartments.length > 1 ? node.compartments[1] : '',
        node.compartments.length > 2 ? node.compartments[2] : '',
      ];
      final String stereotype = WbFlowUmlClassLayout.stereotypeOf(node.type);
      final TextStyle small = base.copyWith(fontSize: 10);
      return ClipRect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: WbFlowUmlClassLayout.nameBand(
                hasStereotype: stereotype.isNotEmpty,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (stereotype.isNotEmpty)
                        Text(
                          stereotype,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: small.copyWith(
                            color: colors.icon.withValues(alpha: 0.65),
                          ),
                        ),
                      Text(
                        parts[0],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: base.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            for (int i = 1; i < 3; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 3, 6, 0),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      parts[i],
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: small,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (node.type == WbFlowNodeType.umlSimpleInterface) {
      // 简单接口：单段名称框，名称上方 «interface» 构造型。
      return ClipRect(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '«interface»',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    fontSize: 10,
                    color: colors.icon.withValues(alpha: 0.65),
                  ),
                ),
                Text(
                  node.displayText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: base.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final Alignment alignment = switch (node.type) {
      WbFlowNodeType.umlActor => Alignment.bottomCenter,
      WbFlowNodeType.umlPackage => Alignment.topLeft,
      WbFlowNodeType.umlLifeline => Alignment.topCenter,
      WbFlowNodeType.umlSystem => Alignment.topCenter,
      _ => Alignment.center,
    };
    final EdgeInsets padding = switch (node.type) {
      WbFlowNodeType.umlActor => const EdgeInsets.fromLTRB(2, 0, 2, 2),
      WbFlowNodeType.umlPackage => const EdgeInsets.fromLTRB(6, 1, 6, 0),
      WbFlowNodeType.umlNote => const EdgeInsets.fromLTRB(10, 6, 14, 10),
      WbFlowNodeType.umlLifeline => const EdgeInsets.fromLTRB(2, 3, 2, 0),
      WbFlowNodeType.umlSystem => const EdgeInsets.fromLTRB(6, 6, 6, 0),
      _ => const EdgeInsets.symmetric(horizontal: 10),
    };
    final bool compact = node.type == WbFlowNodeType.umlActor ||
        node.type == WbFlowNodeType.umlPackage ||
        node.type == WbFlowNodeType.umlLifeline ||
        node.type == WbFlowNodeType.umlInitial ||
        node.type == WbFlowNodeType.umlFinal ||
        node.type == WbFlowNodeType.umlActivation ||
        node.type == WbFlowNodeType.circuitJunction ||
        node.type.library == WbFlowShapeLibrary.circuit;
    TextStyle textStyle = compact ? base.copyWith(fontSize: 10) : base;
    if (node.type == WbFlowNodeType.umlObject) {
      // UML 对象：名称带下划线。
      textStyle = textStyle.copyWith(decoration: TextDecoration.underline);
    }
    return ClipRect(
      child: Padding(
        padding: padding,
        child: Align(
          alignment: alignment,
          child: Text(
            node.displayText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: textStyle,
          ),
        ),
      ),
    );
  }
}

/// UML 类系（类 / 接口 / 多例类）三段式纵向布局共享助手。
///
/// 编辑器节点文本、主画布绘制器（professional_painter）与形状绘制器
/// （分隔线）共用，保证名带 / 分隔线对齐：名称固定名带（28；带构造型
/// 42），属性 / 方法各占剩余一半。
abstract final class WbFlowUmlClassLayout {
  /// 是否三段式类型（类 / 接口 / 多例类）。
  static bool isThreeSegment(WbFlowNodeType type) =>
      type == WbFlowNodeType.umlClass ||
      type == WbFlowNodeType.umlInterface ||
      type == WbFlowNodeType.umlMultiton;

  /// 名带高度（[hasStereotype] 为真时含构造型行）。
  static double nameBand({required bool hasStereotype}) =>
      hasStereotype ? 42 : 28;

  /// 构造型文案（无则空串；简单接口同为 «interface»）。
  static String stereotypeOf(WbFlowNodeType type) => switch (type) {
        WbFlowNodeType.umlInterface => '«interface»',
        WbFlowNodeType.umlSimpleInterface => '«interface»',
        WbFlowNodeType.umlMultiton => '«多例»',
        _ => '',
      };

  /// 两条分隔线的 y（相对高度 [height]；名带超出高度时自适应钳制）。
  static List<double> dividers(WbFlowNodeType type, double height) {
    final double name = math.min(
      nameBand(hasStereotype: stereotypeOf(type).isNotEmpty),
      height,
    );
    final double rest = math.max(height - name, 0);
    return <double>[name, name + rest / 2];
  }
}

/// 节点形状绘制（§3.2 / §4：圆角矩形 / 菱形 / 平行四边形 / 波浪底 /
/// 圆柱 / 梯形 / 圆形 / 开放矩形；扩充 UML 全谱系 / 电路图 / 组件）。
class WbFlowNodePainter extends CustomPainter {
  /// 创建绘制器（`repaint` 绑定组件缓存：解码完成自动重绘）。
  WbFlowNodePainter({
    required this.type,
    required this.selected,
    this.highlighted = false,
    required this.primary,
    this.component,
  }) : super(repaint: WbFlowComponentCache.instance);

  /// 节点类型。
  final WbFlowNodeType type;

  /// 是否选中。
  final bool selected;

  /// 是否作为连线起点高亮。
  final bool highlighted;

  /// 主题主色（选中描边）。
  final Color primary;

  /// 组件数据（仅 [WbFlowNodeType.customComponent]；缓存命中绘制图片，
  /// 未命中绘制虚线占位框并请求后台解码）。
  final WbFlowComponent? component;

  @override
  void paint(Canvas canvas, Size size) {
    final Color color = type.color;
    final Paint fill = Paint()
      ..style = PaintingStyle.fill
      ..color = type == WbFlowNodeType.annotation
          ? WbContextPalette.flowAnnotation
          : WbContextPalette.softFill(color);
    final Color strokeColor = selected
        ? primary
        : (highlighted ? primary.withValues(alpha: 0.85) : color);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected
          ? 2.4
          : (highlighted ? 2.0 : 1.6)
      ..color = strokeColor;

    switch (type) {
      case WbFlowNodeType.start:
      case WbFlowNodeType.end:
        final RRect rr = RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(size.height / 2),
        );
        canvas.drawRRect(rr, fill);
        canvas.drawRRect(rr, stroke);
      case WbFlowNodeType.process:
        final RRect rr = RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(WbContextMetrics.flowNodeRadius),
        );
        canvas.drawRRect(rr, fill);
        canvas.drawRRect(rr, stroke);
      case WbFlowNodeType.decision:
        final Path path = Path()
          ..moveTo(size.width / 2, 0)
          ..lineTo(size.width, size.height / 2)
          ..lineTo(size.width / 2, size.height)
          ..lineTo(0, size.height / 2)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      case WbFlowNodeType.inputOutput:
        const double skew = 14;
        final Path path = Path()
          ..moveTo(skew, 0)
          ..lineTo(size.width, 0)
          ..lineTo(size.width - skew, size.height)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      case WbFlowNodeType.document:
        final double h = size.height;
        final double w = size.width;
        final Path path = Path()
          ..moveTo(0, 0)
          ..lineTo(w, 0)
          ..lineTo(w, h * 0.8)
          ..quadraticBezierTo(w * 0.66, h * 1.08, w * 0.33, h * 0.92)
          ..quadraticBezierTo(w * 0.16, h * 0.84, 0, h * 0.9)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      case WbFlowNodeType.database:
        final double w = size.width;
        final double h = size.height;
        final double ry = h * 0.16;
        final Path body = Path()
          ..moveTo(0, ry)
          ..lineTo(0, h - ry)
          ..arcToPoint(
            Offset(w, h - ry),
            radius: Radius.elliptical(w / 2, ry),
            clockwise: false,
          )
          ..lineTo(w, ry)
          ..close();
        canvas.drawPath(body, fill);
        canvas.drawPath(body, stroke);
        final Rect top = Rect.fromLTWH(0, 0, w, ry * 2);
        canvas.drawOval(top, fill);
        canvas.drawOval(top, stroke);
      case WbFlowNodeType.manualOperation:
        final Path path = Path()
          ..moveTo(size.width * 0.16, 0)
          ..lineTo(size.width * 0.84, 0)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      case WbFlowNodeType.annotation:
        final Rect rect = Offset.zero & size;
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, stroke..color = WbContextPalette.flowDocument);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, 3, size.height),
          Paint()..color = WbContextPalette.flowDocument,
        );
      case WbFlowNodeType.umlClass:
      case WbFlowNodeType.umlInterface:
      case WbFlowNodeType.umlMultiton:
        // 三段式（共享布局）：名带固定（28；带构造型 42），属性 / 方法各半。
        final RRect classRr = RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(4),
        );
        canvas.drawRRect(classRr, fill);
        canvas.drawRRect(classRr, stroke);
        final Paint divider = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = strokeColor.withValues(alpha: 0.65);
        for (final double y
            in WbFlowUmlClassLayout.dividers(type, size.height)) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), divider);
        }
      case WbFlowNodeType.umlActor:
        _paintActor(canvas, size, fill, stroke);
      case WbFlowNodeType.umlUseCase:
        canvas.drawOval(Offset.zero & size, fill);
        canvas.drawOval(Offset.zero & size, stroke);
      case WbFlowNodeType.umlPackage:
        // 文件夹形：左上标签条 + 主体。
        const double tabHeight = 14;
        final Path packagePath = Path()
          ..moveTo(0, size.height)
          ..lineTo(0, 0)
          ..lineTo(46, 0)
          ..lineTo(54, tabHeight)
          ..lineTo(size.width, tabHeight)
          ..lineTo(size.width, size.height)
          ..close();
        canvas.drawPath(packagePath, fill);
        canvas.drawPath(packagePath, stroke);
      case WbFlowNodeType.umlNote:
        // 折角便签：右上角折三角。
        final Rect note = Offset.zero & size;
        const double fold = 14;
        final Path notePath = Path()
          ..moveTo(note.left, note.top)
          ..lineTo(note.right - fold, note.top)
          ..lineTo(note.right, note.top + fold)
          ..lineTo(note.right, note.bottom)
          ..lineTo(note.left, note.bottom)
          ..close();
        canvas.drawPath(notePath, fill);
        canvas.drawPath(notePath, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(note.right - fold, note.top)
            ..lineTo(note.right - fold, note.top + fold)
            ..lineTo(note.right, note.top + fold),
          stroke,
        );
      case WbFlowNodeType.dfdExternal:
        final Rect external = Offset.zero & size;
        canvas.drawRect(external, fill);
        canvas.drawRect(external, stroke);
        canvas.drawRect(external.deflate(3.5), stroke);
      case WbFlowNodeType.dfdProcess:
        canvas.drawOval(Offset.zero & size, fill);
        canvas.drawOval(Offset.zero & size, stroke);
      case WbFlowNodeType.dfdStore:
        // 数据存储：矩形 + 左侧内竖线。
        final Rect store = Offset.zero & size;
        canvas.drawRect(store, fill);
        canvas.drawRect(store, stroke);
        canvas.drawLine(const Offset(9, 0), Offset(9, size.height), stroke);
      case WbFlowNodeType.umlSimpleClass:
      case WbFlowNodeType.umlSimpleInterface:
      case WbFlowNodeType.umlObject:
        // 单段名称框（简单接口带 «interface»、对象名下划线由文本层渲染）。
        final RRect simpleRr = RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(4),
        );
        canvas.drawRRect(simpleRr, fill);
        canvas.drawRRect(simpleRr, stroke);
      case WbFlowNodeType.umlLifeline:
        // 头框 + 中线虚线生命线尾。
        final double lifeHead = math.min(28.0, size.height / 2);
        final Rect lifeBox = Rect.fromLTWH(0, 0, size.width, lifeHead);
        canvas.drawRect(lifeBox, fill);
        canvas.drawRect(lifeBox, stroke);
        _paintDashedLine(
          canvas,
          Offset(size.width / 2, lifeHead),
          Offset(size.width / 2, size.height),
          stroke,
        );
      case WbFlowNodeType.umlActivation:
        final Rect activation = Offset.zero & size;
        canvas.drawRect(activation, fill);
        canvas.drawRect(activation, stroke);
      case WbFlowNodeType.umlSystem:
        final RRect systemRr = RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(4),
        );
        canvas.drawRRect(systemRr, fill);
        canvas.drawRRect(systemRr, stroke);
      case WbFlowNodeType.umlState:
        final RRect stateRr = RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(10),
        );
        canvas.drawRRect(stateRr, fill);
        canvas.drawRRect(stateRr, stroke);
      case WbFlowNodeType.umlInitial:
        // 初态：实心圆。
        canvas.drawCircle(
          size.center(Offset.zero),
          math.max(math.min(size.width, size.height) / 2 - 1, 1),
          Paint()..color = strokeColor,
        );
      case WbFlowNodeType.umlFinal:
        // 终态：外圈描边 + 内实心圆（牛眼）。
        final Offset finalCenter = size.center(Offset.zero);
        final double finalRadius =
            math.max(math.min(size.width, size.height) / 2 - 1, 1);
        canvas.drawCircle(finalCenter, finalRadius, stroke);
        canvas.drawCircle(
          finalCenter,
          finalRadius * 0.55,
          Paint()..color = strokeColor,
        );
      case WbFlowNodeType.umlChoice:
        // 选择：菱形（分支 / 合并）。
        final Path choicePath = Path()
          ..moveTo(size.width / 2, 0)
          ..lineTo(size.width, size.height / 2)
          ..lineTo(size.width / 2, size.height)
          ..lineTo(0, size.height / 2)
          ..close();
        canvas.drawPath(choicePath, fill);
        canvas.drawPath(choicePath, stroke);
      case WbFlowNodeType.circuitResistor:
        // 电阻：锯齿折线 + 双引线。
        const double resistorLead = 12;
        final double resistorMid = size.height / 2;
        _paintCircuitLeads(canvas, size, resistorLead, stroke);
        final Path resistorPath = Path()..moveTo(resistorLead, resistorMid);
        const int resistorTeeth = 6;
        final double resistorSpan = size.width - resistorLead * 2;
        for (int i = 0; i < resistorTeeth; i++) {
          final double x =
              resistorLead + resistorSpan / resistorTeeth * (i + 0.5);
          final double y =
              resistorMid + (i.isEven ? -1 : 1) * size.height * 0.18;
          resistorPath.lineTo(x, y);
        }
        resistorPath.lineTo(size.width - resistorLead, resistorMid);
        canvas.drawPath(resistorPath, stroke);
      case WbFlowNodeType.circuitCapacitor:
        // 电容：双平行板 + 双引线。
        final double capacitorMid = size.height / 2;
        final double capacitorLeft = size.width / 2 - 5;
        final double capacitorRight = size.width / 2 + 5;
        canvas.drawLine(
          Offset(0, capacitorMid),
          Offset(capacitorLeft, capacitorMid),
          stroke,
        );
        canvas.drawLine(
          Offset(capacitorRight, capacitorMid),
          Offset(size.width, capacitorMid),
          stroke,
        );
        canvas.drawLine(
          Offset(capacitorLeft, size.height * 0.14),
          Offset(capacitorLeft, size.height * 0.86),
          stroke,
        );
        canvas.drawLine(
          Offset(capacitorRight, size.height * 0.14),
          Offset(capacitorRight, size.height * 0.86),
          stroke,
        );
      case WbFlowNodeType.circuitInductor:
        // 电感：四段半圆线圈 + 双引线。
        const double inductorLead = 12;
        final double inductorMid = size.height / 2;
        _paintCircuitLeads(canvas, size, inductorLead, stroke);
        final Path inductorPath = Path()..moveTo(inductorLead, inductorMid);
        final double coilSpan = size.width - inductorLead * 2;
        for (int i = 0; i < 4; i++) {
          inductorPath.arcToPoint(
            Offset(inductorLead + coilSpan / 4 * (i + 1), inductorMid),
            radius: Radius.circular(coilSpan / 8),
            clockwise: true,
          );
        }
        canvas.drawPath(inductorPath, stroke);
      case WbFlowNodeType.circuitDiode:
        // 二极管：三角 + 阴极竖线 + 双引线。
        final double diodeMid = size.height / 2;
        final double diodeLeft = size.width / 2 - 8;
        final double diodeRight = size.width / 2 + 8;
        canvas.drawLine(Offset(0, diodeMid), Offset(diodeLeft, diodeMid), stroke);
        canvas.drawLine(
          Offset(diodeRight, diodeMid),
          Offset(size.width, diodeMid),
          stroke,
        );
        final double diodeTop = size.height * 0.18;
        final double diodeBottom = size.height * 0.82;
        final Path diodePath = Path()
          ..moveTo(diodeLeft, diodeTop)
          ..lineTo(diodeLeft, diodeBottom)
          ..lineTo(diodeRight, diodeMid)
          ..close();
        canvas.drawPath(diodePath, fill);
        canvas.drawPath(diodePath, stroke);
        canvas.drawLine(
          Offset(diodeRight, diodeTop),
          Offset(diodeRight, diodeBottom),
          stroke,
        );
      case WbFlowNodeType.circuitBattery:
        // 电池：长薄板（正）+ 短厚板（负）+ 双引线。
        final double batteryMid = size.height / 2;
        final double batteryLeft = size.width / 2 - 4;
        final double batteryRight = size.width / 2 + 4;
        canvas.drawLine(Offset(0, batteryMid), Offset(batteryLeft, batteryMid), stroke);
        canvas.drawLine(
          Offset(batteryRight, batteryMid),
          Offset(size.width, batteryMid),
          stroke,
        );
        canvas.drawLine(
          Offset(batteryLeft, size.height * 0.2),
          Offset(batteryLeft, size.height * 0.8),
          stroke,
        );
        canvas.drawLine(
          Offset(batteryRight, size.height * 0.32),
          Offset(batteryRight, size.height * 0.68),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke.strokeWidth * 2.2
            ..color = stroke.color,
        );
      case WbFlowNodeType.circuitDcSource:
        // 直流电源：圆圈 + 极性符号 + 双引线。
        final Offset dcCenter = size.center(Offset.zero);
        final double dcRadius = math.min(size.width, size.height) * 0.32;
        canvas.drawLine(
          Offset(0, dcCenter.dy),
          Offset(dcCenter.dx - dcRadius, dcCenter.dy),
          stroke,
        );
        canvas.drawLine(
          Offset(dcCenter.dx + dcRadius, dcCenter.dy),
          Offset(size.width, dcCenter.dy),
          stroke,
        );
        canvas.drawCircle(dcCenter, dcRadius, fill);
        canvas.drawCircle(dcCenter, dcRadius, stroke);
        final Paint polarity = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke.strokeWidth
          ..strokeCap = StrokeCap.round
          ..color = strokeColor;
        final double signHalf = dcRadius * 0.2;
        final Offset plusCenter =
            dcCenter.translate(-dcRadius * 0.32, -dcRadius * 0.32);
        canvas.drawLine(
          plusCenter.translate(-signHalf, 0),
          plusCenter.translate(signHalf, 0),
          polarity,
        );
        canvas.drawLine(
          plusCenter.translate(0, -signHalf),
          plusCenter.translate(0, signHalf),
          polarity,
        );
        final Offset minusCenter =
            dcCenter.translate(dcRadius * 0.32, dcRadius * 0.32);
        canvas.drawLine(
          minusCenter.translate(-signHalf, 0),
          minusCenter.translate(signHalf, 0),
          polarity,
        );
      case WbFlowNodeType.circuitSwitch:
        // 开关：两触点圆点 + 抬起的闸刀 + 双引线。
        final double switchMid = size.height / 2;
        final double switchLeft = size.width * 0.26;
        final double switchRight = size.width * 0.74;
        canvas.drawLine(Offset(0, switchMid), Offset(switchLeft, switchMid), stroke);
        canvas.drawLine(
          Offset(switchRight, switchMid),
          Offset(size.width, switchMid),
          stroke,
        );
        final Paint contact = Paint()..color = strokeColor;
        canvas.drawCircle(Offset(switchLeft, switchMid), 2.2, contact);
        canvas.drawCircle(Offset(switchRight, switchMid), 2.2, contact);
        canvas.drawLine(
          Offset(switchLeft, switchMid),
          Offset(switchRight - 3, switchMid - size.height * 0.28),
          stroke,
        );
      case WbFlowNodeType.circuitLamp:
        // 灯泡：圆 + 叉线 + 双引线。
        final Offset lampCenter = size.center(Offset.zero);
        final double lampRadius = math.min(size.width, size.height) * 0.3;
        canvas.drawLine(
          Offset(0, lampCenter.dy),
          Offset(lampCenter.dx - lampRadius, lampCenter.dy),
          stroke,
        );
        canvas.drawLine(
          Offset(lampCenter.dx + lampRadius, lampCenter.dy),
          Offset(size.width, lampCenter.dy),
          stroke,
        );
        canvas.drawCircle(lampCenter, lampRadius, fill);
        canvas.drawCircle(lampCenter, lampRadius, stroke);
        final double crossArm = lampRadius * 0.6;
        canvas.drawLine(
          lampCenter.translate(-crossArm, -crossArm),
          lampCenter.translate(crossArm, crossArm),
          stroke,
        );
        canvas.drawLine(
          lampCenter.translate(crossArm, -crossArm),
          lampCenter.translate(-crossArm, crossArm),
          stroke,
        );
      case WbFlowNodeType.circuitGround:
        // 接地：竖引线 + 三横线（递减宽度）。
        final double groundX = size.width / 2;
        canvas.drawLine(
          Offset(groundX, 0),
          Offset(groundX, size.height * 0.36),
          stroke,
        );
        canvas.drawLine(
          Offset(groundX - size.width * 0.32, size.height * 0.36),
          Offset(groundX + size.width * 0.32, size.height * 0.36),
          stroke,
        );
        canvas.drawLine(
          Offset(groundX - size.width * 0.18, size.height * 0.64),
          Offset(groundX + size.width * 0.18, size.height * 0.64),
          stroke,
        );
        canvas.drawLine(
          Offset(groundX - size.width * 0.07, size.height * 0.92),
          Offset(groundX + size.width * 0.07, size.height * 0.92),
          stroke,
        );
      case WbFlowNodeType.circuitJunction:
        // 节点：实心圆点。
        canvas.drawCircle(
          size.center(Offset.zero),
          math.max(math.min(size.width, size.height) / 2 - 1, 1),
          Paint()..color = strokeColor,
        );
      case WbFlowNodeType.customComponent:
        _paintComponentShape(canvas, size, strokeColor);
    }
    if (selected) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).inflate(1.5),
          const Radius.circular(WbContextMetrics.flowNodeRadius),
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = primary.withValues(alpha: 0.22),
      );
    }
  }

  /// UML 参与者（火柴人：头 / 躯干 / 手臂 / 腿；底部留给名字）。
  void _paintActor(Canvas canvas, Size size, Paint fill, Paint stroke) {
    final double bodyBottom = size.height * 0.78;
    final double cx = size.width / 2;
    final double headRadius =
        math.min(size.width * 0.22, bodyBottom * 0.18).clamp(4.0, 12.0);
    final double headCy = headRadius + 2;
    canvas.drawCircle(Offset(cx, headCy), headRadius, fill);
    canvas.drawCircle(Offset(cx, headCy), headRadius, stroke);
    final double neckY = headCy + headRadius;
    final double hipY = neckY + (bodyBottom - neckY) * 0.45;
    canvas.drawLine(Offset(cx, neckY), Offset(cx, hipY), stroke);
    final double armY = neckY + (hipY - neckY) * 0.3;
    canvas.drawLine(
      Offset(cx - size.width * 0.3, armY),
      Offset(cx + size.width * 0.3, armY),
      stroke,
    );
    canvas.drawLine(
      Offset(cx, hipY),
      Offset(cx - size.width * 0.24, bodyBottom),
      stroke,
    );
    canvas.drawLine(
      Offset(cx, hipY),
      Offset(cx + size.width * 0.24, bodyBottom),
      stroke,
    );
  }

  /// 电路符号水平双引线（左端子至 [leadLeft]，右侧对称）。
  static void _paintCircuitLeads(
    Canvas canvas,
    Size size,
    double leadLeft,
    Paint stroke,
  ) {
    final double midY = size.height / 2;
    canvas.drawLine(Offset(0, midY), Offset(leadLeft, midY), stroke);
    canvas.drawLine(Offset(size.width - leadLeft, midY), Offset(size.width, midY), stroke);
  }

  /// 两点虚线（[dash] 实线段 + [gap] 间隔）。
  static void _paintDashedLine(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint, {
    double dash = 5,
    double gap = 4,
  }) {
    final Offset delta = to - from;
    final double total = delta.distance;
    if (total <= 0) {
      return;
    }
    final Offset step = delta / total;
    double distance = 0;
    while (distance < total) {
      final double end = math.min(distance + dash, total);
      canvas.drawLine(from + step * distance, from + step * end, paint);
      distance = end + gap;
    }
  }

  /// 虚线圆角矩形（沿路径度量取虚线段）。
  static void _paintDashedRRect(
    Canvas canvas,
    RRect rrect,
    Paint paint, {
    double dash = 6,
    double gap = 4,
  }) {
    final Path path = Path()..addRRect(rrect);
    for (final ui.PathMetric metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  /// 组件节点：缓存命中绘制图片（contain + 圆角裁切）；未命中绘制虚线
  /// 占位框（带图片图标）并请求后台解码。
  void _paintComponentShape(Canvas canvas, Size size, Color strokeColor) {
    final WbFlowComponent? data = component;
    final ui.Image? image = data == null
        ? null
        : WbFlowComponentCache.instance.imageFor(data.cacheKey);
    if (data != null && image == null) {
      WbFlowComponentCache.instance.request(data);
    }
    final RRect rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(WbContextMetrics.flowNodeRadius),
    );
    if (image == null) {
      _paintDashedRRect(
        canvas,
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = strokeColor.withValues(alpha: 0.8),
      );
      _paintComponentGlyph(canvas, size, strokeColor);
      return;
    }
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      _containDstRect(size, image.width.toDouble(), image.height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  /// 组件占位图标（图片语义图标，居中，随尺寸缩放）。
  static void _paintComponentGlyph(Canvas canvas, Size size, Color color) {
    final double glyphSize = math.min(size.width, size.height) * 0.34;
    if (glyphSize < 12) {
      return;
    }
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(LinearIcons.image.codePoint),
        style: TextStyle(
          fontSize: glyphSize,
          fontFamily: LinearIcons.image.fontFamily,
          package: LinearIcons.image.fontPackage,
          color: color.withValues(alpha: 0.75),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
  }

  /// contain 目标矩形：等比缩放到 [size] 内并居中。
  static Rect _containDstRect(
    Size size,
    double imageWidth,
    double imageHeight,
  ) {
    if (imageWidth <= 0 || imageHeight <= 0) {
      return Offset.zero & size;
    }
    final double scale =
        math.min(size.width / imageWidth, size.height / imageHeight);
    return Rect.fromCenter(
      center: (Offset.zero & size).center,
      width: imageWidth * scale,
      height: imageHeight * scale,
    );
  }

  @override
  bool shouldRepaint(WbFlowNodePainter oldDelegate) {
    return oldDelegate.type != type ||
        oldDelegate.selected != selected ||
        oldDelegate.highlighted != highlighted ||
        oldDelegate.primary != primary ||
        oldDelegate.component?.cacheKey != component?.cacheKey;
  }
}

/// 连线绘制：锚点吸附（按相对方位选边）+ 折线路由 + 箭头样式 +
/// 标签 + 选中高亮 + 拖拽连线虚线预览。
///
/// 所有坐标按世界坐标绘制，paint 开头整体平移 [sceneOrigin]。
class WbFlowConnectorPainter extends CustomPainter {
  /// 创建绘制器。
  WbFlowConnectorPainter({
    required this.model,
    required this.sceneOrigin,
    required this.selectedNodeIds,
    required this.colors,
    this.selectedConnectorId,
    this.pendingFromId,
    this.pendingSide,
    this.pendingPoint,
    this.pendingTargetId,
  });

  /// 流程图模型。
  final WbFlowchartModel model;

  /// 场景内世界原点平移量（世界坐标 + sceneOrigin = 场景坐标）。
  final Offset sceneOrigin;

  /// 当前选中节点集合（其连线高亮）。
  final Set<String> selectedNodeIds;

  /// 主题颜色（主色 / 文本色 / 浮层底色）。
  final WbThemeColors colors;

  /// 当前选中连线（加粗高亮；Delete 可删除）。
  final String? selectedConnectorId;

  /// 拖拽连线起点节点 id（null 表示无进行中的端口拖拽）。
  final String? pendingFromId;

  /// 拖拽连线起始侧（起点从该侧端口锚点出发）。
  final WbFlowPortSide? pendingSide;

  /// 拖拽连线当前指针位置（世界坐标）。
  final Offset? pendingPoint;

  /// 拖拽连线悬停目标节点 id（虚线预览吸附用）。
  final String? pendingTargetId;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(sceneOrigin.dx, sceneOrigin.dy);
    for (final WbFlowConnector connector in model.connectors) {
      final WbFlowNode? from = model.nodeById(connector.fromId);
      final WbFlowNode? to = model.nodeById(connector.toId);
      if (from == null || to == null) {
        continue;
      }
      final bool selectedLine = connector.id == selectedConnectorId;
      final bool highlight = selectedLine ||
          selectedNodeIds.contains(connector.fromId) ||
          selectedNodeIds.contains(connector.toId);
      final Color color =
          highlight ? colors.primary : WbContextPalette.flowLine;
      final List<Offset> points = _connectorRoute(from.bounds, to.bounds);
      if (points.length < 2) {
        continue;
      }
      final Path path = Path()..moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      if (selectedLine) {
        // 选中光晕底衬。
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 7
            ..strokeCap = StrokeCap.round
            ..color = colors.primary.withValues(alpha: 0.16),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = selectedLine ? 3 : (highlight ? 2.4 : 2)
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
      _drawLineEnds(canvas, points, connector.arrow, color);
      if (connector.label.isNotEmpty) {
        _drawLabel(canvas, connector.label, points, color);
      }
    }
    _paintPending(canvas);
    canvas.restore();
  }

  /// 按箭头样式绘制两端符号（组合 / 聚合菱形画在起点端）。
  void _drawLineEnds(
    Canvas canvas,
    List<Offset> points,
    WbFlowArrowStyle arrow,
    Color color,
  ) {
    final Offset beforeLast = points[points.length - 2];
    final Offset last = points.last;
    switch (arrow) {
      case WbFlowArrowStyle.arrow:
        _drawArrowHead(canvas, beforeLast, last, color, filled: true);
      case WbFlowArrowStyle.open:
        _drawOpenArrow(canvas, beforeLast, last, color);
      case WbFlowArrowStyle.inherit:
        _drawArrowHead(canvas, beforeLast, last, color, filled: false);
      case WbFlowArrowStyle.composition:
        _drawDiamond(canvas, points.first, points[1], color, filled: true);
      case WbFlowArrowStyle.aggregation:
        _drawDiamond(canvas, points.first, points[1], color, filled: false);
    }
  }

  /// 拖拽连线预览：虚线 + 端点圆点；起点从拖拽侧端口锚点出发，
  /// 悬停目标时吸附到目标边缘。
  void _paintPending(Canvas canvas) {
    final String? fromId = pendingFromId;
    final Offset? point = pendingPoint;
    if (fromId == null || point == null) {
      return;
    }
    final WbFlowNode? from = model.nodeById(fromId);
    if (from == null) {
      return;
    }
    final String? targetId = pendingTargetId;
    final WbFlowNode? target =
        targetId == null ? null : model.nodeById(targetId);
    final Offset start =
        pendingSide?.anchorOn(from.bounds) ?? _edgeAnchor(from.bounds, point);
    final Offset end =
        target == null ? point : _edgeAnchor(target.bounds, start);
    _drawDashedLine(
      canvas,
      start,
      end,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = colors.primary.withValues(alpha: 0.9),
    );
    canvas.drawCircle(
      start,
      3.5,
      Paint()..color = colors.primary.withValues(alpha: 0.7),
    );
    canvas.drawCircle(
      end,
      5,
      Paint()..color = colors.primary.withValues(alpha: 0.9),
    );
    canvas.drawCircle(
      end,
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = colors.elevated,
    );
  }

  /// 三角箭头（实心 = 箭头；空心 = 继承）。
  void _drawArrowHead(
    Canvas canvas,
    Offset from,
    Offset to,
    Color color, {
    required bool filled,
  }) {
    const double head = 9;
    final Offset dir = to - from;
    final double len = dir.distance;
    if (len < 0.001) {
      return;
    }
    final Offset unit = dir / len;
    final Offset normal = Offset(-unit.dy, unit.dx);
    final Offset base = to - unit * head;
    final Path path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(
        base.dx + normal.dx * head * 0.42,
        base.dy + normal.dy * head * 0.42,
      )
      ..lineTo(
        base.dx - normal.dx * head * 0.42,
        base.dy - normal.dy * head * 0.42,
      )
      ..close();
    if (filled) {
      canvas.drawPath(path, Paint()..color = color);
    } else {
      canvas.drawPath(path, Paint()..color = colors.canvas);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color,
      );
    }
  }

  /// 开放箭头（V 形两段线，数据流图）。
  void _drawOpenArrow(Canvas canvas, Offset from, Offset to, Color color) {
    final Offset dir = to - from;
    final double len = dir.distance;
    if (len < 0.001) {
      return;
    }
    final Offset unit = dir / len;
    final Offset normal = Offset(-unit.dy, unit.dx);
    const double head = 9;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawLine(to, to - unit * head + normal * head * 0.45, paint);
    canvas.drawLine(to, to - unit * head - normal * head * 0.45, paint);
  }

  /// UML 菱形（实心 = 组合；空心 = 聚合；画在起点端 [tip]）。
  void _drawDiamond(
    Canvas canvas,
    Offset tip,
    Offset next,
    Color color, {
    required bool filled,
  }) {
    final Offset dir = next - tip;
    final double len = dir.distance;
    if (len < 0.001) {
      return;
    }
    final Offset unit = dir / len;
    final Offset normal = Offset(-unit.dy, unit.dx);
    const double halfLength = 9;
    const double halfWidth = 5;
    final Offset mid = tip + unit * halfLength;
    final Offset back = tip + unit * (halfLength * 2);
    final Path path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(mid.dx + normal.dx * halfWidth, mid.dy + normal.dy * halfWidth)
      ..lineTo(back.dx, back.dy)
      ..lineTo(mid.dx - normal.dx * halfWidth, mid.dy - normal.dy * halfWidth)
      ..close();
    if (filled) {
      canvas.drawPath(path, Paint()..color = color);
    } else {
      canvas.drawPath(path, Paint()..color = colors.canvas);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color,
      );
    }
  }

  void _drawLabel(Canvas canvas, String label, List<Offset> points, Color color) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: label,
        style: WbTypography.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final Offset at = points.length <= 2
        ? Offset.lerp(points.first, points.last, 0.5)!
        : points[points.length ~/ 2];
    final Rect rect = Rect.fromCenter(
      center: at.translate(0, -11),
      width: painter.width + 8,
      height: painter.height + 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = colors.elevated.withValues(alpha: 0.9),
    );
    painter.paint(canvas, Offset(rect.left + 4, rect.top + 1));
    painter.dispose();
  }

  @override
  bool shouldRepaint(WbFlowConnectorPainter oldDelegate) {
    return oldDelegate.model != model ||
        oldDelegate.sceneOrigin != sceneOrigin ||
        !setEquals(oldDelegate.selectedNodeIds, selectedNodeIds) ||
        oldDelegate.colors != colors ||
        oldDelegate.selectedConnectorId != selectedConnectorId ||
        oldDelegate.pendingFromId != pendingFromId ||
        oldDelegate.pendingSide != pendingSide ||
        oldDelegate.pendingPoint != pendingPoint ||
        oldDelegate.pendingTargetId != pendingTargetId;
  }
}

// ---------------------------------------------------------------------------
// 连线路由与几何工具
// ---------------------------------------------------------------------------

/// 节点端口方位（四向：上 / 右 / 下 / 左）。
enum WbFlowPortSide {
  top('top'),
  right('right'),
  bottom('bottom'),
  left('left');

  const WbFlowPortSide(this.id);

  /// 稳定 id（测试 key 后缀）。
  final String id;

  /// 端口在节点矩形上的锚点（世界坐标）。
  Offset anchorOn(Rect rect) => switch (this) {
        WbFlowPortSide.top => Offset(rect.center.dx, rect.top),
        WbFlowPortSide.right => Offset(rect.right, rect.center.dy),
        WbFlowPortSide.bottom => Offset(rect.center.dx, rect.bottom),
        WbFlowPortSide.left => Offset(rect.left, rect.center.dy),
      };
}

/// 拖动对齐吸附结果。
class _WbFlowSnap {
  const _WbFlowSnap({
    required this.delta,
    this.guideXs = const <double>[],
    this.guideYs = const <double>[],
  });

  /// 吸附位移修正。
  final Offset delta;

  /// 命中的竖向参考线 x（世界坐标）。
  final List<double> guideXs;

  /// 命中的横向参考线 y（世界坐标）。
  final List<double> guideYs;
}

/// 锚点吸附 + 正交折线路由（简化：取中心线中点折一次）。
///
/// 提取为顶层函数，供绘制器与「点击命中连线」检测共用同一路由结果。
List<Offset> _connectorRoute(Rect a, Rect b) {
  final Offset ca = a.center;
  final Offset cb = b.center;
  final double dx = cb.dx - ca.dx;
  final double dy = cb.dy - ca.dy;
  if (dy.abs() >= dx.abs()) {
    final bool down = dy >= 0;
    final Offset start = Offset(ca.dx, down ? a.bottom : a.top);
    final Offset end = Offset(cb.dx, down ? b.top : b.bottom);
    if ((start.dx - end.dx).abs() < 2 || (end.dy - start.dy).abs() < 2) {
      return <Offset>[start, end];
    }
    final double midY = (start.dy + end.dy) / 2;
    return <Offset>[
      start,
      Offset(start.dx, midY),
      Offset(end.dx, midY),
      end,
    ];
  }
  final bool right = dx >= 0;
  final Offset start = Offset(right ? a.right : a.left, ca.dy);
  final Offset end = Offset(right ? b.left : b.right, cb.dy);
  if ((start.dy - end.dy).abs() < 2 || (end.dx - start.dx).abs() < 2) {
    return <Offset>[start, end];
  }
  final double midX = (start.dx + end.dx) / 2;
  return <Offset>[
    start,
    Offset(midX, start.dy),
    Offset(midX, end.dy),
    end,
  ];
}

/// 矩形边缘上朝向 [towards] 的边中点（拖拽连线预览吸附用）。
Offset _edgeAnchor(Rect rect, Offset towards) {
  final Offset c = rect.center;
  final double dx = towards.dx - c.dx;
  final double dy = towards.dy - c.dy;
  if (dx.abs() >= dy.abs()) {
    return Offset(dx >= 0 ? rect.right : rect.left, c.dy);
  }
  return Offset(c.dx, dy >= 0 ? rect.bottom : rect.top);
}

/// 点到线段的最短距离（连线点击命中检测）。
double _distanceToSegment(Offset point, Offset a, Offset b) {
  final double abx = b.dx - a.dx;
  final double aby = b.dy - a.dy;
  final double lengthSquared = abx * abx + aby * aby;
  if (lengthSquared <= 0.0001) {
    return (point - a).distance;
  }
  final double t =
      (((point.dx - a.dx) * abx + (point.dy - a.dy) * aby) / lengthSquared)
          .clamp(0.0, 1.0);
  return (point - Offset(a.dx + abx * t, a.dy + aby * t)).distance;
}

/// 沿线段绘制虚线（拖拽连线预览）。
void _drawDashedLine(
  Canvas canvas,
  Offset a,
  Offset b,
  Paint paint, {
  double dash = 6,
  double gap = 4,
}) {
  final double total = (b - a).distance;
  if (total <= 0.01) {
    return;
  }
  final Offset direction = (b - a) / total;
  double progress = 0;
  while (progress < total) {
    final double end = math.min(progress + dash, total);
    canvas.drawLine(a + direction * progress, a + direction * end, paint);
    progress = end + gap;
  }
}
