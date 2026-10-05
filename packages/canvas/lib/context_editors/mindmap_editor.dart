/// 思维导图上下文编辑器（Wave 3.6；第三轮问题 2 · 波次 B4 全窗三区重构）。
///
/// 依据《白板软件设计文档》§6.6「思维导图工具栏」实现：
/// - **节点树**：[WbMindNode] 不可变树，支持添加子节点 / 添加兄弟节点 /
///   删除 / 重命名 / 折叠展开；
/// - **折叠**：折叠节点隐藏其整棵子树，节点角标显示隐藏数量，可再次展开；
/// - **布局切换**：内置 3 种纯 Dart 布局（逻辑图向右 / 树形向下 / 思维导图双向），
///   按叶序游标排布 + 画布内平移，随预览尺寸即时计算（见 [WbMindLayoutEngine]）；
/// - **节点交互**：单击选中（右面板编辑文本）、节点右侧「+」按钮快捷
///   添加子节点、右键上下文菜单（加子节点 / 加兄弟节点 / 重命名 / 折叠展开 / 删除）；
/// - **预览平移**：非节点区域按住拖动可平移视图，平移量按内容与视口钳制；
/// - **全窗三区工作区**（波次 B4）：[WbEditorWorkspace] + [WbEditorPanes]，
///   左 176 节点操作面板（`wb-ctx-mind-left-panel`）/ 中间最大化预览 /
///   右 240 节点属性面板（`wb-ctx-mind-right-panel`），无卡片、无第二标题栏；
/// - **画布缩放**（波次 B4）：0.25x~3x（默认 100%），滚轮 factor =
///   exp(-dy / 320) 围绕预览区中心（`Transform.scale`，命中测试自动逆变换），
///   工具条提供 - / 百分比 / + / 重置。
///
/// 组件自包含（无 Provider / 主题扩展依赖），通过 [WbMindmapEditor.onChanged]
/// 上报最新节点树。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import 'context_editor_shell.dart';
import 'editor_workspace.dart';

/// 思维导图布局。
enum WbMindLayout {
  /// 逻辑图（向右展开）。
  right('right', '逻辑图（向右）'),

  /// 树形（向下展开）。
  tree('tree', '树形（向下）'),

  /// 思维导图（根居中，双向展开）。
  both('both', '思维导图（双向）');

  const WbMindLayout(this.id, this.label);

  /// 稳定 id。
  final String id;

  /// 中文显示名。
  final String label;
}

/// 思维导图节点（不可变树）。
@immutable
class WbMindNode {
  /// 创建节点。
  const WbMindNode({
    required this.id,
    required this.text,
    this.children = const <WbMindNode>[],
    this.collapsed = false,
  });

  /// 演示用示例树（中心主题 + 3 分支）。
  factory WbMindNode.sample() {
    return const WbMindNode(
      id: 'm1',
      text: '中心主题',
      children: <WbMindNode>[
        WbMindNode(
          id: 'm2',
          text: '分支 A',
          children: <WbMindNode>[
            WbMindNode(id: 'm3', text: '要点 A1'),
            WbMindNode(id: 'm4', text: '要点 A2'),
          ],
        ),
        WbMindNode(id: 'm5', text: '分支 B'),
        WbMindNode(id: 'm6', text: '分支 C'),
      ],
    );
  }

  /// 节点 id（树内唯一）。
  final String id;

  /// 节点文本。
  final String text;

  /// 子节点。
  final List<WbMindNode> children;

  /// 是否折叠（折叠后子节点不参与布局与交互）。
  final bool collapsed;

  /// 子树节点总数（含自身）。
  int get count => 1 + children.fold(0, (int sum, WbMindNode c) => sum + c.count);

  /// 复制并覆盖字段。
  WbMindNode copyWith({
    String? id,
    String? text,
    List<WbMindNode>? children,
    bool? collapsed,
  }) {
    return WbMindNode(
      id: id ?? this.id,
      text: text ?? this.text,
      children: children ?? this.children,
      collapsed: collapsed ?? this.collapsed,
    );
  }

  /// 按 id 查找节点（含自身；不存在返回 null）。
  WbMindNode? nodeById(String id) {
    if (this.id == id) {
      return this;
    }
    for (final WbMindNode child in children) {
      final WbMindNode? found = child.nodeById(id);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  /// 将 id 命中节点替换为 [transform] 的结果（返回新树）。
  WbMindNode mapById(String id, WbMindNode Function(WbMindNode node) transform) {
    if (this.id == id) {
      return transform(this);
    }
    return copyWith(
      children: <WbMindNode>[
        for (final WbMindNode child in children)
          child.mapById(id, transform),
      ],
    );
  }

  /// 删除 id 命中节点（根节点不可删除；返回新树）。
  WbMindNode removeById(String id) {
    if (this.id == id) {
      return this;
    }
    return copyWith(
      children: <WbMindNode>[
        for (final WbMindNode child in children)
          if (child.id != id) child.removeById(id),
      ],
    );
  }

  /// 在 [id] 节点的父级 `children` 中，紧跟该节点之后插入 [sibling]（返回新树）。
  ///
  /// 与 [mapById] / [removeById] 同为不可变树操作（仅重建路径上的节点）：
  /// - 根节点没有父级、即没有兄弟位，命中根节点时原样返回；
  /// - [id] 不存在时返回结构等价的新树（与 [mapById] 行为一致）；
  /// - [sibling] 的 id 唯一性由调用方保证。
  WbMindNode insertAfter(String id, WbMindNode sibling) {
    if (this.id == id) {
      return this;
    }
    final int index = children.indexWhere((WbMindNode child) => child.id == id);
    if (index >= 0) {
      return copyWith(
        children: <WbMindNode>[
          ...children.take(index + 1),
          sibling,
          ...children.skip(index + 1),
        ],
      );
    }
    return copyWith(
      children: <WbMindNode>[
        for (final WbMindNode child in children)
          child.insertAfter(id, sibling),
      ],
    );
  }

  /// 深度优先展开（含折叠节点自身）。
  List<WbMindNode> flatten() {
    return <WbMindNode>[
      this,
      for (final WbMindNode child in children) ...child.flatten(),
    ];
  }
}

/// 布局边（父子连线）。
@immutable
class WbMindEdge {
  /// 创建边。
  const WbMindEdge(this.fromId, this.toId);

  /// 父节点 id。
  final String fromId;

  /// 子节点 id。
  final String toId;
}

/// 布局结果（节点矩形 + 连线 + 层级）。
@immutable
class WbMindLayoutResult {
  /// 创建结果。
  const WbMindLayoutResult({
    required this.rects,
    required this.edges,
    required this.depths,
  });

  /// 节点 id → 外接矩形。
  final Map<String, Rect> rects;

  /// 父子连线。
  final List<WbMindEdge> edges;

  /// 节点 id → 层级（根为 0）。
  final Map<String, int> depths;
}

/// 思维导图布局引擎（叶序游标 + 父节点居中 + 画布内平移）。
abstract final class WbMindLayoutEngine {
  /// 计算布局。
  ///
  /// [canvas] 为可用画布尺寸；节点尺寸默认取 [WbContextMetrics]。
  static WbMindLayoutResult layout({
    required WbMindNode root,
    required WbMindLayout layout,
    required Size canvas,
    double nodeWidth = WbContextMetrics.mindNodeWidth,
    double nodeHeight = WbContextMetrics.mindNodeHeight,
    double gapX = 52,
    double gapY = 30,
    double padding = 12,
  }) {
    final Map<String, Rect> rects = <String, Rect>{};
    final List<WbMindEdge> edges = <WbMindEdge>[];
    final Map<String, int> depths = <String, int>{};

    switch (layout) {
      case WbMindLayout.right:
        _layoutRight(
          root: root,
          depth: 0,
          cursor: _Cursor(padding),
          rects: rects,
          edges: edges,
          depths: depths,
          nodeWidth: nodeWidth,
          nodeHeight: nodeHeight,
          gapX: gapX,
          gapY: _adaptiveGap(root, nodeHeight, gapY, canvas.height, padding),
          padding: padding,
        );
      case WbMindLayout.tree:
        _layoutTree(
          root: root,
          depth: 0,
          cursor: _Cursor(padding),
          rects: rects,
          edges: edges,
          depths: depths,
          nodeWidth: nodeWidth,
          nodeHeight: nodeHeight,
          gapX: _adaptiveGap(root, nodeWidth, gapX, canvas.width, padding),
          gapY: gapY,
          padding: padding,
        );
      case WbMindLayout.both:
        _layoutBoth(
          root: root,
          rects: rects,
          edges: edges,
          depths: depths,
          canvas: canvas,
          nodeWidth: nodeWidth,
          nodeHeight: nodeHeight,
          gapX: gapX,
          gapY: gapY,
          padding: padding,
        );
    }

    final Map<String, Rect> placed = _translateInto(rects, canvas, padding);
    return WbMindLayoutResult(rects: placed, edges: edges, depths: depths);
  }

  static double _adaptiveGap(
    WbMindNode root,
    double unit,
    double gap,
    double total,
    double padding,
  ) {
    int leaves = 0;
    void walk(WbMindNode node) {
      if (node.collapsed || node.children.isEmpty) {
        leaves++;
        return;
      }
      for (final WbMindNode child in node.children) {
        walk(child);
      }
    }

    walk(root);
    final double available = math.max(total - padding * 2, unit);
    if (leaves <= 1) {
      return gap;
    }
    final double free = available - unit * leaves;
    if (free <= 0) {
      return 4;
    }
    return math.min(gap, math.max(4, free / (leaves - 1)));
  }

  /// 向右展开：y 由叶序游标决定，父节点居中于子节点范围。
  static void _layoutRight({
    required WbMindNode root,
    required int depth,
    required _Cursor cursor,
    required Map<String, Rect> rects,
    required List<WbMindEdge> edges,
    required Map<String, int> depths,
    required double nodeWidth,
    required double nodeHeight,
    required double gapX,
    required double gapY,
    required double padding,
  }) {
    final double x = padding + depth * (nodeWidth + gapX);
    depths[root.id] = depth;
    final List<WbMindNode> visible = root.collapsed
        ? const <WbMindNode>[]
        : root.children;
    if (visible.isEmpty) {
      rects[root.id] = Rect.fromLTWH(x, cursor.value, nodeWidth, nodeHeight);
      cursor.value += nodeHeight + gapY;
      return;
    }
    double top = double.infinity;
    double bottom = 0;
    for (final WbMindNode child in visible) {
      edges.add(WbMindEdge(root.id, child.id));
      _layoutRight(
        root: child,
        depth: depth + 1,
        cursor: cursor,
        rects: rects,
        edges: edges,
        depths: depths,
        nodeWidth: nodeWidth,
        nodeHeight: nodeHeight,
        gapX: gapX,
        gapY: gapY,
        padding: padding,
      );
      final Rect childRect = rects[child.id]!;
      top = math.min(top, childRect.top);
      bottom = math.max(bottom, childRect.bottom);
    }
    final double y = (top + bottom) / 2 - nodeHeight / 2;
    rects[root.id] = Rect.fromLTWH(x, y, nodeWidth, nodeHeight);
  }

  /// 向下展开（树形）：x 由叶序游标决定，父节点居中于子节点范围。
  static void _layoutTree({
    required WbMindNode root,
    required int depth,
    required _Cursor cursor,
    required Map<String, Rect> rects,
    required List<WbMindEdge> edges,
    required Map<String, int> depths,
    required double nodeWidth,
    required double nodeHeight,
    required double gapX,
    required double gapY,
    required double padding,
  }) {
    final double y = padding + depth * (nodeHeight + gapY);
    depths[root.id] = depth;
    final List<WbMindNode> visible = root.collapsed
        ? const <WbMindNode>[]
        : root.children;
    if (visible.isEmpty) {
      rects[root.id] = Rect.fromLTWH(cursor.value, y, nodeWidth, nodeHeight);
      cursor.value += nodeWidth + gapX;
      return;
    }
    double left = double.infinity;
    double right = 0;
    for (final WbMindNode child in visible) {
      edges.add(WbMindEdge(root.id, child.id));
      _layoutTree(
        root: child,
        depth: depth + 1,
        cursor: cursor,
        rects: rects,
        edges: edges,
        depths: depths,
        nodeWidth: nodeWidth,
        nodeHeight: nodeHeight,
        gapX: gapX,
        gapY: gapY,
        padding: padding,
      );
      final Rect childRect = rects[child.id]!;
      left = math.min(left, childRect.left);
      right = math.max(right, childRect.right);
    }
    final double x = (left + right) / 2 - nodeWidth / 2;
    rects[root.id] = Rect.fromLTWH(x, y, nodeWidth, nodeHeight);
  }

  /// 双向展开：根居中，前半子节点向右、后半向左。
  static void _layoutBoth({
    required WbMindNode root,
    required Map<String, Rect> rects,
    required List<WbMindEdge> edges,
    required Map<String, int> depths,
    required Size canvas,
    required double nodeWidth,
    required double nodeHeight,
    required double gapX,
    required double gapY,
    required double padding,
  }) {
    depths[root.id] = 0;
    final List<WbMindNode> visible = root.collapsed
        ? const <WbMindNode>[]
        : root.children;
    final double centerX = math.max(canvas.width / 2 - nodeWidth / 2, padding);
    if (visible.isEmpty) {
      rects[root.id] = Rect.fromLTWH(
        centerX,
        math.max(canvas.height / 2 - nodeHeight / 2, padding),
        nodeWidth,
        nodeHeight,
      );
      return;
    }
    final int half = (visible.length / 2).ceil();
    final List<WbMindNode> rightSide = visible.sublist(0, half);
    final List<WbMindNode> leftSide = visible.sublist(half);

    final _Cursor rightCursor = _Cursor(padding);
    final _Cursor leftCursor = _Cursor(padding);
    for (final WbMindNode child in rightSide) {
      edges.add(WbMindEdge(root.id, child.id));
      _layoutRight(
        root: child,
        depth: 1,
        cursor: rightCursor,
        rects: rects,
        edges: edges,
        depths: depths,
        nodeWidth: nodeWidth,
        nodeHeight: nodeHeight,
        gapX: gapX,
        gapY: gapY,
        padding: padding,
      );
    }
    for (final WbMindNode child in leftSide) {
      edges.add(WbMindEdge(root.id, child.id));
      _layoutLeft(
        root: child,
        depth: 1,
        cursor: leftCursor,
        rects: rects,
        edges: edges,
        depths: depths,
        nodeWidth: nodeWidth,
        nodeHeight: nodeHeight,
        gapX: gapX,
        gapY: gapY,
        padding: padding,
      );
    }
    final double rightHeight = math.max(rightCursor.value - gapY - padding, 0);
    final double leftHeight = math.max(leftCursor.value - gapY - padding, 0);
    final double contentHeight = math.max(rightHeight, leftHeight);
    final double centerY =
        math.max(padding + contentHeight / 2 - nodeHeight / 2, padding);
    rects[root.id] = Rect.fromLTWH(centerX, centerY, nodeWidth, nodeHeight);
    final double rightDeltaY = (contentHeight - rightHeight) / 2;
    final double leftDeltaY = (contentHeight - leftHeight) / 2;
    for (final WbMindNode child in rightSide) {
      _translateSubtree(rects, child, Offset(centerX - padding, rightDeltaY));
    }
    for (final WbMindNode child in leftSide) {
      _translateSubtree(rects, child, Offset(centerX, leftDeltaY));
    }
  }

  /// 向左镜像展开（[WbMindLayout.both] 左侧子树用）。
  static void _layoutLeft({
    required WbMindNode root,
    required int depth,
    required _Cursor cursor,
    required Map<String, Rect> rects,
    required List<WbMindEdge> edges,
    required Map<String, int> depths,
    required double nodeWidth,
    required double nodeHeight,
    required double gapX,
    required double gapY,
    required double padding,
  }) {
    depths[root.id] = depth;
    final List<WbMindNode> visible = root.collapsed
        ? const <WbMindNode>[]
        : root.children;
    if (visible.isEmpty) {
      rects[root.id] = Rect.fromLTWH(-depth * (nodeWidth + gapX), cursor.value, nodeWidth, nodeHeight);
      cursor.value += nodeHeight + gapY;
      return;
    }
    double top = double.infinity;
    double bottom = 0;
    for (final WbMindNode child in visible) {
      edges.add(WbMindEdge(root.id, child.id));
      _layoutLeft(
        root: child,
        depth: depth + 1,
        cursor: cursor,
        rects: rects,
        edges: edges,
        depths: depths,
        nodeWidth: nodeWidth,
        nodeHeight: nodeHeight,
        gapX: gapX,
        gapY: gapY,
        padding: padding,
      );
      final Rect childRect = rects[child.id]!;
      top = math.min(top, childRect.top);
      bottom = math.max(bottom, childRect.bottom);
    }
    final double y = (top + bottom) / 2 - nodeHeight / 2;
    rects[root.id] = Rect.fromLTWH(
      -depth * (nodeWidth + gapX),
      y,
      nodeWidth,
      nodeHeight,
    );
  }

  /// 平移 [node] 及整棵子树在 [rects] 中的矩形（原地更新）。
  static void _translateSubtree(
    Map<String, Rect> rects,
    WbMindNode node,
    Offset delta,
  ) {
    for (final WbMindNode descendant in node.flatten()) {
      final Rect? rect = rects[descendant.id];
      if (rect != null) {
        rects[descendant.id] = rect.translate(delta.dx, delta.dy);
      }
    }
  }

  static Map<String, Rect> _translateInto(
    Map<String, Rect> rects,
    Size canvas,
    double padding,
  ) {
    if (rects.isEmpty) {
      return rects;
    }
    double minLeft = double.infinity;
    double minTop = double.infinity;
    for (final Rect rect in rects.values) {
      minLeft = math.min(minLeft, rect.left);
      minTop = math.min(minTop, rect.top);
    }
    final double dx = minLeft < padding ? padding - minLeft : 0;
    final double dy = minTop < padding ? padding - minTop : 0;
    if (dx == 0 && dy == 0) {
      return rects;
    }
    return <String, Rect>{
      for (final MapEntry<String, Rect> entry in rects.entries)
        entry.key: entry.value.translate(dx, dy),
    };
  }
}

/// 可变叶序游标。
class _Cursor {
  _Cursor(this.value);

  double value;
}

/// 思维导图上下文编辑器。
class WbMindmapEditor extends StatefulWidget {
  /// 创建编辑器。
  const WbMindmapEditor({
    super.key,
    this.initialRoot,
    this.initialLayout = WbMindLayout.right,
    this.onChanged,
    this.onLayoutChanged,
    this.onClose,
    this.width = WbContextMetrics.defaultWidth,
  });

  /// 初始节点树（null 使用 [WbMindNode.sample]）。
  final WbMindNode? initialRoot;

  /// 初始布局。
  final WbMindLayout initialLayout;

  /// 节点树变更回调。
  final ValueChanged<WbMindNode>? onChanged;

  /// 布局切换回调。
  final ValueChanged<WbMindLayout>? onLayoutChanged;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 面板宽度（兼容保留，全窗工作区不再参与布局）。
  final double width;

  @override
  State<WbMindmapEditor> createState() => _WbMindmapEditorState();
}

class _WbMindmapEditorState extends State<WbMindmapEditor> {
  /// 画布缩放范围 / 步进（对齐流程图编辑器口径，波次 B4）。
  static const double _minViewScale = 0.25;
  static const double _maxViewScale = 3.0;
  static const double _zoomStep = 1.2;

  late WbMindNode _root;
  late WbMindLayout _layout;
  late String _selectedId;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  int _idSeq = 0;

  /// 预览平移量（值由预览层按内容 / 视口钳制后回传，见 `_clampPanOffset`）。
  Offset _panOffset = Offset.zero;

  /// 画布缩放（1.0 = 100%；`Transform.scale` 围绕预览区中心）。
  double _viewScale = 1.0;

  @override
  void initState() {
    super.initState();
    _root = widget.initialRoot ?? WbMindNode.sample();
    _layout = widget.initialLayout;
    _selectedId = _root.id;
    _textController.text = _root.text;
    _idSeq = _root.count + 16;
  }

  @override
  void dispose() {
    _textController.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged?.call(_root);

  void _select(String id) {
    final WbMindNode? node = _root.nodeById(id);
    setState(() {
      _selectedId = id;
      _textController.text = node?.text ?? '';
    });
  }

  /// 聚焦底部文本编辑区；[selectAll] 时全选文本，便于直接覆盖输入。
  void _requestTextFocus({bool selectAll = false}) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) {
        return;
      }
      if (selectAll) {
        _textController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _textController.text.length,
        );
      }
      _textFocus.requestFocus();
    });
  }

  /// 为 [id] 节点追加子节点（折叠节点先展开），自动选中并聚焦文本编辑区。
  void _addChildTo(String id) {
    final WbMindNode? target = _root.nodeById(id);
    if (target == null) {
      return;
    }
    final String childId = 'm${++_idSeq}';
    setState(() {
      _root = _root.mapById(
        target.id,
        (WbMindNode node) => node.copyWith(
          collapsed: false,
          children: <WbMindNode>[
            ...node.children,
            WbMindNode(id: childId, text: '新节点'),
          ],
        ),
      );
    });
    _emit();
    _select(childId);
    _requestTextFocus();
  }

  /// 在 [id] 节点之后插入兄弟节点（根节点无兄弟位），自动选中并聚焦文本编辑区。
  void _addSiblingTo(String id) {
    final WbMindNode? target = _root.nodeById(id);
    if (target == null || target.id == _root.id) {
      return;
    }
    final String siblingId = 'm${++_idSeq}';
    setState(() {
      _root = _root.insertAfter(
        target.id,
        WbMindNode(id: siblingId, text: '新节点'),
      );
    });
    _emit();
    _select(siblingId);
    _requestTextFocus();
  }

  /// 工具栏「添加子节点」：作用于当前选中节点。
  void _addChild() => _addChildTo(_selectedId);

  /// 工具栏「删除」：作用于当前选中节点。
  void _deleteSelected() => _deleteNode(_selectedId);

  /// 删除 [id] 节点（根节点不可删除），删除后选中回落到根节点。
  void _deleteNode(String id) {
    final WbMindNode? target = _root.nodeById(id);
    if (target == null || target.id == _root.id) {
      return;
    }
    setState(() {
      _root = _root.removeById(target.id);
      _selectedId = _root.id;
      _textController.text = _root.text;
    });
    _emit();
  }

  /// 工具栏「折叠 / 展开」：作用于当前选中节点。
  void _toggleCollapse() => _toggleCollapseAt(_selectedId);

  /// 折叠 / 展开 [id] 节点（无子节点时忽略）。
  void _toggleCollapseAt(String id) {
    final WbMindNode? target = _root.nodeById(id);
    if (target == null || target.children.isEmpty) {
      return;
    }
    setState(() {
      _root = _root.mapById(
        target.id,
        (WbMindNode node) => node.copyWith(collapsed: !node.collapsed),
      );
    });
    _emit();
  }

  /// 选中 [id] 并进入重命名：聚焦文本编辑区并全选当前文本。
  void _beginRename(String id) {
    _select(id);
    _requestTextFocus(selectAll: true);
  }

  void _rename(String text) {
    final WbMindNode? selected = _root.nodeById(_selectedId);
    if (selected == null) {
      return;
    }
    setState(() {
      _root = _root.mapById(
        selected.id,
        (WbMindNode node) => node.copyWith(text: text),
      );
    });
    _emit();
  }

  /// 预览拖动平移（值已由预览层钳制，见 `_clampPanOffset`）。
  void _updatePan(Offset offset) {
    if (offset == _panOffset) {
      return;
    }
    setState(() => _panOffset = offset);
  }

  void _setLayout(WbMindLayout layout) {
    if (_layout == layout) {
      return;
    }
    setState(() => _layout = layout);
    widget.onLayoutChanged?.call(layout);
  }

  // ---- 画布缩放（波次 B4） -------------------------------------------------

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
  /// 中心放大 / 缩小；命中测试沿变换链自动做逆变换，缩放后的节点点选 /
  /// 右键菜单 / 空白拖动平移均无需额外换算（`DragUpdateDetails.delta`
  /// 已是局部坐标）。
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

  /// 右键菜单锚点（相对 Overlay 的矩形，与图层 / 页面面板菜单同口径）。
  RelativeRect _menuPosition(Offset globalPosition) {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    return RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      overlay.size.width - globalPosition.dx,
      overlay.size.height - globalPosition.dy,
    );
  }

  /// 打开节点右键上下文菜单。
  ///
  /// 菜单先选中该节点；「添加兄弟节点」「删除」在根节点上禁用，
  /// 「折叠 / 展开」在无子节点时禁用。
  Future<void> _showNodeContextMenu(String id, Offset globalPosition) async {
    final WbMindNode? node = _root.nodeById(id);
    if (node == null) {
      return;
    }
    _select(node.id);
    final bool isRoot = node.id == _root.id;
    final WbThemeColors colors = context.wbColors;
    final String? action = await showMenu<String>(
      context: context,
      position: _menuPosition(globalPosition),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: const ValueKey<String>('wb-ctx-mind-menu-add-child'),
          value: 'add-child',
          height: 36,
          child: _menuRow(colors, LinearIcons.add, '添加子节点'),
        ),
        PopupMenuItem<String>(
          key: const ValueKey<String>('wb-ctx-mind-menu-add-sibling'),
          value: 'add-sibling',
          height: 36,
          enabled: !isRoot,
          child: _menuRow(colors, LinearIcons.addPage, '添加兄弟节点'),
        ),
        PopupMenuItem<String>(
          key: const ValueKey<String>('wb-ctx-mind-menu-rename'),
          value: 'rename',
          height: 36,
          child: _menuRow(colors, LinearIcons.pen, '重命名'),
        ),
        PopupMenuItem<String>(
          key: const ValueKey<String>('wb-ctx-mind-menu-collapse'),
          value: 'collapse',
          height: 36,
          enabled: node.children.isNotEmpty,
          child: _menuRow(
            colors,
            LinearIcons.layers,
            node.collapsed ? '展开' : '折叠',
          ),
        ),
        const PopupMenuDivider(height: 6),
        PopupMenuItem<String>(
          key: const ValueKey<String>('wb-ctx-mind-menu-delete'),
          value: 'delete',
          height: 36,
          enabled: !isRoot,
          child: _menuRow(colors, LinearIcons.delete, '删除'),
        ),
      ],
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case 'add-child':
        _addChildTo(node.id);
      case 'add-sibling':
        _addSiblingTo(node.id);
      case 'rename':
        _beginRename(node.id);
      case 'collapse':
        _toggleCollapseAt(node.id);
      case 'delete':
        _deleteNode(node.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final WbMindNode? selected = _root.nodeById(_selectedId);
    return WbEditorWorkspace(
      toolbar: _buildToolbar(context),
      child: WbEditorPanes(
        left: _buildLeftPanel(context, selected),
        center: _buildPreviewArea(),
        right: _buildRightPanel(context, selected),
      ),
    );
  }

  /// 左面板：节点操作 + 布局风格（窄栏垂直滚动；控件搬家、key 不动）。
  Widget _buildLeftPanel(BuildContext context, WbMindNode? selected) {
    final bool canCollapse =
        selected != null && selected.children.isNotEmpty;
    final bool canDelete = selected != null && selected.id != _root.id;
    final String scope = selected == null
        ? '未选中'
        : (selected.id == _root.id ? '根节点' : '已选中');
    return Container(
      key: const ValueKey<String>('wb-ctx-mind-left-panel'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 根节点即初始选中，删除按钮对根节点禁用。
            WbEditorSectionTitle(
              title: '节点操作',
              trailing: WbEditorHint(scope),
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-mind-add'),
              icon: LinearIcons.add,
              label: '添加子节点',
              tooltip: '添加子节点',
              onTap: _addChild,
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-mind-delete'),
              icon: LinearIcons.delete,
              label: '删除节点',
              tooltip: '删除选中节点（根节点不可删除）',
              enabled: canDelete,
              onTap: _deleteSelected,
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-mind-collapse'),
              icon: LinearIcons.layers,
              label: '折叠 / 展开',
              tooltip: '折叠 / 展开选中节点',
              enabled: canCollapse,
              onTap: _toggleCollapse,
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-mind-rename'),
              icon: LinearIcons.pen,
              label: '重命名',
              tooltip: '重命名选中节点（聚焦右侧文本框）',
              onTap: () => _beginRename(_selectedId),
            ),
            const SizedBox(height: 8),
            const WbEditorSectionTitle(title: '布局风格'),
            for (final WbMindLayout layout in WbMindLayout.values)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: WbEditorChip(
                    key: ValueKey<String>('wb-ctx-mind-layout-${layout.id}'),
                    label: layout.label,
                    dense: true,
                    selected: _layout == layout,
                    onTap: () => _setLayout(layout),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Text(
              '${_root.count} 节点 · ${_layout.label}',
              style: WbTypography.caption.copyWith(
                color: context.wbColors.icon.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 4),
            const WbEditorHint(
              '提示：滚轮或工具条按钮缩放画布；拖动空白处平移视图；'
              '节点右键可加子节点 / 加兄弟 / 重命名 / 折叠 / 删除。',
            ),
          ],
        ),
      ),
    );
  }

  /// 左面板操作行：图标按钮（带稳定 key / tooltip）+ 文字标签。
  Widget _panelAction({
    required Key key,
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final WbThemeColors colors = context.wbColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          WbEditorIconButton(
            key: key,
            icon: icon,
            tooltip: tooltip,
            enabled: enabled,
            size: 26,
            iconSize: 15,
            onTap: onTap,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: WbTypography.caption.copyWith(
                color: colors.icon.withValues(alpha: enabled ? 1 : 0.4),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 中间：最大化预览 + 滚轮缩放（围绕预览区中心，0.25x~3x）。
  Widget _buildPreviewArea() {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _handlePointerSignal,
      child: ClipRect(
        child: Transform.scale(
          key: const ValueKey<String>('wb-ctx-mind-preview-transform'),
          scale: _viewScale,
          // 默认 alignment: Alignment.center，即围绕预览区中心缩放。
          child: _MindPreview(
            root: _root,
            layout: _layout,
            selectedId: _selectedId,
            panOffset: _panOffset,
            viewScale: _viewScale,
            onPanChanged: _updatePan,
            onSelect: _select,
            onAddChild: _addChildTo,
            onToggleCollapse: (String id) {
              _select(id);
              _toggleCollapseAt(id);
            },
            onContextMenu: _showNodeContextMenu,
          ),
        ),
      ),
    );
  }

  /// 右面板：节点属性（垂直可滚动）。
  Widget _buildRightPanel(BuildContext context, WbMindNode? selected) {
    return Container(
      key: const ValueKey<String>('wb-ctx-mind-right-panel'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: _buildInspector(context, selected),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        // 画布缩放控件：- / 当前百分比 / + / 重置（100%）。
        _buildZoomControls(context),
      ],
    );
  }

  /// 缩放控件（工具条）：缩小 / 百分比文本 / 放大 / 重置 100%。
  Widget _buildZoomControls(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-mind-zoom-out'),
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
          key: const ValueKey<String>('wb-ctx-mind-zoom-in'),
          icon: LinearIcons.zoomIn,
          tooltip: '放大画布',
          onTap: () => _zoomBy(_zoomStep),
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-mind-zoom-reset'),
          icon: LinearIcons.refresh,
          tooltip: '重置缩放（100%）',
          onTap: _resetView,
        ),
      ],
    );
  }

  /// 右面板内容（竖排）：节点文本编辑 + 选中状态提示。
  Widget _buildInspector(BuildContext context, WbMindNode? selected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        WbEditorSectionTitle(
          title: '节点属性',
          trailing: selected == null
              ? null
              : WbEditorHint(
                  selected.id == _root.id ? '根节点' : '选中：${selected.text}',
                ),
        ),
        if (selected == null)
          const WbEditorHint('点击节点选中后可重命名 / 添加子节点。')
        else
          TextField(
            key: const ValueKey<String>('wb-ctx-mind-text'),
            controller: _textController,
            focusNode: _textFocus,
            style: WbTypography.body.copyWith(color: context.wbColors.icon),
            decoration: wbEditorInputDecoration(context, hint: '节点文本'),
            onChanged: _rename,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 预览区
// ---------------------------------------------------------------------------

class _MindPreview extends StatelessWidget {
  const _MindPreview({
    required this.root,
    required this.layout,
    required this.selectedId,
    required this.panOffset,
    required this.viewScale,
    required this.onPanChanged,
    required this.onSelect,
    required this.onAddChild,
    required this.onToggleCollapse,
    required this.onContextMenu,
  });

  final WbMindNode root;
  final WbMindLayout layout;
  final String selectedId;

  /// 预览平移量（由编辑器持有，拖动时经 [onPanChanged] 回传钳制后的值）。
  final Offset panOffset;

  /// 画布缩放（与编辑器 `_viewScale` 同步；平移钳制按缩放后的可视尺寸折算）。
  final double viewScale;

  /// 平移回调（值为钳制后的绝对平移量）。
  final ValueChanged<Offset> onPanChanged;

  final ValueChanged<String> onSelect;

  /// 节点「+」按钮：为该节点添加子节点。
  final ValueChanged<String> onAddChild;

  final ValueChanged<String> onToggleCollapse;

  /// 节点右键菜单回调（参数为节点 id 与全局坐标）。
  final void Function(String id, Offset globalPosition) onContextMenu;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(
          math.max(constraints.maxWidth, 1),
          math.max(constraints.maxHeight, 1),
        );
        final WbMindLayoutResult result = WbMindLayoutEngine.layout(
          root: root,
          layout: layout,
          canvas: size,
        );
        // 内容包围盒与钳制后的平移量（渲染与拖动均以钳制值为准；钳制口径
        // 按缩放后的可视尺寸折算，见 `_clampPanOffset` 的 scale 参数）。
        final Rect content = _contentBounds(result);
        final Offset pan = _clampPanOffset(
          panOffset,
          size,
          content,
          scale: viewScale,
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
          child: Container(
            color: colors.canvas,
            child: SizedBox.fromSize(
              size: size,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: <Widget>[
                  // 非节点区域：按住拖动平移视图（位于内容层之下，节点优先命中）。
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey<String>('wb-ctx-mind-preview-pan'),
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (DragUpdateDetails details) {
                        onPanChanged(
                          _clampPanOffset(
                            pan + details.delta,
                            size,
                            content,
                            scale: viewScale,
                          ),
                        );
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                  // 内容层：连线 + 节点，整体按平移量变换。
                  Positioned.fill(
                    child: Transform.translate(
                      key: const ValueKey<String>(
                        'wb-ctx-mind-preview-pan-layer',
                      ),
                      offset: pan,
                      child: Stack(
                        children: <Widget>[
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: WbMindEdgePainter(
                                  result: result,
                                  root: root,
                                  colors: colors,
                                ),
                              ),
                            ),
                          ),
                          for (final WbMindNode node in root.flatten())
                            if (result.rects[node.id] != null)
                              Positioned.fromRect(
                                rect: result.rects[node.id]!,
                                child: _MindNodeView(
                                  key: ValueKey<String>(
                                    'wb-ctx-mind-node-${node.id}',
                                  ),
                                  node: node,
                                  depth: result.depths[node.id] ?? 0,
                                  selected: node.id == selectedId,
                                  onTap: () => onSelect(node.id),
                                  onAddChild: () => onAddChild(node.id),
                                  onToggleCollapse: () =>
                                      onToggleCollapse(node.id),
                                  onContextMenu: (Offset position) =>
                                      onContextMenu(node.id, position),
                                ),
                              ),
                        ],
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
  }
}

/// 单个思维导图节点。
class _MindNodeView extends StatelessWidget {
  const _MindNodeView({
    super.key,
    required this.node,
    required this.depth,
    required this.selected,
    required this.onTap,
    required this.onAddChild,
    required this.onToggleCollapse,
    required this.onContextMenu,
  });

  final WbMindNode node;
  final int depth;
  final bool selected;

  /// 单击选中回调。
  final VoidCallback onTap;

  /// 右侧「+」按钮：为当前节点添加子节点。
  final VoidCallback onAddChild;

  final VoidCallback onToggleCollapse;

  /// 右键（次键）回调，参数为全局坐标。
  final ValueChanged<Offset> onContextMenu;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Color accent = WbContextPalette.swatches[
        depth % WbContextPalette.swatches.length];
    final bool hasChildren = node.children.isNotEmpty;
    return GestureDetector(
      onSecondaryTapUp: (TapUpDetails details) =>
          onContextMenu(details.globalPosition),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
          child: Container(
            decoration: BoxDecoration(
              color: depth == 0
                  ? WbContextPalette.softFill(accent, alpha: 0.22)
                  : colors.surface,
              borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
              border: Border.all(
                color: selected ? colors.primary : accent,
                width: selected ? 2 : 1.2,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    node.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WbTypography.label.copyWith(
                      color: colors.icon,
                      fontSize: 12,
                    ),
                  ),
                ),
                // 「+」快捷添加子节点（子级手势优先命中，不影响节点单击）。
                Tooltip(
                  message: '添加子节点',
                  waitDuration: const Duration(milliseconds: 600),
                  child: GestureDetector(
                    key: ValueKey<String>('wb-ctx-mind-node-add-${node.id}'),
                    onTap: onAddChild,
                    child: Container(
                      width: 16,
                      height: 16,
                      margin: const EdgeInsets.only(left: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors.canvas,
                        shape: BoxShape.circle,
                        border: Border.all(color: accent, width: 1),
                      ),
                      child: Icon(LinearIcons.add, size: 10, color: accent),
                    ),
                  ),
                ),
                if (hasChildren)
                  GestureDetector(
                    key: ValueKey<String>(
                      'wb-ctx-mind-collapse-badge-${node.id}',
                    ),
                    onTap: onToggleCollapse,
                    child: Container(
                      width: 16,
                      height: 16,
                      margin: const EdgeInsets.only(left: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: node.collapsed
                            ? accent.withValues(alpha: 0.2)
                            : colors.canvas,
                        shape: BoxShape.circle,
                        border: Border.all(color: accent, width: 1),
                      ),
                      child: Text(
                        node.collapsed ? '+${node.count - 1}' : '−',
                        style: WbTypography.caption.copyWith(
                          fontSize: 9,
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 思维导图连线绘制（父子贝塞尔）。
class WbMindEdgePainter extends CustomPainter {
  /// 创建绘制器。
  WbMindEdgePainter({
    required this.result,
    required this.root,
    required this.colors,
  });

  /// 布局结果。
  final WbMindLayoutResult result;

  /// 节点树（用于判断折叠状态选线型）。
  final WbMindNode root;

  /// 主题颜色。
  final WbThemeColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    for (final WbMindEdge edge in result.edges) {
      final Rect? from = result.rects[edge.fromId];
      final Rect? to = result.rects[edge.toId];
      if (from == null || to == null) {
        continue;
      }
      final bool horizontal = (to.center.dx - from.center.dx).abs() >=
          (to.center.dy - from.center.dy).abs();
      final Offset start = horizontal
          ? (to.center.dx >= from.center.dx ? from.centerRight : from.centerLeft)
          : (to.center.dy >= from.center.dy ? from.bottomCenter : from.topCenter);
      final Offset end = horizontal
          ? (to.center.dx >= from.center.dx ? to.centerLeft : to.centerRight)
          : (to.center.dy >= from.center.dy ? to.topCenter : to.bottomCenter);
      final Path path = Path()..moveTo(start.dx, start.dy);
      if (horizontal) {
        final double midX = (start.dx + end.dx) / 2;
        path.cubicTo(midX, start.dy, midX, end.dy, end.dx, end.dy);
      } else {
        final double midY = (start.dy + end.dy) / 2;
        path.cubicTo(start.dx, midY, end.dx, midY, end.dx, end.dy);
      }
      final int depth = result.depths[edge.toId] ?? 1;
      final Color color = WbContextPalette.swatches[
              depth % WbContextPalette.swatches.length]
          .withValues(alpha: 0.7);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(WbMindEdgePainter oldDelegate) =>
      oldDelegate.result != result || oldDelegate.root != root;
}

// ---------------------------------------------------------------------------
// 私有辅助
// ---------------------------------------------------------------------------

/// 上下文菜单行（图标 + 文本，风格与图层 / 页面面板右键菜单一致）。
Widget _menuRow(WbThemeColors colors, IconData icon, String label) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(icon, size: 16, color: colors.icon),
      const SizedBox(width: 8),
      Text(label, style: const TextStyle(fontSize: 13)),
    ],
  );
}

/// 布局结果的内容包围盒（所有已排布节点外接矩形的并集）。
Rect _contentBounds(WbMindLayoutResult result) {
  Rect? bounds;
  for (final Rect rect in result.rects.values) {
    bounds = bounds == null ? rect : bounds.expandToInclude(rect);
  }
  return bounds ?? Rect.zero;
}

/// 预览平移钳制：保证内容包围盒与视口至少保留 [minVisible] 的重叠
/// （内容较小时取内容自身尺寸），避免内容被完全拖出可视区。
///
/// [scale] 为预览层缩放系数：缩放后的可视窗口在未缩放的局部坐标中
/// 为画布按中心缩放后的矩形，宽高均为 `canvas / scale` 且居中；
/// 因此钳制区间按该可视窗口计算，`scale == 1` 时退化为原始口径。
Offset _clampPanOffset(
  Offset pan,
  Size canvas,
  Rect content, {
  double minVisible = 56,
  double scale = 1.0,
}) {
  final double safeScale = scale <= 0 ? 1.0 : scale;
  final double viewWidth = canvas.width / safeScale;
  final double viewHeight = canvas.height / safeScale;
  final double viewLeft = (canvas.width - viewWidth) / 2;
  final double viewTop = (canvas.height - viewHeight) / 2;
  final double visibleX = math.min(minVisible, math.max(content.width, 1));
  final double visibleY = math.min(minVisible, math.max(content.height, 1));
  return Offset(
    _clampPanAxis(
      pan.dx,
      viewLeft + visibleX - content.right,
      viewLeft + viewWidth - visibleX - content.left,
    ),
    _clampPanAxis(
      pan.dy,
      viewTop + visibleY - content.bottom,
      viewTop + viewHeight - visibleY - content.top,
    ),
  );
}

/// 单轴平移钳制（区间非法时取中点，兜底异常尺寸）。
double _clampPanAxis(double value, double min, double max) {
  if (min > max) {
    return (min + max) / 2;
  }
  return value.clamp(min, max);
}
