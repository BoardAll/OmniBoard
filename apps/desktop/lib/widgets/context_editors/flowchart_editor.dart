/// 流程图上下文编辑器（Wave 3.6，交互增强）。
///
/// 依据《流程图模块设计》§10–11 与《白板软件设计文档》§6.7/§7 实现：
/// - **快速创建**：顶部图形库提供开始 / 结束 / 处理 / 判断 / 输入输出等
///   9 种图形，点击即在画布空位添加节点，按住拖拽可放到画布指定位置；
///   经典「类型调色板 + 添加节点」按钮与「连线」模式保留为替代操作；
/// - **拖拽连线**：从节点右侧中点端口圆点按住拖拽，落到目标节点（或目标
///   附近的容差范围）松手即创建连线，拖拽过程显示虚线预览并高亮目标；
/// - **连线选择 / 删除**：点击连线选中（Delete / Backspace 删除），双击
///   连线直接删除；
/// - **双击改字**：双击节点弹出输入框编辑文本（inspector 文本框仍可用）；
/// - **键盘删除**：选中节点 / 连线后按 Delete / Backspace 删除（删除节点
///   时级联清理关联连线）；
/// - **自动布局**：内置纯 Dart 分层摆放算法（Kahn 拓扑分层 + 自适应间距，
///   见 [WbFlowAutoLayout]），非图形学最优，仅演示整理效果；
/// - **手动微调**：预览区节点可直接拖拽（连线实时跟随），拖拽结果通过
///   `onChanged` 上报；
/// - **泳道图**：泳道增删改 / 方向切换 / 节点归类（拖拽或下拉归类）；
/// - **模板库**：内置 5 个模板（基础流程 / 审批流 / 登录流 / 泳道流程 /
///   分支流程），一键填充并自动布局。
///
/// 数据模型为不可变值对象（[WbFlowchartModel] 等），预览区尺寸即世界坐标，
/// 因此组件无需滚动即可在任意有界区域内工作。组件不依赖 Provider /
/// FFI，可在测试与演示环境中独立挂载。
///
/// 第三轮问题 2（全窗工作区）：编辑器改为全窗三区布局（左图形库垂直列表 /
/// 中间最大化画布 / 右属性面板，见 `editor_workspace.dart`），并新增画布
/// 缩放（0.25x–3x，滚轮或工具条控件）。缩放只影响绘制与指针换算，
/// 模型坐标始终是世界坐标。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../miuix_dialog.dart';
import 'context_editor_shell.dart';
import 'editor_workspace.dart';

// ---------------------------------------------------------------------------
// 枚举
// ---------------------------------------------------------------------------

/// 流程图节点类型（对齐《流程图模块设计》§3.1 / §4）。
enum WbFlowNodeType {
  /// 开始。
  start('start', '开始', WbContextPalette.flowStart, LinearIcons.forward),

  /// 结束。
  end('end', '结束', WbContextPalette.flowEnd, LinearIcons.stop),

  /// 处理。
  process('process', '处理', WbContextPalette.flowProcess, LinearIcons.shape),

  /// 判断。
  decision('decision', '判断', WbContextPalette.flowDecision, LinearIcons.warning),

  /// 输入 / 输出。
  inputOutput('inputOutput', '输入/输出', WbContextPalette.flowInputOutput, LinearIcons.import),

  /// 文档。
  document('document', '文档', WbContextPalette.flowDocument, LinearIcons.page),

  /// 数据库。
  database('database', '数据库', WbContextPalette.flowDatabase, LinearIcons.layers),

  /// 手动操作。
  manualOperation('manualOperation', '手动操作', WbContextPalette.flowManual, LinearIcons.hand),

  /// 注释（开放矩形，虚线语义由绘制器用左侧色条表达）。
  annotation('annotation', '注释', WbContextPalette.flowDocument, LinearIcons.comment);

  const WbFlowNodeType(this.id, this.label, this.color, this.icon);

  /// 稳定 id（跨端序列化用）。
  final String id;

  /// 中文显示名。
  final String label;

  /// 节点主色（§12.1）。
  final Color color;

  /// 调色板图标。
  final IconData icon;

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
  });

  /// 节点 id（图内唯一）。
  final String id;

  /// 左上角 x（预览区 / 世界坐标）。
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

  /// 外接矩形。
  Rect get bounds => Rect.fromLTWH(x, y, width, height);

  /// 中心点。
  Offset get center => Offset(x + width / 2, y + height / 2);

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

  /// 复制并覆盖字段。
  WbFlowConnector copyWith({String? id, String? fromId, String? toId, String? label}) {
    return WbFlowConnector(
      id: id ?? this.id,
      fromId: fromId ?? this.fromId,
      toId: toId ?? this.toId,
      label: label ?? this.label,
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
  }) {
    final WbFlowNode? node = nodeById(id);
    if (node == null) {
      return this;
    }
    return upsertNode(
      node.copyWith(x: x, y: y, text: text, type: type, laneId: laneId),
    );
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

/// 自动布局引擎：Kahn 拓扑分层 + 层内稳定排序 + 自适应间距。
///
/// 算法步骤（简化版 Sugiyama，不做交叉最小化/图形优化）：
/// 1. 构图并统计入度；
/// 2. Kahn 拓扑分层（`layer[v] = max(layer[u] + 1)`），环上节点回退为
///    「上游最大层 + 1」，保证不丢节点、不挂死；
/// 3. 层内排序：有泳道时按泳道序，否则按插入序（稳定）；
/// 4. 分方向分配坐标：间距随画布尺寸自适应压缩，结果钳制在画布内。
abstract final class WbFlowAutoLayout {
  /// 对 [model] 执行布局并返回新模型（节点为空时原样返回）。
  ///
  /// [canvas] 为可用画布尺寸（预览区尺寸）；[padding] 为四周留白。
  static WbFlowchartModel apply(
    WbFlowchartModel model, {
    required Size canvas,
    double padding = 14,
    double minGapX = 36,
    double minGapY = 40,
  }) {
    if (model.nodes.isEmpty) {
      return model;
    }
    final double width = math.max(canvas.width, 120);
    final double height = math.max(canvas.height, 120);

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

    // 4. 逐层求坐标。
    final Map<String, List<WbFlowNode>> byLayer = <String, List<WbFlowNode>>{};
    for (final WbFlowNode n in sorted) {
      byLayer.putIfAbsent('${layer[n.id] ?? 0}', () => <WbFlowNode>[]).add(n);
    }
    final int layerCount = maxLayer + 1;
    final bool withLanes = model.lanes.isNotEmpty;
    final int laneCount = math.max(model.lanes.length, 1);
    final bool vertical = !withLanes ||
        model.lanes.first.orientation == WbSwimlaneOrientation.vertical;

    final Map<String, Offset> placed = <String, Offset>{};
    if (model.direction == WbFlowLayoutDirection.topToBottom) {
      // 主方向：y（层），次方向：x（泳道或居中）。
      final List<double> layerHeights = List<double>.filled(layerCount, 0);
      for (int l = 0; l < layerCount; l++) {
        double h = WbContextMetrics.flowNodeHeight;
        for (final WbFlowNode n in byLayer['$l'] ?? const <WbFlowNode>[]) {
          h = math.max(h, n.height);
        }
        layerHeights[l] = h;
      }
      final double gapY = _adaptiveGap(
        total: height - padding * 2,
        fixed: layerHeights.fold(0, (double a, double b) => a + b),
        count: layerCount - 1,
        minGap: minGapY,
      );
      final List<double> layerY = List<double>.filled(layerCount, padding);
      for (int l = 1; l < layerCount; l++) {
        layerY[l] = layerY[l - 1] + layerHeights[l - 1] + gapY;
      }
      if (withLanes && vertical) {
        final double columnWidth = (width - padding * 2) / laneCount;
        for (int l = 0; l < layerCount; l++) {
          for (final WbFlowNode n in byLayer['$l'] ?? const <WbFlowNode>[]) {
            final int lane = n.laneId == null ? 0 : (laneIndex[n.laneId!] ?? 0);
            final double columnLeft = padding + columnWidth * lane;
            final double x = columnLeft + (columnWidth - n.width) / 2;
            placed[n.id] = Offset(
              _clamp(x, 0, math.max(0, width - n.width)),
              _clamp(layerY[l], 0, math.max(0, height - n.height)),
            );
          }
        }
      } else if (withLanes) {
        // 横向泳道：层内按泳道行摆放。
        final double rowHeight = (height - padding * 2) / laneCount;
        for (int l = 0; l < layerCount; l++) {
          final List<WbFlowNode> rowNodes = byLayer['$l'] ?? const <WbFlowNode>[];
          final double gapX = _adaptiveGap(
            total: width - padding * 2,
            fixed: rowNodes.fold(0, (double a, WbFlowNode n) => a + n.width),
            count: rowNodes.length - 1,
            minGap: minGapX,
          );
          double x = padding;
          for (final WbFlowNode n in rowNodes) {
            final int lane = n.laneId == null ? 0 : (laneIndex[n.laneId!] ?? 0);
            final double rowTop = padding + rowHeight * lane;
            final double y = rowTop + (rowHeight - n.height) / 2;
            placed[n.id] = Offset(
              _clamp(x, 0, math.max(0, width - n.width)),
              _clamp(y, 0, math.max(0, height - n.height)),
            );
            x += n.width + gapX;
          }
        }
      } else {
        for (int l = 0; l < layerCount; l++) {
          final List<WbFlowNode> rowNodes = byLayer['$l'] ?? const <WbFlowNode>[];
          final double totalWidth = rowNodes.fold(
            0,
            (double a, WbFlowNode n) => a + n.width,
          );
          final double gap = _adaptiveGap(
            total: width - padding * 2,
            fixed: totalWidth,
            count: rowNodes.length - 1,
            minGap: minGapX,
          );
          double x = padding +
              math.max(0, (width - padding * 2 - totalWidth - gap * (rowNodes.length - 1)) / 2);
          for (final WbFlowNode n in rowNodes) {
            placed[n.id] = Offset(
              _clamp(x, 0, math.max(0, width - n.width)),
              _clamp(layerY[l], 0, math.max(0, height - n.height)),
            );
            x += n.width + gap;
          }
        }
      }
    } else {
      // 从左到右：主方向 x（层），次方向 y。
      final List<double> layerWidths = List<double>.filled(layerCount, 0);
      for (int l = 0; l < layerCount; l++) {
        double w = WbContextMetrics.flowNodeWidth;
        for (final WbFlowNode n in byLayer['$l'] ?? const <WbFlowNode>[]) {
          w = math.max(w, n.width);
        }
        layerWidths[l] = w;
      }
      final double gapX = _adaptiveGap(
        total: width - padding * 2,
        fixed: layerWidths.fold(0, (double a, double b) => a + b),
        count: layerCount - 1,
        minGap: minGapX,
      );
      final List<double> layerX = List<double>.filled(layerCount, padding);
      for (int l = 1; l < layerCount; l++) {
        layerX[l] = layerX[l - 1] + layerWidths[l - 1] + gapX;
      }
      if (withLanes) {
        final double rowHeight = (height - padding * 2) / laneCount;
        for (int l = 0; l < layerCount; l++) {
          for (final WbFlowNode n in byLayer['$l'] ?? const <WbFlowNode>[]) {
            final int lane = n.laneId == null ? 0 : (laneIndex[n.laneId!] ?? 0);
            final double rowTop = padding + rowHeight * lane;
            final double y = rowTop + (rowHeight - n.height) / 2;
            placed[n.id] = Offset(
              _clamp(layerX[l], 0, math.max(0, width - n.width)),
              _clamp(y, 0, math.max(0, height - n.height)),
            );
          }
        }
      } else {
        for (int l = 0; l < layerCount; l++) {
          final List<WbFlowNode> columnNodes = byLayer['$l'] ?? const <WbFlowNode>[];
          final double totalHeight = columnNodes.fold(
            0,
            (double a, WbFlowNode n) => a + n.height,
          );
          final double gap = _adaptiveGap(
            total: height - padding * 2,
            fixed: totalHeight,
            count: columnNodes.length - 1,
            minGap: minGapY,
          );
          double y = padding +
              math.max(0, (height - padding * 2 - totalHeight - gap * (columnNodes.length - 1)) / 2);
          for (final WbFlowNode n in columnNodes) {
            placed[n.id] = Offset(
              _clamp(layerX[l], 0, math.max(0, width - n.width)),
              _clamp(y, 0, math.max(0, height - n.height)),
            );
            y += n.height + gap;
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

  static double _adaptiveGap({
    required double total,
    required double fixed,
    required int count,
    required double minGap,
  }) {
    if (count <= 0) {
      return 0;
    }
    final double free = total - fixed;
    return math.max(minGap, free / count);
  }

  static double _clamp(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);
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
}) {
  return WbFlowNode(id: id, x: 0, y: 0, type: type, text: text, laneId: laneId);
}

WbFlowConnector _link(String id, String from, String to, {String label = ''}) {
  return WbFlowConnector(id: id, fromId: from, toId: to, label: label);
}

/// 内置模板列表（5 个：基础流程 / 审批流 / 登录流 / 泳道流程 / 分支流程）。
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
  });

  /// 初始模型（null 使用 [WbFlowchartModel.sample] 并按预览尺寸自动分层）。
  final WbFlowchartModel? initialModel;

  /// 变更回调（每次模型变更后调用）。
  final ValueChanged<WbFlowchartModel>? onChanged;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 面板宽度（兼容保留，不再参与布局）。
  final double width;

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

  late WbFlowchartModel _model;
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _laneNameController = TextEditingController();

  /// 预览区（世界坐标）渲染盒 key：用于把全局指针位置换算为画布坐标。
  final GlobalKey _canvasKey = GlobalKey(debugLabel: 'wb-flow-canvas');

  /// 编辑器焦点（选中节点 / 连线后接管 Delete / Backspace）。
  final FocusNode _editorFocus = FocusNode(debugLabel: 'wb-flow-editor');

  String? _selectedNodeId;
  String? _selectedLaneId;
  String? _selectedConnectorId;

  /// 连线模式起点（工具栏「连线」按钮 + 依次点击两节点）。
  String? _linkFromId;

  /// 端口拖拽连线：起点节点、当前指针（世界坐标）、悬停目标节点。
  String? _linkDragFromId;
  Offset? _linkDragPoint;
  String? _linkDragTargetId;

  /// 双击检测：节点 / 连线的最近一次点击。
  String? _lastNodeTapId;
  int _lastNodeTapAt = 0;
  String? _lastConnectorTapId;
  int _lastConnectorTapAt = 0;

  WbFlowNodeType _pendingType = WbFlowNodeType.process;
  bool _linking = false;
  bool _templatesOpen = false;

  /// 画布缩放比例（0.25~3.0；1.0 = 100%）。只影响绘制与指针换算，
  /// 模型坐标始终是世界坐标。
  double _viewScale = 1.0;
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
  }

  @override
  void dispose() {
    _textController.dispose();
    _laneNameController.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  // ---- 基础工具 -----------------------------------------------------------

  String _nextId(String prefix) => '$prefix${++_idSeq}';

  void _emit() => widget.onChanged?.call(_model);

  void _updateModel(WbFlowchartModel next) {
    setState(() => _model = next);
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

  Offset? _globalToCanvas(Offset globalPosition) {
    final RenderBox? box = _canvasBox();
    if (box == null) {
      return null;
    }
    return box.globalToLocal(globalPosition);
  }

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

  // ---- 画布缩放 -----------------------------------------------------------

  /// 按 [factor] 缩放画布（结果 clamp 到 [_minViewScale]~[_maxViewScale]）。
  void _zoomBy(double factor) {
    final double next =
        (_viewScale * factor).clamp(_minViewScale, _maxViewScale);
    if ((next - _viewScale).abs() < 0.0001) {
      return;
    }
    setState(() => _viewScale = next);
  }

  /// 重置缩放为 100%。
  void _resetView() {
    if (_viewScale == 1.0) {
      return;
    }
    setState(() => _viewScale = 1.0);
  }

  /// 滚轮缩放：factor = exp(-dy / 320)，围绕预览区中心缩放。
  ///
  /// [Transform.scale] 默认 `alignment: Alignment.center`，即围绕预览区
  /// 中心放大 / 缩小；命中测试沿变换链自动做逆变换，画布内拖放 / 端口
  /// 拖拽等基于 globalPosition 的换算因此无需额外处理。
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final double dy = event.scrollDelta.dy;
    if (dy == 0) {
      return;
    }
    _zoomBy(math.exp(-dy / 320));
  }

  Rect _laneRectFor(int laneIndex, Size canvas) {
    final List<WbFlowLane> lanes = _model.lanes;
    if (lanes.isEmpty) {
      return Offset.zero & canvas;
    }
    final bool vertical =
        lanes.first.orientation == WbSwimlaneOrientation.vertical;
    final double band =
        (vertical ? canvas.width : canvas.height) / lanes.length;
    final int index = laneIndex.clamp(0, lanes.length - 1);
    return vertical
        ? Rect.fromLTWH(band * index, 0, band, canvas.height)
        : Rect.fromLTWH(0, band * index, canvas.width, band);
  }

  /// 画布坐标 [local] 所在的泳道 id（不在任何泳道内返回 null）。
  String? _laneIdAt(Offset local) {
    for (int i = 0; i < _model.lanes.length; i++) {
      if (_laneRectFor(i, _canvas()).contains(local)) {
        return _model.lanes[i].id;
      }
    }
    return null;
  }

  /// 在画布上寻找不与现有节点重叠的空位（网格扫描；找不到时按插入序堆叠）。
  Offset _findFreeSpot() {
    final Size canvas = _canvas();
    const double w = WbContextMetrics.flowNodeWidth;
    const double h = WbContextMetrics.flowNodeHeight;
    for (double y = 14; y + h <= canvas.height; y += h + 20) {
      for (double x = 14; x + w <= canvas.width; x += w + 26) {
        final Rect candidate = Rect.fromLTWH(x, y, w, h);
        bool clash = false;
        for (final WbFlowNode node in _model.nodes) {
          if (candidate.overlaps(node.bounds.inflate(6))) {
            clash = true;
            break;
          }
        }
        if (!clash) {
          return Offset(x, y);
        }
      }
    }
    final int index = _model.nodes.length;
    return Offset(14.0 + (index % 3) * 148.0, 14.0 + (index ~/ 3) * 76.0);
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
      _selectedNodeId = id;
      _selectedLaneId = null;
      _selectedConnectorId = null;
      _textController.text = id == null ? '' : (_model.nodeById(id)?.text ?? '');
    });
    if (id != null) {
      _editorFocus.requestFocus();
    }
  }

  void _selectLane(String id) {
    final WbFlowLane? lane = _model.laneById(id);
    setState(() {
      _selectedLaneId = id;
      _selectedNodeId = null;
      _selectedConnectorId = null;
      _laneNameController.text = lane?.name ?? '';
    });
    _editorFocus.requestFocus();
  }

  /// 添加指定类型节点：无泳道时放在画布空位，有泳道时放入当前泳道；
  /// [at] 非空表示拖拽落点（世界坐标，节点中心对齐落点）。
  void _addNodeOfType(WbFlowNodeType type, {Offset? at}) {
    final Size canvas = _canvas();
    final String id = _nextId('n');
    double x;
    double y;
    String? laneId;
    if (at != null) {
      laneId = _laneIdAt(at);
      x = (at.dx - WbContextMetrics.flowNodeWidth / 2).clamp(
        0.0,
        math.max(0, canvas.width - WbContextMetrics.flowNodeWidth),
      );
      y = (at.dy - WbContextMetrics.flowNodeHeight / 2).clamp(
        0.0,
        math.max(0, canvas.height - WbContextMetrics.flowNodeHeight),
      );
    } else if (_model.lanes.isNotEmpty) {
      laneId = _selectedLaneId ?? _model.lanes.first.id;
      final int laneIndex = _model.lanes.indexWhere(
        (WbFlowLane lane) => lane.id == laneId,
      );
      final Rect rect = _laneRectFor(laneIndex < 0 ? 0 : laneIndex, canvas);
      final int count = _model.nodesOfLane(laneId).length;
      x = rect.left + (rect.width - WbContextMetrics.flowNodeWidth) / 2;
      y = math.min(
        rect.top + 10 + count * 72,
        math.max(rect.top, rect.bottom - WbContextMetrics.flowNodeHeight),
      );
    } else {
      final Offset spot = _findFreeSpot();
      x = spot.dx;
      y = spot.dy;
    }
    final WbFlowNode node = WbFlowNode(
      id: id,
      type: type,
      text: type.label,
      x: x,
      y: y,
      laneId: laneId,
    );
    _updateModel(_model.upsertNode(node));
    _selectNode(id);
  }

  /// 「添加节点」按钮：使用当前选中类型。
  void _addNode() => _addNodeOfType(_pendingType);

  /// 图形库拖拽落点：在画布指定位置添加节点。
  void _handleShapeDrop(WbFlowNodeType type, Offset globalOffset) {
    final Offset? local = _globalToCanvas(globalOffset);
    if (local == null) {
      return;
    }
    _addNodeOfType(type, at: local);
  }

  void _removeSelectedNode() {
    final String? id = _selectedNodeId;
    if (id == null) {
      return;
    }
    _updateModel(_model.removeNode(id));
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

  void _dragNode(String id, Offset delta) {
    final WbFlowNode? node = _model.nodeById(id);
    if (node == null) {
      return;
    }
    final Size canvas = _canvas();
    final double maxX = math.max(0, canvas.width - node.width);
    final double maxY = math.max(0, canvas.height - node.height);
    final double x = (node.x + delta.dx).clamp(0.0, maxX);
    final double y = (node.y + delta.dy).clamp(0.0, maxY);
    _updateModel(_model.updateNode(id, x: x, y: y));
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
      _openNodeTextDialog(id);
      return;
    }
    _lastNodeTapId = id;
    _lastNodeTapAt = now;
    _selectNode(id);
  }

  /// 双击节点：弹出输入框编辑文本（确认后经 onChanged 上报）。
  void _openNodeTextDialog(String id) {
    final WbFlowNode? node = _model.nodeById(id);
    if (node == null) {
      return;
    }
    final TextEditingController controller =
        TextEditingController(text: node.text);
    showWbMiuixDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        void submit() {
          _updateModel(_model.updateNode(id, text: controller.text));
          Navigator.of(dialogContext).pop();
        }

        return WbMiuixDialog(
          key: const ValueKey<String>('wb-ctx-flow-node-editor'),
          title: '编辑节点文本',
          width: 320,
          content: Builder(
            builder: (BuildContext context) => TextField(
              key: const ValueKey<String>('wb-ctx-flow-node-editor-field'),
              controller: controller,
              autofocus: true,
              minLines: 1,
              maxLines: 2,
              decoration: wbMiuixFieldDecoration(context, hint: '输入节点文本'),
              onSubmitted: (String _) => submit(),
            ),
          ),
          actions: <WbDialogAction>[
            WbDialogAction(
              key: const ValueKey<String>('wb-ctx-flow-node-editor-cancel'),
              label: '取消',
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            WbDialogAction(
              key: const ValueKey<String>('wb-ctx-flow-node-editor-confirm'),
              label: '确定',
              primary: true,
              onPressed: submit,
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
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

  // ---- 端口拖拽连线 --------------------------------------------------------

  void _handlePortDragStart(String nodeId, Offset globalPosition) {
    final Offset? local = _globalToCanvas(globalPosition);
    if (local == null) {
      return;
    }
    setState(() {
      _linkDragFromId = nodeId;
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

  void _handlePortDragEnd() {
    final String? from = _linkDragFromId;
    final String? target = _linkDragTargetId;
    final Offset? point = _linkDragPoint;
    setState(() {
      _linkDragFromId = null;
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
    }
  }

  void _handlePortDragCancel() {
    if (_linkDragFromId == null) {
      return;
    }
    setState(() {
      _linkDragFromId = null;
      _linkDragPoint = null;
      _linkDragTargetId = null;
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
        _selectedNodeId = null;
        _selectedLaneId = null;
      });
      _editorFocus.requestFocus();
      return;
    }
    if (_selectedConnectorId == null &&
        _selectedNodeId == null &&
        _selectedLaneId == null &&
        _linkFromId == null) {
      return;
    }
    setState(() {
      _selectedConnectorId = null;
      _selectedNodeId = null;
      _selectedLaneId = null;
      _linkFromId = null;
    });
  }

  void _removeConnector(String id) {
    _updateModel(_model.removeConnector(id));
    setState(() => _selectedConnectorId = null);
  }

  // ---- 键盘：Delete / Backspace 删除选中内容 --------------------------------

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.delete &&
        key != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    if (_isEditingText()) {
      // 文本输入中：交给输入框处理（避免误删节点）。
      return KeyEventResult.ignored;
    }
    final String? connectorId = _selectedConnectorId;
    if (connectorId != null) {
      _removeConnector(connectorId);
      return KeyEventResult.handled;
    }
    if (_selectedNodeId != null) {
      _removeSelectedNode();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
      _selectedNodeId = null;
      _selectedLaneId = null;
      _selectedConnectorId = null;
      _linkFromId = null;
      _linkDragFromId = null;
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
    return Focus(
      focusNode: _editorFocus,
      onKeyEvent: _handleKeyEvent,
      child: WbEditorWorkspace(
        toolbar: _buildToolbar(context),
        child: WbEditorPanes(
          left: _buildLeftPanel(context),
          center: _buildCanvasArea(),
          right: _buildRightPanel(context, selectedNode, selectedLane),
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

  /// 右面板：选中节点 / 泳道属性（垂直可滚动）。
  Widget _buildRightPanel(
    BuildContext context,
    WbFlowNode? selectedNode,
    WbFlowLane? selectedLane,
  ) {
    return Container(
      key: const ValueKey<String>('wb-ctx-flow-right-panel'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: _buildInspector(context, selectedNode, selectedLane),
      ),
    );
  }

  /// 中间画布区：最大化预览 + 滚轮缩放（围绕预览区中心，0.25x~3x）。
  Widget _buildCanvasArea() {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _handlePointerSignal,
      child: ClipRect(
        child: Transform.scale(
          key: const ValueKey<String>('wb-ctx-flow-preview-transform'),
          scale: _viewScale,
          // 默认 alignment: Alignment.center，即围绕预览区中心缩放。
          child: _FlowPreview(
            model: _model,
            canvasKey: _canvasKey,
            selectedNodeId: _selectedNodeId,
            selectedLaneId: _selectedLaneId,
            selectedConnectorId: _selectedConnectorId,
            linkFromId: _linkFromId,
            pendingFromId: _linkDragFromId,
            pendingPoint: _linkDragPoint,
            pendingTargetId: _linkDragTargetId,
            onViewport: _handleViewport,
            onNodeTap: _handleNodeTap,
            onNodeDrag: _dragNode,
            onLaneTap: _selectLane,
            onCanvasTap: _handleCanvasTap,
            onPortDragStart: _handlePortDragStart,
            onPortDragUpdate: _handlePortDragUpdate,
            onPortDragEnd: _handlePortDragEnd,
            onPortDragCancel: _handlePortDragCancel,
            onShapeDrop: _handleShapeDrop,
          ),
        ),
      ),
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
          tooltip: '添加节点（当前类型：${_pendingType.label}）',
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
        for (final WbFlowNodeType type in WbFlowNodeType.values)
          WbEditorChip(
            key: ValueKey<String>('wb-ctx-flow-type-${type.id}'),
            label: type.label,
            dense: true,
            selected: _pendingType == type,
            onTap: () => setState(() => _pendingType = type),
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
      ],
    );
  }

  /// 图形库（左面板垂直滚动列表，WPS 式图形库）：9 种图形项，
  /// 点击在画布空位添加；按住可拖拽到画布指定位置。
  Widget _buildShapeLibrary(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        WbEditorSectionTitle(
          title: '图形库',
          trailing: WbEditorHint('${WbFlowNodeType.values.length} 种图形'),
        ),
        for (final WbFlowNodeType type in WbFlowNodeType.values)
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
  ) {
    if (selectedNode != null) {
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
          if (_model.lanes.isNotEmpty)
            PopupMenuButton<String>(
              key: const ValueKey<String>('wb-ctx-flow-node-lane'),
              tooltip: '移动到泳道',
              icon: Icon(LinearIcons.layers, size: 16, color: context.wbColors.toolbarIcon),
              onSelected: (String value) =>
                  _moveNodeToLane(selectedNode.id, value.isEmpty ? null : value),
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
      '单击选中节点 / 双击改字 / 拖拽微调位置；从节点右侧圆点拖拽到目标节点即创建连线；'
      '点选连线后按 Delete 删除（双击连线直接删除）。',
    );
  }
}

// ---------------------------------------------------------------------------
// 预览区
// ---------------------------------------------------------------------------

/// 画布预览：泳道背景 + 连线层 + 画布手势层 + 节点 + 端口 + 拖拽目标。
class _FlowPreview extends StatelessWidget {
  const _FlowPreview({
    required this.model,
    required this.canvasKey,
    required this.selectedNodeId,
    required this.selectedLaneId,
    required this.selectedConnectorId,
    required this.linkFromId,
    required this.pendingFromId,
    required this.pendingPoint,
    required this.pendingTargetId,
    required this.onViewport,
    required this.onNodeTap,
    required this.onNodeDrag,
    required this.onLaneTap,
    required this.onCanvasTap,
    required this.onPortDragStart,
    required this.onPortDragUpdate,
    required this.onPortDragEnd,
    required this.onPortDragCancel,
    required this.onShapeDrop,
  });

  final WbFlowchartModel model;

  /// 画布渲染盒 key（世界坐标换算用）。
  final GlobalKey canvasKey;

  final String? selectedNodeId;
  final String? selectedLaneId;
  final String? selectedConnectorId;
  final String? linkFromId;
  final String? pendingFromId;
  final Offset? pendingPoint;
  final String? pendingTargetId;
  final ValueChanged<Size> onViewport;
  final ValueChanged<String> onNodeTap;
  final void Function(String id, Offset delta) onNodeDrag;
  final ValueChanged<String> onLaneTap;
  final ValueChanged<Offset> onCanvasTap;
  final void Function(String nodeId, Offset globalPosition) onPortDragStart;
  final ValueChanged<Offset> onPortDragUpdate;
  final VoidCallback onPortDragEnd;
  final VoidCallback onPortDragCancel;
  final void Function(WbFlowNodeType type, Offset globalOffset) onShapeDrop;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.width > 1 && size.height > 1) {
          onViewport(size);
        }
        return DragTarget<WbFlowNodeType>(
          onAcceptWithDetails: (DragTargetDetails<WbFlowNodeType> details) =>
              onShapeDrop(details.data, details.offset),
          builder: (
            BuildContext context,
            List<WbFlowNodeType?> candidates,
            List<dynamic> rejected,
          ) {
            final bool accepting = candidates.isNotEmpty;
            return ClipRRect(
              borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
              child: Container(
                key: canvasKey,
                color: colors.canvas,
                foregroundDecoration: accepting
                    ? BoxDecoration(
                        border: Border.all(color: colors.primary, width: 1.6),
                      )
                    : null,
                child: SizedBox.fromSize(
                  size: size,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: <Widget>[
                      ..._buildLaneBands(context, size),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: WbFlowConnectorPainter(
                              model: model,
                              selectedNodeId: selectedNodeId,
                              selectedConnectorId: selectedConnectorId,
                              pendingFromId: pendingFromId,
                              pendingPoint: pendingPoint,
                              pendingTargetId: pendingTargetId,
                              colors: colors,
                            ),
                          ),
                        ),
                      ),
                      // 画布手势层：点选 / 删除连线，点击空白取消选中。
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (TapUpDetails details) =>
                              onCanvasTap(details.localPosition),
                        ),
                      ),
                      ..._buildLaneHeaders(context, size),
                      for (final WbFlowNode node in model.nodes)
                        Positioned(
                          left: node.x,
                          top: node.y,
                          width: node.width,
                          height: node.height,
                          child: WbFlowNodeView(
                            key: ValueKey<String>('wb-ctx-flow-node-${node.id}'),
                            node: node,
                            selected: node.id == selectedNodeId,
                            highlighted: node.id == linkFromId ||
                                node.id == pendingFromId ||
                                node.id == pendingTargetId,
                            onTap: () => onNodeTap(node.id),
                            onDragDelta: (Offset delta) => onNodeDrag(node.id, delta),
                          ),
                        ),
                      // 连线端口：节点右侧中点圆点，按住拖拽建立连线。
                      for (final WbFlowNode node in model.nodes)
                        Positioned(
                          left: node.x + node.width - 9,
                          top: node.y + node.height / 2 - 9,
                          width: 18,
                          height: 18,
                          child: _FlowPortDot(
                            key: ValueKey<String>('wb-ctx-flow-port-${node.id}'),
                            color: colors.primary,
                            active: node.id == selectedNodeId ||
                                node.id == pendingFromId,
                            onDragStart: (Offset global) =>
                                onPortDragStart(node.id, global),
                            onDragUpdate: onPortDragUpdate,
                            onDragEnd: onPortDragEnd,
                            onDragCancel: onPortDragCancel,
                          ),
                        ),
                      if (model.nodes.isEmpty)
                        const Positioned.fill(
                          child: IgnorePointer(
                            child: Center(
                              child: WbEditorHint(
                                '画布为空：点击图形库或拖拽图形到此处开始绘制',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 泳道背景带（忽略指针，保证画布手势层可用）。
  List<Widget> _buildLaneBands(BuildContext context, Size size) {
    final List<WbFlowLane> lanes = model.lanes;
    if (lanes.isEmpty || size.width <= 1 || size.height <= 1) {
      return const <Widget>[];
    }
    final bool vertical =
        lanes.first.orientation == WbSwimlaneOrientation.vertical;
    final double band =
        (vertical ? size.width : size.height) / lanes.length;
    return <Widget>[
      for (int i = 0; i < lanes.length; i++)
        Positioned.fromRect(
          rect: vertical
              ? Rect.fromLTWH(band * i, 0, band, size.height)
              : Rect.fromLTWH(0, band * i, size.width, band),
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

  /// 泳道标题层（独立于背景带，保证标题可点击且不遮挡画布手势）。
  List<Widget> _buildLaneHeaders(BuildContext context, Size size) {
    final List<WbFlowLane> lanes = model.lanes;
    if (lanes.isEmpty || size.width <= 1 || size.height <= 1) {
      return const <Widget>[];
    }
    final bool vertical =
        lanes.first.orientation == WbSwimlaneOrientation.vertical;
    final double band =
        (vertical ? size.width : size.height) / lanes.length;
    final List<Widget> headers = <Widget>[];
    for (int i = 0; i < lanes.length; i++) {
      final WbFlowLane lane = lanes[i];
      final Rect rect = vertical
          ? Rect.fromLTWH(band * i, 0, band, size.height)
          : Rect.fromLTWH(0, band * i, size.width, band);
      final Widget header = GestureDetector(
        key: ValueKey<String>('wb-ctx-flow-lane-${lane.id}'),
        onTap: () => onLaneTap(lane.id),
        child: _FlowLaneHeader(
          lane: lane,
          count: model.nodesOfLane(lane.id).length,
          selected: lane.id == selectedLaneId,
        ),
      );
      headers.add(
        Positioned.fromRect(
          rect: rect,
          child: Align(
            alignment:
                vertical ? Alignment.topLeft : Alignment.centerLeft,
            child: vertical
                ? SizedBox(width: rect.width, child: header)
                : header,
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
    return Draggable<WbFlowNodeType>(
      data: type,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _FlowNodeGhost(type: type, primary: primary),
      childWhenDragging: Opacity(opacity: 0.35, child: content),
      child: content,
    );
  }
}

/// 图形拖拽反馈：节点尺寸的半透明幽灵，中心对齐指针。
class _FlowNodeGhost extends StatelessWidget {
  const _FlowNodeGhost({required this.type, required this.primary});

  final WbFlowNodeType type;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    return FractionalTranslation(
      translation: const Offset(-0.5, -0.5),
      child: Opacity(
        opacity: 0.85,
        child: SizedBox(
          width: WbContextMetrics.flowNodeWidth,
          height: WbContextMetrics.flowNodeHeight,
          child: CustomPaint(
            painter: WbFlowNodePainter(
              type: type,
              selected: true,
              primary: primary,
            ),
            child: Center(
              child: Text(
                type.label,
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

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.precise,
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
// 节点视图与绘制
// ---------------------------------------------------------------------------

/// 单个流程图节点（可点选 / 可拖拽微调）。
class WbFlowNodeView extends StatelessWidget {
  /// 创建节点视图。
  const WbFlowNodeView({
    super.key,
    required this.node,
    required this.selected,
    required this.highlighted,
    required this.onTap,
    required this.onDragDelta,
  });

  /// 节点数据。
  final WbFlowNode node;

  /// 是否选中。
  final bool selected;

  /// 是否处于连线起点高亮。
  final bool highlighted;

  /// 点选回调。
  final VoidCallback onTap;

  /// 拖拽增量回调（世界坐标增量）。
  final ValueChanged<Offset> onDragDelta;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onPanUpdate: (DragUpdateDetails details) => onDragDelta(details.delta),
        child: CustomPaint(
          painter: WbFlowNodePainter(
            type: node.type,
            selected: selected,
            highlighted: highlighted,
            primary: colors.primary,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                node.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: WbTypography.label.copyWith(
                  color: colors.icon,
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

/// 节点形状绘制（§3.2 / §4：圆角矩形 / 菱形 / 平行四边形 / 波浪底 /
/// 圆柱 / 梯形 / 圆形 / 开放矩形）。
class WbFlowNodePainter extends CustomPainter {
  /// 创建绘制器。
  const WbFlowNodePainter({
    required this.type,
    required this.selected,
    this.highlighted = false,
    required this.primary,
  });

  /// 节点类型。
  final WbFlowNodeType type;

  /// 是否选中。
  final bool selected;

  /// 是否作为连线起点高亮。
  final bool highlighted;

  /// 主题主色（选中描边）。
  final Color primary;

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

  @override
  bool shouldRepaint(WbFlowNodePainter oldDelegate) {
    return oldDelegate.type != type ||
        oldDelegate.selected != selected ||
        oldDelegate.highlighted != highlighted ||
        oldDelegate.primary != primary;
  }
}

/// 连线绘制：锚点吸附（按相对方位选边）+ 折线路由 + 箭头 + 标签 +
/// 选中高亮 + 拖拽连线虚线预览。
class WbFlowConnectorPainter extends CustomPainter {
  /// 创建绘制器。
  WbFlowConnectorPainter({
    required this.model,
    required this.selectedNodeId,
    required this.colors,
    this.selectedConnectorId,
    this.pendingFromId,
    this.pendingPoint,
    this.pendingTargetId,
  });

  /// 流程图模型。
  final WbFlowchartModel model;

  /// 当前选中节点（其连线高亮）。
  final String? selectedNodeId;

  /// 主题颜色（主色 / 文本色 / 浮层底色）。
  final WbThemeColors colors;

  /// 当前选中连线（加粗高亮；Delete 可删除）。
  final String? selectedConnectorId;

  /// 拖拽连线起点节点 id（null 表示无进行中的端口拖拽）。
  final String? pendingFromId;

  /// 拖拽连线当前指针位置（世界坐标）。
  final Offset? pendingPoint;

  /// 拖拽连线悬停目标节点 id（虚线预览吸附用）。
  final String? pendingTargetId;

  @override
  void paint(Canvas canvas, Size size) {
    for (final WbFlowConnector connector in model.connectors) {
      final WbFlowNode? from = model.nodeById(connector.fromId);
      final WbFlowNode? to = model.nodeById(connector.toId);
      if (from == null || to == null) {
        continue;
      }
      final bool selectedLine = connector.id == selectedConnectorId;
      final bool highlight = selectedLine ||
          connector.fromId == selectedNodeId ||
          connector.toId == selectedNodeId;
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
      _drawArrow(canvas, points[points.length - 2], points.last, color);
      if (connector.label.isNotEmpty) {
        _drawLabel(canvas, connector.label, points, color);
      }
    }
    _paintPending(canvas);
  }

  /// 拖拽连线预览：虚线 + 端点圆点；悬停目标时吸附到目标边缘。
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
    final Offset start = _edgeAnchor(from.bounds, point);
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

  void _drawArrow(Canvas canvas, Offset from, Offset to, Color color) {
    const double head = 8;
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
    canvas.drawPath(path, Paint()..color = color);
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
        oldDelegate.selectedNodeId != selectedNodeId ||
        oldDelegate.colors != colors ||
        oldDelegate.selectedConnectorId != selectedConnectorId ||
        oldDelegate.pendingFromId != pendingFromId ||
        oldDelegate.pendingPoint != pendingPoint ||
        oldDelegate.pendingTargetId != pendingTargetId;
  }
}

// ---------------------------------------------------------------------------
// 连线路由与几何工具
// ---------------------------------------------------------------------------

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
