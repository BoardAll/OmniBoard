/// 可扩展工具栏配置模型（ToolRegistry / ContextResolver 的 Dart 数据面）。
///
/// 数据来源：《可扩展工具栏设计 v1.0》
/// - §3 ToolRegistry：工具 id / 名称 / 图标 / 快捷键 / 分组；
/// - §4 ContextResolver：对象类型 → 工具栏映射与多选解析规则；
/// - §5–16：默认工具栏与各对象类型上下文工具栏的按钮清单；
/// - §18：工具栏尺寸 / 圆角 / 溢出折叠相关度量。
///
/// 工具 id 取设计文档原文（camelCase，如 `element.setColor`）；core 契约
/// `core/tools/schema/tool.schema.json` 的 id 正则为小写点分风格，接入
/// 引擎执行前需做一次 id 映射（见 implementation 报告偏差清单）。
///
/// 本文件为纯数据 + 纯函数：不依赖 Material UI，可被工具栏、命令层与
/// 测试直接复用。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:whiteboard_icons/icons.dart';

// ===== 1. 工具 id 与视觉度量 =================================================

/// 主工具栏条目 id（与画布工具 / 命令总线命名一致）。
abstract final class WbToolbarToolIds {
  // 9 类绘图工具（与 `WbCanvasTool.id` 完全一致）。
  static const String select = 'select';
  static const String hand = 'hand';
  static const String pen = 'pen';
  static const String highlighter = 'highlighter';
  static const String eraser = 'eraser';
  static const String sticky = 'sticky';
  static const String text = 'text';
  static const String shape = 'shape';
  static const String image = 'image';

  // 动作条目。
  static const String undo = 'edit.undo';
  static const String redo = 'edit.redo';
  static const String more = 'more';

  // 更多菜单内的固定动作（文档 §5：更多 → 设置、快捷键）。
  static const String settings = 'app.settings';
  static const String shortcuts = 'app.shortcuts';
}

/// 工具栏视觉度量（文档 §18.1 尺寸表）。
abstract final class WbToolbarMetrics {
  /// 工具栏高度。
  static const double barHeight = 40;

  /// 按钮尺寸（32×32）。
  static const double buttonSize = 32;

  /// 图标尺寸。
  static const double iconSize = 20;

  /// 条目间距。
  static const double gap = 4;

  /// 按钮圆角。
  static const double radius = 8;

  /// 容器圆角（文档未单列容器值，取 radius.l = 12 与 40 高协调）。
  static const double containerRadius = 12;

  /// 容器左右内边距（文档 4px 8px → 水平 8+8）。
  static const double barPadding = 16;

  /// 容器竖直内边距（4+4，与按钮 32 合计 40 高）。
  static const double barPaddingV = 4;

  /// 单个条目占位宽度（按钮 + 间距）。
  static const double itemExtent = buttonSize + gap;

  /// 固定区前分隔线占位宽度（线宽 1 + 左右 margin）。
  static const double separatorExtent = 12;
}

// ===== 2. 主工具栏（无选中 / 默认工具栏）===================================

/// 主工具栏条目（工具或动作）。
class WbToolbarItem {
  const WbToolbarItem({
    required this.id,
    required this.label,
    required this.icon,
    this.shortcut = '',
  });

  /// 稳定 id（工具 id / 动作 id）。
  final String id;

  /// 中文显示名。
  final String label;

  /// 图标（仅使用 `whiteboard_icons` 现有图标）。
  final IconData icon;

  /// 单字母快捷键角标（仅显示提示，不注册全局快捷键；空串不显示）。
  final String shortcut;

  @override
  String toString() => 'WbToolbarItem($id)';
}

/// 主工具栏分组（声明式配置：分组 / 顺序 / 溢出折叠的数据源）。
class WbToolbarGroup {
  const WbToolbarGroup({
    required this.id,
    required this.label,
    required this.items,
  });

  /// 稳定分组 id。
  final String id;

  /// 分组显示名（供 Tooltip / 报告使用）。
  final String label;

  /// 组内条目（依序）。
  final List<WbToolbarItem> items;
}

/// 主工具栏目录：9 类工具 + 撤销 / 重做 / 更多。
///
/// 快捷键角标依据：《齿轮圆盘交互详细设计 v1.1》§3.1 已定义
/// `V / N / R / P / I`；其余 4 项（抓手 / 荧光笔 / 橡皮 / 文本）在该文档
/// 未给出字母，按同类工具通用约定补全为 `H / M / E / T`（仅作角标提示）。
abstract final class WbMainToolbar {
  /// 工具分组（组间渲染细分隔）。
  static const List<WbToolbarGroup> groups = <WbToolbarGroup>[
    WbToolbarGroup(
      id: 'navigate',
      label: '选择 / 导航',
      items: <WbToolbarItem>[
        WbToolbarItem(
          id: WbToolbarToolIds.select,
          label: '选择',
          icon: LinearIcons.select,
          shortcut: 'V',
        ),
        WbToolbarItem(
          id: WbToolbarToolIds.hand,
          label: '抓手',
          icon: LinearIcons.hand,
          shortcut: 'H',
        ),
      ],
    ),
    WbToolbarGroup(
      id: 'draw',
      label: '绘制',
      items: <WbToolbarItem>[
        WbToolbarItem(
          id: WbToolbarToolIds.pen,
          label: '画笔',
          icon: LinearIcons.pen,
          shortcut: 'P',
        ),
        WbToolbarItem(
          id: WbToolbarToolIds.highlighter,
          label: '荧光笔',
          icon: LinearIcons.highlighter,
          shortcut: 'M',
        ),
        WbToolbarItem(
          id: WbToolbarToolIds.eraser,
          label: '橡皮擦',
          icon: LinearIcons.eraser,
          shortcut: 'E',
        ),
      ],
    ),
    WbToolbarGroup(
      id: 'create',
      label: '创建',
      items: <WbToolbarItem>[
        WbToolbarItem(
          id: WbToolbarToolIds.sticky,
          label: '便签',
          icon: LinearIcons.stickyNote,
          shortcut: 'N',
        ),
        WbToolbarItem(
          id: WbToolbarToolIds.text,
          label: '文本',
          icon: LinearIcons.text,
          shortcut: 'T',
        ),
        WbToolbarItem(
          id: WbToolbarToolIds.shape,
          label: '形状',
          icon: LinearIcons.shape,
          shortcut: 'R',
        ),
        WbToolbarItem(
          id: WbToolbarToolIds.image,
          label: '图片',
          icon: LinearIcons.image,
          shortcut: 'I',
        ),
      ],
    ),
  ];

  /// 撤销动作。
  static const WbToolbarItem undo = WbToolbarItem(
    id: WbToolbarToolIds.undo,
    label: '撤销',
    icon: LinearIcons.undo,
  );

  /// 重做动作。
  static const WbToolbarItem redo = WbToolbarItem(
    id: WbToolbarToolIds.redo,
    label: '重做',
    icon: LinearIcons.redo,
  );

  /// 更多入口（溢出菜单）。
  static const WbToolbarItem more = WbToolbarItem(
    id: WbToolbarToolIds.more,
    label: '更多',
    icon: LinearIcons.more,
  );

  /// 全部工具（按分组顺序扁平化）。
  static List<WbToolbarItem> get tools {
    return <WbToolbarItem>[
      for (final WbToolbarGroup group in groups) ...group.items,
    ];
  }

  /// 按 id 查找工具；未找到返回 null。
  static WbToolbarItem? toolById(String id) {
    for (final WbToolbarItem item in tools) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }
}

// ===== 3. 上下文目标（ContextResolver，文档 §4）=============================

/// 上下文对象类型（文档 §4.1 对象类型与工具栏映射）。
enum WbContextTargetType {
  /// 无选中（显示默认 / 主工具栏）。
  none('none', '未选中'),

  /// 便签。
  note('sticky', '便签'),

  /// 文本。
  text('text', '文本'),

  /// 形状。
  shape('shape', '形状'),

  /// 连线。
  connector('connector', '连线'),

  /// 图片。
  image('image', '图片'),

  /// 3D 渲染。
  render3d('render3d', '3D'),

  /// 函数。
  function('function', '函数'),

  /// 2D 渲染。
  render2d('render2d', '2D'),

  /// 表格。
  table('table', '表格'),

  /// 思维导图。
  mindmap('mindmap', '思维导图'),

  /// 流程图。
  flowchart('flowchart', '流程图'),

  /// 多选。
  multiSelect('multiSelect', '多选'),

  /// Frame。
  frame('frame', 'Frame'),

  /// 单选但类型未知（无解析器 / 引擎元素类型未映射）。
  unknown('unknown', '元素');

  const WbContextTargetType(this.id, this.label);

  /// 稳定 id（对齐 `element.schema.json` 的 type 取值风格）。
  final String id;

  /// 中文显示名（工具栏类型标签 / Tooltip）。
  final String label;

  /// 是否为"有上下文"的类型（可显示上下文工具栏）。
  bool get isContextful =>
      this != WbContextTargetType.none && this != WbContextTargetType.unknown;

  @override
  String toString() => 'WbContextTargetType($id)';
}

/// 元素类型解析器：由元素 id 得到上下文类型（画布 / 引擎侧提供）。
typedef WbContextTypeResolver = WbContextTargetType Function(String elementId);

/// 上下文目标：ContextResolver 的解析结果。
class WbContextTarget {
  const WbContextTarget({
    required this.type,
    this.count = 1,
    this.elementIds = const <String>[],
  });

  /// 对象类型。
  final WbContextTargetType type;

  /// 选中数量。
  final int count;

  /// 选中元素 id（可空：仅类型驱动场景）。
  final List<String> elementIds;

  /// 是否空目标（无选中 → 显示主工具栏）。
  bool get isEmpty => type == WbContextTargetType.none || count <= 0;

  /// 多选目标。
  bool get isMultiSelect => type == WbContextTargetType.multiSelect;

  /// 解析规则（文档 §4.2）：
  /// 空选区 → none；多选 → multiSelect；单元素 → 类型解析（未知回退 unknown）。
  static WbContextTarget fromSelection(
    Iterable<String> ids, {
    WbContextTypeResolver? resolver,
  }) {
    final List<String> list = ids.toList(growable: false);
    if (list.isEmpty) {
      return const WbContextTarget(type: WbContextTargetType.none, count: 0);
    }
    if (list.length > 1) {
      return WbContextTarget(
        type: WbContextTargetType.multiSelect,
        count: list.length,
        elementIds: list,
      );
    }
    final WbContextTargetType type =
        resolver?.call(list.first) ?? WbContextTargetType.unknown;
    return WbContextTarget(type: type, elementIds: list);
  }

  @override
  String toString() =>
      'WbContextTarget(${type.id}, count: $count, ids: $elementIds)';
}

// ===== 4. 上下文工具栏（文档 §6–16）=========================================

/// 上下文条目的交互类型。
enum WbContextItemKind {
  /// 直接执行命令。
  action,

  /// 打开颜色弹层（选色后可能进入"选色再点表面"待应用状态，文档 §11.2）。
  color,

  /// 打开单选弹层（对齐 / 线型 / 字号等）。
  choice,

  /// 打开线宽弹层。
  lineWidth,
}

/// 单选弹层的一个选项。
class WbChoiceOption {
  const WbChoiceOption({
    required this.value,
    required this.label,
    this.icon,
    this.command,
    this.args = const <String, Object?>{},
  });

  /// 选项值（命令参数 `value`）。
  final String value;

  /// 显示名。
  final String label;

  /// 行首图标（可空 → 仅文字）。
  final IconData? icon;

  /// 覆盖默认命令 id（如层级弹层的不同命令）。
  final String? command;

  /// 附加命令参数。
  final Map<String, Object?> args;

  @override
  String toString() => 'WbChoiceOption($value)';
}

/// 上下文工具栏的一个条目。
class WbContextItem {
  const WbContextItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.command,
    this.kind = WbContextItemKind.action,
    this.args = const <String, Object?>{},
    this.confirm = false,
    this.awaitsSurfacePaint = false,
    this.choiceTitle = '',
    this.choiceOptions = const <WbChoiceOption>[],
    this.colorSlot = '',
  });

  /// 稳定 id（测试与自动化引用：`wb-context-<id>`）。
  final String id;

  /// 中文显示名 / Tooltip。
  final String label;

  /// 图标。
  final IconData icon;

  /// 默认命令 id（文档工具 ID 表原文）。
  final String command;

  /// 交互类型。
  final WbContextItemKind kind;

  /// 默认命令的固定参数。
  final Map<String, Object?> args;

  /// 是否需要二次确认（文档 §3.4：删除单元素 = Confirm）。
  final bool confirm;

  /// 选色后是否进入"待应用表面"状态（文档 §11.2：3D 选色再点表面）。
  final bool awaitsSurfacePaint;

  /// 单选弹层标题。
  final String choiceTitle;

  /// 单选弹层选项。
  final List<WbChoiceOption> choiceOptions;

  /// 颜色用途槽位（回调方区分填充 / 描边 / 文本色等）。
  final String colorSlot;

  @override
  String toString() => 'WbContextItem($id -> $command)';
}

/// 上下文工具栏描述（对应文档 §19.4 的 `ContextToolbar`）。
class WbContextToolbarSpec {
  const WbContextToolbarSpec({
    required this.type,
    required this.items,
    this.moreItems = const <WbContextItem>[],
  });

  /// 适用的对象类型。
  final WbContextTargetType type;

  /// 主行条目（可溢出折叠）。
  final List<WbContextItem> items;

  /// "更多"菜单内的附加条目（文档：⋯ 复制、删除、层级等）。
  final List<WbContextItem> moreItems;
}

/// 上下文工具栏目录（文档 §6–16 逐项落地）。
///
/// 图标映射说明：文档附录图标名在 `whiteboard_icons` 中缺失时，使用语义
/// 最接近的现有图标（tag→menu、line-width→distribute-vertical、
/// screenshot→export、filter→dark-mode、measure→grid 等）。
abstract final class WbContextCatalog {
  // ---- 公共选项集 -------------------------------------------------------

  /// 字号档（便签 / 文本 / 多选批量）。
  static const List<WbChoiceOption> fontSizeOptions = <WbChoiceOption>[
    WbChoiceOption(value: '12', label: '12', args: <String, Object?>{'size': 12}),
    WbChoiceOption(value: '14', label: '14', args: <String, Object?>{'size': 14}),
    WbChoiceOption(value: '16', label: '16', args: <String, Object?>{'size': 16}),
    WbChoiceOption(value: '20', label: '20', args: <String, Object?>{'size': 20}),
    WbChoiceOption(value: '24', label: '24', args: <String, Object?>{'size': 24}),
    WbChoiceOption(value: '32', label: '32', args: <String, Object?>{'size': 32}),
  ];

  /// 水平对齐档。
  static const List<WbChoiceOption> alignOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'left', label: '左对齐', icon: LinearIcons.alignLeft),
    WbChoiceOption(
      value: 'center',
      label: '居中对齐',
      icon: LinearIcons.alignCenter,
    ),
    WbChoiceOption(
      value: 'right',
      label: '右对齐',
      icon: LinearIcons.alignRight,
    ),
  ];

  /// 线型档（文档 §12.2：实线 / 虚线 / 点线 / 点划线）。
  static const List<WbChoiceOption> lineTypeOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'solid', label: '实线'),
    WbChoiceOption(value: 'dashed', label: '虚线'),
    WbChoiceOption(value: 'dotted', label: '点线'),
    WbChoiceOption(value: 'dashdot', label: '点划线'),
  ];

  /// 连线箭头档。
  static const List<WbChoiceOption> arrowOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'none', label: '无箭头'),
    WbChoiceOption(value: 'end', label: '终点箭头'),
    WbChoiceOption(value: 'both', label: '双向箭头'),
  ];

  /// 图片透明度档（百分比）。
  static const List<WbChoiceOption> opacityOptions = <WbChoiceOption>[
    WbChoiceOption(value: '20', label: '20%', args: <String, Object?>{'percent': 20}),
    WbChoiceOption(value: '40', label: '40%', args: <String, Object?>{'percent': 40}),
    WbChoiceOption(value: '60', label: '60%', args: <String, Object?>{'percent': 60}),
    WbChoiceOption(value: '80', label: '80%', args: <String, Object?>{'percent': 80}),
    WbChoiceOption(
      value: '100',
      label: '100%',
      args: <String, Object?>{'percent': 100},
    ),
  ];

  /// 图片滤镜档（文档未明细，样例档位见报告）。
  static const List<WbChoiceOption> filterOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'none', label: '原图'),
    WbChoiceOption(value: 'grayscale', label: '灰阶'),
    WbChoiceOption(value: 'warm', label: '暖色'),
    WbChoiceOption(value: 'cool', label: '冷色'),
  ];

  /// 文本行高档。
  static const List<WbChoiceOption> lineHeightOptions = <WbChoiceOption>[
    WbChoiceOption(value: '1.2', label: '1.2', args: <String, Object?>{'height': 1.2}),
    WbChoiceOption(value: '1.5', label: '1.5', args: <String, Object?>{'height': 1.5}),
    WbChoiceOption(value: '1.8', label: '1.8', args: <String, Object?>{'height': 1.8}),
  ];

  /// 圆角档（形状）。
  static const List<WbChoiceOption> radiusOptions = <WbChoiceOption>[
    WbChoiceOption(value: '0', label: '直角', args: <String, Object?>{'radius': 0}),
    WbChoiceOption(value: '4', label: '4px', args: <String, Object?>{'radius': 4}),
    WbChoiceOption(value: '8', label: '8px', args: <String, Object?>{'radius': 8}),
    WbChoiceOption(value: '16', label: '16px', args: <String, Object?>{'radius': 16}),
  ];

  /// 表格边框档。
  static const List<WbChoiceOption> tableBorderOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'none', label: '无边框'),
    WbChoiceOption(value: 'outer', label: '外边框'),
    WbChoiceOption(value: 'all', label: '全边框'),
    WbChoiceOption(value: 'inner', label: '内网格'),
  ];

  /// 导图布局档。
  static const List<WbChoiceOption> mindmapLayoutOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'right', label: '向右'),
    WbChoiceOption(value: 'left', label: '向左'),
    WbChoiceOption(value: 'both', label: '双向'),
    WbChoiceOption(value: 'radial', label: '放射'),
  ];

  /// 导图连线档。
  static const List<WbChoiceOption> mindmapConnectorOptions =
      <WbChoiceOption>[
    WbChoiceOption(value: 'straight', label: '直线'),
    WbChoiceOption(value: 'curve', label: '曲线'),
    WbChoiceOption(value: 'elbow', label: '折线'),
  ];

  /// 导图间距档。
  static const List<WbChoiceOption> mindmapSpacingOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'compact', label: '紧凑'),
    WbChoiceOption(value: 'normal', label: '标准'),
    WbChoiceOption(value: 'loose', label: '宽松'),
  ];

  /// 流程图形状档。
  static const List<WbChoiceOption> flowchartShapeOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'rect', label: '矩形'),
    WbChoiceOption(value: 'rounded', label: '圆角矩形'),
    WbChoiceOption(value: 'diamond', label: '菱形'),
    WbChoiceOption(value: 'circle', label: '圆形'),
  ];

  /// 3D 材质档（文档未明细，样例档位见报告）。
  static const List<WbChoiceOption> materialOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'standard', label: '标准'),
    WbChoiceOption(value: 'glass', label: '玻璃'),
    WbChoiceOption(value: 'metal', label: '金属'),
    WbChoiceOption(value: 'matte', label: '磨砂'),
  ];

  /// 3D 光照档（文档未明细，样例档位见报告）。
  static const List<WbChoiceOption> lightOptions = <WbChoiceOption>[
    WbChoiceOption(value: 'ambient', label: '环境光'),
    WbChoiceOption(value: 'top', label: '顶光'),
    WbChoiceOption(value: 'side', label: '侧光'),
  ];

  // ---- 按类型定义 spec ---------------------------------------------------

  static const WbContextToolbarSpec _empty =
      WbContextToolbarSpec(type: WbContextTargetType.none, items: <WbContextItem>[]);

  static const WbContextToolbarSpec _note = WbContextToolbarSpec(
    type: WbContextTargetType.note,
    items: <WbContextItem>[
      WbContextItem(id: 'color', label: '颜色', icon: LinearIcons.palette, command: 'element.setColor', kind: WbContextItemKind.color, colorSlot: 'note'),
      WbContextItem(id: 'font-size', label: '字号', icon: LinearIcons.fontSize, command: 'element.setFontSize', kind: WbContextItemKind.choice, choiceTitle: '字号', choiceOptions: fontSizeOptions),
      WbContextItem(id: 'align', label: '对齐', icon: LinearIcons.alignLeft, command: 'element.setAlign', kind: WbContextItemKind.choice, choiceTitle: '文本对齐', choiceOptions: alignOptions),
      WbContextItem(id: 'tag', label: '标签', icon: LinearIcons.menu, command: 'element.setTag'),
      WbContextItem(id: 'comment', label: '评论', icon: LinearIcons.comment, command: 'comment.create'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'duplicate', label: '复制', icon: LinearIcons.duplicate, command: 'element.duplicate'),
      WbContextItem(id: 'bring-front', label: '置顶', icon: LinearIcons.bringToFront, command: 'element.bringToFront'),
      WbContextItem(id: 'send-back', label: '置底', icon: LinearIcons.sendToBack, command: 'element.sendToBack'),
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _text = WbContextToolbarSpec(
    type: WbContextTargetType.text,
    items: <WbContextItem>[
      WbContextItem(id: 'color', label: '颜色', icon: LinearIcons.textColor, command: 'element.setColor', kind: WbContextItemKind.color, colorSlot: 'text'),
      WbContextItem(id: 'font', label: '字体', icon: LinearIcons.text, command: 'element.setFont', kind: WbContextItemKind.choice, choiceTitle: '字体', choiceOptions: <WbChoiceOption>[WbChoiceOption(value: 'sans', label: '无衬线'), WbChoiceOption(value: 'serif', label: '衬线'), WbChoiceOption(value: 'mono', label: '等宽')]),
      WbContextItem(id: 'bold', label: '加粗', icon: LinearIcons.bold, command: 'element.setFont', args: <String, Object?>{'bold': true}),
      WbContextItem(id: 'italic', label: '斜体', icon: LinearIcons.italic, command: 'element.setFont', args: <String, Object?>{'italic': true}),
      WbContextItem(id: 'underline', label: '下划线', icon: LinearIcons.underline, command: 'element.setFont', args: <String, Object?>{'underline': true}),
      WbContextItem(id: 'align', label: '对齐', icon: LinearIcons.alignLeft, command: 'element.setAlign', kind: WbContextItemKind.choice, choiceTitle: '文本对齐', choiceOptions: alignOptions),
      WbContextItem(id: 'line-height', label: '行高', icon: LinearIcons.distributeVertical, command: 'element.setLineHeight', kind: WbContextItemKind.choice, choiceTitle: '行高', choiceOptions: lineHeightOptions),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'duplicate', label: '复制', icon: LinearIcons.duplicate, command: 'element.duplicate'),
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _shape = WbContextToolbarSpec(
    type: WbContextTargetType.shape,
    items: <WbContextItem>[
      WbContextItem(id: 'fill', label: '填充', icon: LinearIcons.fillColor, command: 'element.setColor', kind: WbContextItemKind.color, colorSlot: 'fill'),
      WbContextItem(id: 'border', label: '边框', icon: LinearIcons.borderStyle, command: 'element.setBorderStyle', kind: WbContextItemKind.choice, choiceTitle: '边框', choiceOptions: lineTypeOptions),
      WbContextItem(id: 'radius', label: '圆角', icon: LinearIcons.shape, command: 'element.setRadius', kind: WbContextItemKind.choice, choiceTitle: '圆角', choiceOptions: radiusOptions),
      WbContextItem(id: 'align', label: '对齐', icon: LinearIcons.alignLeft, command: 'element.setAlign', kind: WbContextItemKind.choice, choiceTitle: '对齐', choiceOptions: alignOptions),
      WbContextItem(id: 'connect', label: '连接', icon: LinearIcons.connector, command: 'element.connect'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'duplicate', label: '复制', icon: LinearIcons.duplicate, command: 'element.duplicate'),
      WbContextItem(id: 'bring-front', label: '置顶', icon: LinearIcons.bringToFront, command: 'element.bringToFront'),
      WbContextItem(id: 'send-back', label: '置底', icon: LinearIcons.sendToBack, command: 'element.sendToBack'),
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _connector = WbContextToolbarSpec(
    type: WbContextTargetType.connector,
    items: <WbContextItem>[
      WbContextItem(id: 'color', label: '颜色', icon: LinearIcons.palette, command: 'element.setColor', kind: WbContextItemKind.color, colorSlot: 'stroke'),
      WbContextItem(id: 'line-type', label: '线型', icon: LinearIcons.borderStyle, command: 'element.setLineType', kind: WbContextItemKind.choice, choiceTitle: '线型', choiceOptions: lineTypeOptions),
      WbContextItem(id: 'line-width', label: '线宽', icon: LinearIcons.distributeVertical, command: 'element.setLineWidth', kind: WbContextItemKind.lineWidth),
      WbContextItem(id: 'arrow', label: '箭头', icon: LinearIcons.forward, command: 'element.setArrow', kind: WbContextItemKind.choice, choiceTitle: '箭头', choiceOptions: arrowOptions),
      WbContextItem(id: 'label', label: '标签', icon: LinearIcons.menu, command: 'element.setLabel'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'duplicate', label: '复制', icon: LinearIcons.duplicate, command: 'element.duplicate'),
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _image = WbContextToolbarSpec(
    type: WbContextTargetType.image,
    items: <WbContextItem>[
      WbContextItem(id: 'crop', label: '裁剪', icon: LinearIcons.fitScreen, command: 'image.crop'),
      WbContextItem(id: 'replace', label: '替换', icon: LinearIcons.refresh, command: 'image.replace'),
      WbContextItem(id: 'opacity', label: '透明度', icon: LinearIcons.opacity, command: 'image.setOpacity', kind: WbContextItemKind.choice, choiceTitle: '透明度', choiceOptions: opacityOptions),
      WbContextItem(id: 'filter', label: '滤镜', icon: LinearIcons.darkMode, command: 'image.setFilter', kind: WbContextItemKind.choice, choiceTitle: '滤镜', choiceOptions: filterOptions),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'duplicate', label: '复制', icon: LinearIcons.duplicate, command: 'element.duplicate'),
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _render3d = WbContextToolbarSpec(
    type: WbContextTargetType.render3d,
    items: <WbContextItem>[
      WbContextItem(id: 'face-color', label: '颜色', icon: LinearIcons.palette, command: 'render.3d.setFaceColor', kind: WbContextItemKind.color, awaitsSurfacePaint: true, colorSlot: 'face'),
      WbContextItem(id: 'material', label: '材质', icon: LinearIcons.layers, command: 'render.3d.setMaterial', kind: WbContextItemKind.choice, choiceTitle: '材质', choiceOptions: materialOptions),
      WbContextItem(id: 'light', label: '光照', icon: LinearIcons.light, command: 'render.3d.setLight', kind: WbContextItemKind.choice, choiceTitle: '光照', choiceOptions: lightOptions),
      WbContextItem(id: 'rotate', label: '旋转', icon: LinearIcons.rotate3d, command: 'render.3d.transform'),
      WbContextItem(id: 'size', label: '尺寸', icon: LinearIcons.fullscreen, command: 'render.3d.setSize'),
      WbContextItem(id: 'screenshot', label: '截图', icon: LinearIcons.export, command: 'render.3d.screenshot'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _function = WbContextToolbarSpec(
    type: WbContextTargetType.function,
    items: <WbContextItem>[
      WbContextItem(id: 'color', label: '颜色', icon: LinearIcons.palette, command: 'render.function.setStyle', kind: WbContextItemKind.color, colorSlot: 'curve'),
      WbContextItem(id: 'line-type', label: '线型', icon: LinearIcons.borderStyle, command: 'render.function.setStyle', kind: WbContextItemKind.choice, choiceTitle: '线型', choiceOptions: lineTypeOptions),
      WbContextItem(id: 'line-width', label: '线宽', icon: LinearIcons.distributeVertical, command: 'render.function.setStyle', kind: WbContextItemKind.lineWidth),
      WbContextItem(id: 'params', label: '参数', icon: LinearIcons.settings, command: 'render.function.update'),
      WbContextItem(id: 'analyze', label: '分析', icon: LinearIcons.search, command: 'render.function.analyze'),
      WbContextItem(id: 'add', label: '函数', icon: LinearIcons.add, command: 'render.function.add'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _render2d = WbContextToolbarSpec(
    type: WbContextTargetType.render2d,
    items: <WbContextItem>[
      WbContextItem(id: 'color', label: '颜色', icon: LinearIcons.palette, command: 'render.2d.setStyle', kind: WbContextItemKind.color, colorSlot: 'stroke'),
      WbContextItem(id: 'line-type', label: '线型', icon: LinearIcons.borderStyle, command: 'render.2d.setStyle', kind: WbContextItemKind.choice, choiceTitle: '线型', choiceOptions: lineTypeOptions),
      WbContextItem(id: 'line-width', label: '线宽', icon: LinearIcons.distributeVertical, command: 'render.2d.setStyle', kind: WbContextItemKind.lineWidth),
      WbContextItem(id: 'annotate', label: '标注', icon: LinearIcons.pen, command: 'render.2d.annotate'),
      WbContextItem(id: 'measure', label: '测量', icon: LinearIcons.grid, command: 'render.2d.measure'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _table = WbContextToolbarSpec(
    type: WbContextTargetType.table,
    items: <WbContextItem>[
      WbContextItem(id: 'background', label: '背景', icon: LinearIcons.board, command: 'table.setCellStyle', kind: WbContextItemKind.color, colorSlot: 'cell-background'),
      WbContextItem(id: 'border', label: '边框', icon: LinearIcons.borderStyle, command: 'table.setCellStyle', kind: WbContextItemKind.choice, choiceTitle: '表格边框', choiceOptions: tableBorderOptions),
      WbContextItem(id: 'align', label: '对齐', icon: LinearIcons.alignLeft, command: 'table.setCellStyle', kind: WbContextItemKind.choice, choiceTitle: '单元格对齐', choiceOptions: alignOptions),
      WbContextItem(id: 'formula', label: '公式', icon: LinearIcons.formula, command: 'table.setFormula'),
      WbContextItem(id: 'sort', label: '排序', icon: LinearIcons.import, command: 'table.sort'),
      WbContextItem(id: 'filter', label: '筛选', icon: LinearIcons.search, command: 'table.filter'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _mindmap = WbContextToolbarSpec(
    type: WbContextTargetType.mindmap,
    items: <WbContextItem>[
      WbContextItem(id: 'color', label: '颜色', icon: LinearIcons.palette, command: 'mindmap.setStyle', kind: WbContextItemKind.color, colorSlot: 'node'),
      WbContextItem(id: 'layout', label: '布局', icon: LinearIcons.distributeHorizontal, command: 'mindmap.setLayout', kind: WbContextItemKind.choice, choiceTitle: '导图布局', choiceOptions: mindmapLayoutOptions),
      WbContextItem(id: 'add-node', label: '节点', icon: LinearIcons.add, command: 'mindmap.addNode'),
      WbContextItem(id: 'connector', label: '连线', icon: LinearIcons.connector, command: 'mindmap.setConnector', kind: WbContextItemKind.choice, choiceTitle: '连线样式', choiceOptions: mindmapConnectorOptions),
      WbContextItem(id: 'spacing', label: '间距', icon: LinearIcons.distributeVertical, command: 'mindmap.setSpacing', kind: WbContextItemKind.choice, choiceTitle: '节点间距', choiceOptions: mindmapSpacingOptions),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _flowchart = WbContextToolbarSpec(
    type: WbContextTargetType.flowchart,
    items: <WbContextItem>[
      WbContextItem(id: 'color', label: '颜色', icon: LinearIcons.palette, command: 'flowchart.setStyle', kind: WbContextItemKind.color, colorSlot: 'node'),
      WbContextItem(id: 'shape', label: '形状', icon: LinearIcons.shape, command: 'flowchart.setShape', kind: WbContextItemKind.choice, choiceTitle: '节点形状', choiceOptions: flowchartShapeOptions),
      WbContextItem(id: 'connect', label: '连线', icon: LinearIcons.connector, command: 'flowchart.connect'),
      WbContextItem(id: 'branch', label: '分支', icon: LinearIcons.ungroup, command: 'flowchart.labelBranches'),
      WbContextItem(id: 'align', label: '对齐', icon: LinearIcons.alignLeft, command: 'flowchart.align', kind: WbContextItemKind.choice, choiceTitle: '节点对齐', choiceOptions: alignOptions),
      WbContextItem(id: 'auto-layout', label: '布局', icon: LinearIcons.distributeHorizontal, command: 'flowchart.autoLayout'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _multiSelect = WbContextToolbarSpec(
    type: WbContextTargetType.multiSelect,
    items: <WbContextItem>[
      WbContextItem(id: 'align-left', label: '左对齐', icon: LinearIcons.alignHorizontalLeft, command: 'element.align', args: <String, Object?>{'align': 'left'}),
      WbContextItem(id: 'align-hcenter', label: '水平居中', icon: LinearIcons.alignHorizontalCenter, command: 'element.align', args: <String, Object?>{'align': 'hcenter'}),
      WbContextItem(id: 'align-right', label: '右对齐', icon: LinearIcons.alignHorizontalRight, command: 'element.align', args: <String, Object?>{'align': 'right'}),
      WbContextItem(id: 'align-top', label: '顶对齐', icon: LinearIcons.alignVerticalTop, command: 'element.align', args: <String, Object?>{'align': 'top'}),
      WbContextItem(id: 'align-vcenter', label: '垂直居中', icon: LinearIcons.alignVerticalCenter, command: 'element.align', args: <String, Object?>{'align': 'vcenter'}),
      WbContextItem(id: 'align-bottom', label: '底对齐', icon: LinearIcons.alignVerticalBottom, command: 'element.align', args: <String, Object?>{'align': 'bottom'}),
      WbContextItem(id: 'distribute-h', label: '水平分布', icon: LinearIcons.distributeHorizontal, command: 'element.distribute', args: <String, Object?>{'axis': 'horizontal'}),
      WbContextItem(id: 'distribute-v', label: '垂直分布', icon: LinearIcons.distributeVertical, command: 'element.distribute', args: <String, Object?>{'axis': 'vertical'}),
      WbContextItem(id: 'color', label: '批量颜色', icon: LinearIcons.palette, command: 'element.setColor', kind: WbContextItemKind.color, colorSlot: 'multi'),
      WbContextItem(id: 'group', label: '分组', icon: LinearIcons.group, command: 'element.group'),
      WbContextItem(id: 'ungroup', label: '取消分组', icon: LinearIcons.ungroup, command: 'element.ungroup'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'bring-front', label: '置顶', icon: LinearIcons.bringToFront, command: 'element.bringToFront'),
      WbContextItem(id: 'send-back', label: '置底', icon: LinearIcons.sendToBack, command: 'element.sendToBack'),
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _frame = WbContextToolbarSpec(
    type: WbContextTargetType.frame,
    items: <WbContextItem>[
      WbContextItem(id: 'background', label: '背景', icon: LinearIcons.board, command: 'frame.setBackground', kind: WbContextItemKind.color, colorSlot: 'frame-background'),
      WbContextItem(id: 'fit', label: '适配内容', icon: LinearIcons.fitScreen, command: 'frame.fitContent'),
      WbContextItem(id: 'lock', label: '锁定', icon: LinearIcons.lock, command: 'frame.toggleLock'),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
  );

  static const WbContextToolbarSpec _unknown = WbContextToolbarSpec(
    type: WbContextTargetType.unknown,
    items: <WbContextItem>[
      WbContextItem(id: 'color', label: '颜色', icon: LinearIcons.palette, command: 'element.setColor', kind: WbContextItemKind.color, colorSlot: 'element'),
      WbContextItem(id: 'align', label: '对齐', icon: LinearIcons.alignLeft, command: 'element.setAlign', kind: WbContextItemKind.choice, choiceTitle: '对齐', choiceOptions: alignOptions),
      WbContextItem(id: 'duplicate', label: '复制', icon: LinearIcons.duplicate, command: 'element.duplicate'),
      WbContextItem(id: 'delete', label: '删除', icon: LinearIcons.delete, command: 'element.delete', confirm: true),
    ],
    moreItems: <WbContextItem>[
      WbContextItem(id: 'bring-front', label: '置顶', icon: LinearIcons.bringToFront, command: 'element.bringToFront'),
      WbContextItem(id: 'send-back', label: '置底', icon: LinearIcons.sendToBack, command: 'element.sendToBack'),
    ],
  );

  /// 取得类型对应的上下文工具栏 spec（未配置类型回退空 spec）。
  static WbContextToolbarSpec specFor(WbContextTargetType type) {
    return switch (type) {
      WbContextTargetType.none => _empty,
      WbContextTargetType.note => _note,
      WbContextTargetType.text => _text,
      WbContextTargetType.shape => _shape,
      WbContextTargetType.connector => _connector,
      WbContextTargetType.image => _image,
      WbContextTargetType.render3d => _render3d,
      WbContextTargetType.function => _function,
      WbContextTargetType.render2d => _render2d,
      WbContextTargetType.table => _table,
      WbContextTargetType.mindmap => _mindmap,
      WbContextTargetType.flowchart => _flowchart,
      WbContextTargetType.multiSelect => _multiSelect,
      WbContextTargetType.frame => _frame,
      WbContextTargetType.unknown => _unknown,
    };
  }

  /// 全部已有 spec（测试 / 审计用）。
  static List<WbContextToolbarSpec> get all {
    return <WbContextToolbarSpec>[
      for (final WbContextTargetType type in WbContextTargetType.values)
        specFor(type),
    ];
  }
}

// ===== 5. 统一命令 =========================================================

/// 工具栏命令（统一命令层的最小 Dart 表示）。
///
/// `toolId` 为文档原文工具 id；执行到 C++ 核心前由命令层做 id 映射与
/// `wb_tool_execute(toolId, argsJson)` 拼装（Wave 4 接线）。
class WbToolbarCommand {
  const WbToolbarCommand(this.toolId, [this.args = const <String, Object?>{}]);

  /// 工具 id（如 `element.setColor` / `app.settings`）。
  final String toolId;

  /// 命令参数。
  final Map<String, Object?> args;

  @override
  String toString() => 'WbToolbarCommand($toolId, $args)';
}

/// 由上下文条目 + 交互结果构建命令（纯函数，供 UI 与测试复用）。
///
/// - [option]：单选弹层结果（命令可被 [WbChoiceOption.command] 覆盖）；
/// - [color]：选色结果（`color` 参数为 `#AARRGGBB`，含 [WbContextItem.colorSlot]）；
/// - [width]：线宽结果。
WbToolbarCommand buildWbContextCommand(
  WbContextItem item, {
  Color? color,
  double? width,
  WbChoiceOption? option,
}) {
  if (option != null) {
    return WbToolbarCommand(
      option.command ?? item.command,
      <String, Object?>{
        'value': option.value,
        ...item.args,
        ...option.args,
      },
    );
  }
  if (color != null) {
    return WbToolbarCommand(
      item.command,
      <String, Object?>{
        'color': wbColorToHex(color),
        if (item.colorSlot.isNotEmpty) 'slot': item.colorSlot,
        ...item.args,
      },
    );
  }
  if (width != null) {
    return WbToolbarCommand(
      item.command,
      <String, Object?>{'width': width, ...item.args},
    );
  }
  return WbToolbarCommand(item.command, item.args);
}

/// 颜色 → `#AARRGGBB` 十六进制串（与元素 JSON 的颜色格式一致）。
String wbColorToHex(Color color) {
  final String hex = color.toARGB32().toRadixString(16).padLeft(8, '0');
  return '#${hex.toUpperCase()}';
}

// ===== 6. 预设色板（文档 §11.2 调色板 / §18）================================

/// 工具栏预设色板与线宽 / 档位常量。
///
/// 色板与画布元素调色板同源（与 `WbCanvasPalette` 的便签 / 形状 / 画笔色
/// 一致），补齐为 12 色的通用色板；主题色由 `context.wbColors.primary`
/// 动态注入（见 `color_picker_popover.dart`），不在此硬编码。
abstract final class WbToolbarPalette {
  /// 预设 12 色（与画布调色板同源）。
  static const List<Color> presets = <Color>[
    Color(0xFF1F2933), // 墨黑（画笔）
    Color(0xFF667085), // 中灰
    Color(0xFFE5484D), // 红（形状 / 画笔）
    Color(0xFFF5A623), // 橙（形状）
    Color(0xFFF5C518), // 黄（荧光）
    Color(0xFF12A150), // 绿（形状 / 画笔）
    Color(0xFF12B5A5), // 青
    Color(0xFF3370FF), // 蓝（形状 / 画笔 / 主色）
    Color(0xFF6B4EFF), // 紫
    Color(0xFFFFD9E2), // 粉（便签）
    Color(0xFFFFF2B2), // 便签黄
    Color(0xFFCFE4FF), // 淡蓝（便签）
  ];

  /// 线宽档（与 `WbCanvasPalette.penWidths` 一致）。
  static const List<double> lineWidths = <double>[2, 4, 8];

  /// 文本颜色（便签 / 文本默认文字色，与画布调色板一致）。
  static const Color textColor = Color(0xFF1F2933);
}

// ===== 7. 溢出折叠（响应式收窄，文档 §17.2）=================================

/// 计算工具栏在可用宽度下可显示的前缀条目数（纯函数）。
///
/// 策略：按条目顺序（选择 → 抓手 → 画笔 → …）保留前缀，尾部条目折叠入
/// "更多"菜单；固定尾部（撤销 / 重做 / 更多）始终保留。
///
/// - [maxWidth]：可用宽度（无限时全显）；
/// - [padding]：容器水平内边距；
/// - [leadingExtent]：前缀固定区（如上下文类型标签）宽度；
/// - [fixedExtent]：尾部固定区（分隔线 + 撤销 / 重做 / 更多）宽度；
/// - [itemExtent]：单条占位宽（按钮 32 + 间距 4）；
/// - [separatorExtent]：工具区与固定区之间的分隔线占位宽；
/// - [total]：可折叠条目总数。
///
/// 返回可显示数量（0..total）。
int computeWbToolbarVisibleCount({
  required double maxWidth,
  required double padding,
  required double leadingExtent,
  required double fixedExtent,
  required double itemExtent,
  required int total,
  double separatorExtent = WbToolbarMetrics.separatorExtent,
}) {
  if (total <= 0) {
    return 0;
  }
  if (!maxWidth.isFinite) {
    return total;
  }
  final double budget =
      maxWidth - padding - leadingExtent - fixedExtent - separatorExtent;
  final int fit = budget <= 0 ? 0 : (budget / itemExtent).floor();
  return math.min(math.max(fit, 0), total);
}
