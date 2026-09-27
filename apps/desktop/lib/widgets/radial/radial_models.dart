/// 齿轮圆盘数据模型：工具 / 分组 / 目录 / 设置 / 命中结果。
///
/// 数据来源：《齿轮圆盘交互详细设计 v1.1》第 3、4、6.4、11 节。
/// 本文件不含 UI 依赖，可被布局、菜单与工具栏复用。
library;

import 'package:flutter/widgets.dart';
import 'package:whiteboard_icons/icons.dart';

/// 内环"更多"入口 id（动作，非绘图工具）。
const String kRadialMoreId = 'more';

/// AI 助手动作 id（文档 9.4）。
const String kRadialAiAssistantId = 'ai.assistant';

/// 打开设置动作 id（文档 4：流程图/AI 组子工具）。
const String kRadialSettingsId = 'app.settings';

/// 条目类型：可选中的绘图工具，或触发动作的入口。
enum RadialToolKind {
  /// 绘图工具（可成为"当前工具"，出现在最近使用）。
  tool,

  /// 动作入口（如"更多""AI 助手""设置"）。
  action,
}

/// 圆盘内的一个条目（内环工具 / 子工具 / 最近使用共用）。
class RadialTool {
  const RadialTool({
    required this.id,
    required this.label,
    required this.icon,
    this.keyword = '',
    this.kind = RadialToolKind.tool,
  });

  /// 稳定工具 id（供宿主 / AI `radial.selectTool` 对接）。
  final String id;

  /// 中文显示名（标签、Tooltip、轨迹线末端）。
  final String label;

  /// 图标（仅使用 `whiteboard_icons` 现有图标）。
  final IconData icon;

  /// 默认快捷键字符（文档 3.1，如 `V` / `N` / `R`）。
  final String keyword;

  /// 条目类型。
  final RadialToolKind kind;

  /// 是否为动作入口。
  bool get isAction => kind == RadialToolKind.action;
}

/// 外环分组（含子工具列表）。
class RadialGroup {
  const RadialGroup({
    required this.id,
    required this.label,
    required this.icon,
    required this.tools,
    this.secondaryIcon,
  });

  /// 稳定分组 id。
  final String id;

  /// 显示名（如"形状 / 连线"）。
  final String label;

  /// 主图标。
  final IconData icon;

  /// 副图标（文档外环示意中的第二个图标，可为空）。
  final IconData? secondaryIcon;

  /// 子工具（3–6 个；超过 6 个时子环滚动）。
  final List<RadialTool> tools;

  /// 默认工具（双击父扇区 / 拖拽命中外环时选中）。
  RadialTool get defaultTool => tools.first;
}

/// 圆盘目录：内环 6 固定工具 + 外环 8 固定分组 + 默认最近使用。
///
/// 与文档 v1.1 第 3.1 / 4 / 6.4 节逐项对应；图标映射说明见各常量注释
/// （图标集内缺失的具象图标使用语义最接近的现有图标，详见实现报告）。
abstract final class RadialCatalog {
  /// 内环 6 个高频工具（从正上方起顺时针）。
  static const List<RadialTool> inner = <RadialTool>[
    RadialTool(
      id: 'select',
      label: '选择',
      icon: LinearIcons.select,
      keyword: 'V',
    ),
    RadialTool(
      id: 'sticky',
      label: '便签',
      icon: LinearIcons.stickyNote,
      keyword: 'N',
    ),
    RadialTool(
      id: 'shape',
      label: '形状',
      icon: LinearIcons.shape,
      keyword: 'R',
    ),
    RadialTool(id: 'pen', label: '画笔', icon: LinearIcons.pen, keyword: 'P'),
    RadialTool(
      id: 'image',
      label: '图片',
      icon: LinearIcons.image,
      keyword: 'I',
    ),
    RadialTool(
      id: kRadialMoreId,
      label: '更多',
      icon: LinearIcons.more,
      kind: RadialToolKind.action,
    ),
  ];

  /// 外环 8 个分组（从正上方起顺时针）。
  static const List<RadialGroup> groups = <RadialGroup>[
    RadialGroup(
      id: 'select-hand',
      label: '选择 / 手',
      icon: LinearIcons.select,
      secondaryIcon: LinearIcons.hand,
      tools: <RadialTool>[
        RadialTool(id: 'select', label: '选择', icon: LinearIcons.select),
        RadialTool(id: 'hand', label: '手', icon: LinearIcons.hand),
        RadialTool(id: 'marquee', label: '框选', icon: LinearIcons.fitScreen),
        RadialTool(id: 'lasso', label: '套索', icon: LinearIcons.pen),
      ],
    ),
    RadialGroup(
      id: 'note-text',
      label: '便签 / 文本',
      icon: LinearIcons.stickyNote,
      secondaryIcon: LinearIcons.text,
      tools: <RadialTool>[
        RadialTool(id: 'sticky', label: '便签', icon: LinearIcons.stickyNote),
        RadialTool(id: 'text', label: '文本', icon: LinearIcons.text),
        RadialTool(id: 'heading', label: '标题', icon: LinearIcons.fontSize),
        RadialTool(id: 'list', label: '列表', icon: LinearIcons.menu),
        RadialTool(id: 'quote', label: '引用', icon: LinearIcons.comment),
      ],
    ),
    RadialGroup(
      id: 'shape-link',
      label: '形状 / 连线',
      icon: LinearIcons.shape,
      secondaryIcon: LinearIcons.forward,
      tools: <RadialTool>[
        RadialTool(id: 'rect', label: '矩形', icon: LinearIcons.shape),
        RadialTool(id: 'circle', label: '圆', icon: LinearIcons.refresh),
        RadialTool(id: 'diamond', label: '菱形', icon: LinearIcons.rotate3d),
        RadialTool(
          id: 'parallelogram',
          label: '平行四边形',
          icon: LinearIcons.distributeHorizontal,
        ),
        RadialTool(id: 'arrow', label: '箭头', icon: LinearIcons.forward),
        RadialTool(id: 'connector', label: '连线', icon: LinearIcons.connector),
      ],
    ),
    RadialGroup(
      id: 'pen-eraser',
      label: '画笔 / 橡皮',
      icon: LinearIcons.pen,
      secondaryIcon: LinearIcons.eraser,
      tools: <RadialTool>[
        RadialTool(id: 'pen', label: '画笔', icon: LinearIcons.pen),
        RadialTool(
          id: 'highlighter',
          label: '荧光笔',
          icon: LinearIcons.highlighter,
        ),
        RadialTool(id: 'eraser', label: '橡皮', icon: LinearIcons.eraser),
        RadialTool(id: 'laser', label: '激光笔', icon: LinearIcons.light),
      ],
    ),
    RadialGroup(
      id: 'image-doc',
      label: '图片 / 文档',
      icon: LinearIcons.image,
      secondaryIcon: LinearIcons.page,
      tools: <RadialTool>[
        RadialTool(id: 'image', label: '图片', icon: LinearIcons.image),
        RadialTool(id: 'pdf', label: 'PDF', icon: LinearIcons.print),
        RadialTool(id: 'doc', label: '文档', icon: LinearIcons.page),
        RadialTool(
          id: 'screenshot',
          label: '截图',
          icon: LinearIcons.fullscreen,
        ),
        RadialTool(id: 'paste', label: '贴图', icon: LinearIcons.paste),
      ],
    ),
    RadialGroup(
      id: 'mind-table',
      label: '导图 / 表格',
      icon: LinearIcons.mindmap,
      secondaryIcon: LinearIcons.table,
      tools: <RadialTool>[
        RadialTool(id: 'mindmap', label: '思维导图', icon: LinearIcons.mindmap),
        RadialTool(id: 'table', label: '表格', icon: LinearIcons.table),
        RadialTool(id: 'kanban', label: '看板', icon: LinearIcons.board),
        RadialTool(id: 'timeline', label: '时间线', icon: LinearIcons.history),
      ],
    ),
    RadialGroup(
      id: 'function-2d3d',
      label: '函数 / 3D / 2D',
      icon: LinearIcons.formula,
      secondaryIcon: LinearIcons.cube,
      tools: <RadialTool>[
        RadialTool(id: 'fn', label: '函数渲染', icon: LinearIcons.formula),
        RadialTool(id: 'render3d', label: '3D 渲染', icon: LinearIcons.cube),
        RadialTool(id: 'render2d', label: '2D 渲染', icon: LinearIcons.shape),
        RadialTool(id: 'axes', label: '坐标系', icon: LinearIcons.grid),
      ],
    ),
    RadialGroup(
      id: 'flow-ai',
      label: '流程图 / AI',
      icon: LinearIcons.flowchart,
      secondaryIcon: LinearIcons.ai,
      tools: <RadialTool>[
        RadialTool(id: 'flowchart', label: '流程图', icon: LinearIcons.flowchart),
        RadialTool(
          id: 'swimlane',
          label: '泳道图',
          icon: LinearIcons.distributeVertical,
        ),
        RadialTool(id: 'stateMachine', label: '状态机', icon: LinearIcons.sync),
        RadialTool(
          id: kRadialAiAssistantId,
          label: 'AI 助手',
          icon: LinearIcons.ai,
          kind: RadialToolKind.action,
        ),
        RadialTool(
          id: kRadialSettingsId,
          label: '设置',
          icon: LinearIcons.settings,
          kind: RadialToolKind.action,
        ),
      ],
    ),
  ];

  /// 默认最近使用工具 id（文档 3.2：选择、便签、形状）。
  static const List<String> defaultRecentIds = <String>[
    'select',
    'sticky',
    'shape',
  ];

  /// 按 id 在全部工具（内环 + 外环子工具）中查找；未找到返回 null。
  static RadialTool? toolById(String id) {
    for (final RadialTool tool in inner) {
      if (tool.id == id) {
        return tool;
      }
    }
    for (final RadialGroup group in groups) {
      for (final RadialTool tool in group.tools) {
        if (tool.id == id) {
          return tool;
        }
      }
    }
    return null;
  }

  /// 按 id 查找分组；未找到返回 null。
  static RadialGroup? groupById(String id) {
    for (final RadialGroup group in groups) {
      if (group.id == id) {
        return group;
      }
    }
    return null;
  }

  /// 分组序号；未找到返回 -1。
  static int groupIndex(String id) {
    for (int i = 0; i < groups.length; i++) {
      if (groups[i].id == id) {
        return i;
      }
    }
    return -1;
  }
}

/// 圆盘尺寸档（文档 11：小 / 中 / 大）。
enum RadialSizeOption {
  /// 小（总直径约 180px，对应小屏规格）。
  small('小', 0.75),

  /// 中（总直径 240px，默认）。
  medium('中', 1.0),

  /// 大（总直径 300px）。
  large('大', 1.25);

  const RadialSizeOption(this.label, this.scale);

  /// 中文显示名。
  final String label;

  /// 相对基准（240px）的缩放系数。
  final double scale;
}

/// 圆盘设置（不可变；右键配置菜单可修改，可回传宿主）。
class RadialSettings {
  const RadialSettings({
    this.size = RadialSizeOption.medium,
    this.showLabels = true,
    this.showRecent = true,
    this.recentCount = 3,
    this.showTrail = true,
    this.animations = true,
    this.longPressEnabled = true,
  });

  /// 尺寸档。
  final RadialSizeOption size;

  /// 是否显示条目标签（文档 11：默认"是"）。
  final bool showLabels;

  /// 是否显示最近使用快捷条。
  final bool showRecent;

  /// 最近使用数量（1–3）。
  final int recentCount;

  /// 是否显示拖拽轨迹线。
  final bool showTrail;

  /// 是否启用展开/收起动效。
  final bool animations;

  /// 是否启用长按类交互（长按锁定 / 长按弹出）。
  final bool longPressEnabled;

  /// 复制并覆盖部分字段（[recentCount] 自动夹在 1–3）。
  RadialSettings copyWith({
    RadialSizeOption? size,
    bool? showLabels,
    bool? showRecent,
    int? recentCount,
    bool? showTrail,
    bool? animations,
    bool? longPressEnabled,
  }) {
    return RadialSettings(
      size: size ?? this.size,
      showLabels: showLabels ?? this.showLabels,
      showRecent: showRecent ?? this.showRecent,
      recentCount: (recentCount ?? this.recentCount).clamp(1, 3),
      showTrail: showTrail ?? this.showTrail,
      animations: animations ?? this.animations,
      longPressEnabled: longPressEnabled ?? this.longPressEnabled,
    );
  }
}

/// 命中区域（对应文档 12.3 的 `RadialHitResult.zone`）。
enum RadialZone {
  /// 无命中 / 取消区（距中心 < 28px）。
  none,

  /// 中心。
  center,

  /// 内环（28–72px）。
  inner,

  /// 外环（72–120px）。
  outer,

  /// 子环（120–180px）。
  sub,

  /// 最近使用条。
  recent,
}

/// 命中结果。
class RadialHit {
  const RadialHit(this.zone, {this.index = -1, this.slot = -1});

  /// 无命中。
  static const RadialHit none = RadialHit(RadialZone.none);

  /// 命中区域。
  final RadialZone zone;

  /// inner / outer 的扇区序号；sub 的**子工具列表索引**。
  final int index;

  /// 子环显示槽位（0..visible-1），仅 [RadialZone.sub] 使用。
  final int slot;

  @override
  bool operator ==(Object other) =>
      other is RadialHit &&
      other.zone == zone &&
      other.index == index &&
      other.slot == slot;

  @override
  int get hashCode => Object.hash(zone, index, slot);

  @override
  String toString() => 'RadialHit(${zone.name}#$index@$slot)';
}
