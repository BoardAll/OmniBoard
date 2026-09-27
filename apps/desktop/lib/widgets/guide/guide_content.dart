/// 引导与帮助内容数据（《用户手册与帮助文档设计》§3-§7）。
///
/// 纯数据 + 少量检索逻辑，不依赖 UI 框架；文案为中文、简洁、
/// 可直接展示。快捷键条目在标注 [WbGuideShortcut.shortcutId] 时，
/// 显示键位由 [WbShortcutService.describeById] 动态生成，
/// 与应用快捷键注册表保持一致。
library;

import 'dart:ui' show Rect;

import '../../services/shortcut_service.dart';

/// 帮助中心分节（《用户手册与帮助文档设计》§2 文档体系）。
enum WbGuideSection {
  /// 快速上手（§4）：5 分钟上手 + 常用操作。
  quickStart('quick-start', '快速上手', 'board', '5 分钟上手与常用操作'),

  /// 用户手册（§5）：按主题的功能详解。
  manual('manual', '用户手册', 'page', '功能详解与场景教程'),

  /// 进阶技巧（§6）：效率技巧、高级功能与集成。
  advanced('advanced', '进阶技巧', 'light', '效率技巧与集成'),

  /// FAQ（§7）：常见问题、故障排查与反馈。
  faq('faq', 'FAQ', 'info', '常见问题与故障排查');

  const WbGuideSection(this.id, this.title, this.icon, this.subtitle);

  /// 稳定 id（用于导航与搜索跳转）。
  final String id;

  /// 中文标题。
  final String title;

  /// 语义图标名（见 `wbGuideIcon`）。
  final String icon;

  /// 辅助说明。
  final String subtitle;

  /// 按 id 查找分节（未知 id 回退到 [WbGuideSection.quickStart]）。
  static WbGuideSection fromId(String id) {
    for (final WbGuideSection section in WbGuideSection.values) {
      if (section.id == id) {
        return section;
      }
    }
    return WbGuideSection.quickStart;
  }
}

/// 引导步骤的屏幕高亮区域（相对屏幕 0..1 比例）。
///
/// 宿主接线时可替换为真实组件位置；未接线时按比例近似高亮。
class WbGuideAnchor {
  const WbGuideAnchor(this.left, this.top, this.width, this.height);

  /// 相对左边界（0..1）。
  final double left;

  /// 相对上边界（0..1）。
  final double top;

  /// 相对宽度（0..1）。
  final double width;

  /// 相对高度（0..1）。
  final double height;

  /// 按屏幕尺寸解析为绝对区域。
  Rect resolve(double screenWidth, double screenHeight) {
    return Rect.fromLTWH(
      screenWidth * left,
      screenHeight * top,
      screenWidth * width,
      screenHeight * height,
    );
  }

  /// 圆盘（右下角）。
  static const WbGuideAnchor bottomRight =
      WbGuideAnchor(0.74, 0.66, 0.22, 0.28);

  /// 画布中央（便签 / 连线）。
  static const WbGuideAnchor center = WbGuideAnchor(0.36, 0.30, 0.28, 0.24);

  /// 左侧栏（AI / 页面管理）。
  static const WbGuideAnchor leftSide =
      WbGuideAnchor(0.0, 0.28, 0.08, 0.44);
}

/// 一条新手引导步骤（§3.2 交互式引导）。
class WbGuideStep {
  const WbGuideStep({
    required this.id,
    required this.title,
    required this.message,
    required this.icon,
    required this.anchor,
  });

  /// 稳定 id（`wb-guide-step-<id>`）。
  final String id;

  /// 步骤标题（如「认识圆盘」）。
  final String title;

  /// 提示文案（如「点击圆盘展开工具」）。
  final String message;

  /// 语义图标名（见 `wbGuideIcon`）。
  final String icon;

  /// 高亮区域。
  final WbGuideAnchor anchor;
}

/// 快速上手一条（§4.1）。
class WbQuickStartStep {
  const WbQuickStartStep({required this.title, required this.detail});

  /// 操作名称。
  final String title;

  /// 一句话说明。
  final String detail;
}

/// 一条快捷键定义（§4.3 / §10.1）。
class WbGuideShortcut {
  const WbGuideShortcut({
    required this.id,
    required this.label,
    required this.keys,
    this.shortcutId = '',
  });

  /// 稳定 id（用于 `ValueKey`）。
  final String id;

  /// 中文动作名。
  final String label;

  /// 展示用键位文本（无 [shortcutId] 时使用）。
  final String keys;

  /// 应用快捷键注册表 id（[WbShortcutService]）；非空时优先动态解析。
  final String shortcutId;

  /// 生效键位：标注 [shortcutId] 时以应用注册表为准。
  String get resolvedKeys {
    if (shortcutId.isEmpty) {
      return keys;
    }
    final String described = WbShortcutService.describeById(shortcutId);
    return described.isEmpty ? keys : described;
  }
}

/// 快捷键分组（按功能归类）。
class WbGuideShortcutGroup {
  const WbGuideShortcutGroup({
    required this.id,
    required this.name,
    required this.icon,
    required this.entries,
  });

  /// 稳定 id。
  final String id;

  /// 分组名（如「工具切换」）。
  final String name;

  /// 语义图标名（见 `wbGuideIcon`）。
  final String icon;

  /// 组内条目。
  final List<WbGuideShortcut> entries;
}

/// 用户手册章节（§5.1）。
class WbManualChapter {
  const WbManualChapter({required this.title, required this.topics});

  /// 章节标题（如「01 入门」）。
  final String title;

  /// 章节内条目。
  final List<WbManualTopic> topics;
}

/// 用户手册条目（§5.1）。
class WbManualTopic {
  const WbManualTopic({required this.title, required this.summary});

  /// 条目标题（如「01 安装与启动」）。
  final String title;

  /// 一句话简介。
  final String summary;
}

/// 通用「名称 + 说明」条目（技巧、高级功能、集成、反馈等）。
class WbTipEntry {
  const WbTipEntry({required this.name, required this.detail});

  /// 名称。
  final String name;

  /// 说明。
  final String detail;
}

/// FAQ / 故障排查条目（§7）。
class WbFaqEntry {
  const WbFaqEntry({
    required this.id,
    required this.question,
    required this.answer,
    required this.category,
  });

  /// 稳定 id（`wb-guide-faq-<id>` / `wb-guide-trouble-<id>`）。
  final String id;

  /// 问题。
  final String question;

  /// 答案（可为多行列表文本）。
  final String answer;

  /// 分类标签（如「基础」「故障」）。
  final String category;
}

/// 帮助搜索结果（跨分节）。
class WbGuideSearchHit {
  const WbGuideSearchHit({
    required this.section,
    required this.title,
    required this.detail,
  });

  /// 所属分节。
  final WbGuideSection section;

  /// 命中条目标题。
  final String title;

  /// 命中条目说明。
  final String detail;
}

/// 引导/帮助静态内容表。
abstract final class WbGuideContent {
  // ---------------------------------------------------------------------
  // §3.2 交互式引导步骤（7 步）
  // ---------------------------------------------------------------------

  /// 新手引导步骤（对齐 §3.2 / §21 附录步骤清单）。
  static const List<WbGuideStep> onboardingSteps = <WbGuideStep>[
    WbGuideStep(
      id: 'radial',
      title: '认识圆盘',
      message: '点击圆盘展开工具。圆盘是白板的核心工具入口。',
      icon: 'radial',
      anchor: WbGuideAnchor.bottomRight,
    ),
    WbGuideStep(
      id: 'sticky',
      title: '创建便签',
      message: '选择便签工具，点击画布创建。',
      icon: 'stickyNote',
      anchor: WbGuideAnchor.bottomRight,
    ),
    WbGuideStep(
      id: 'sticky-edit',
      title: '编辑便签',
      message: '双击便签编辑文本，按 Tab 创建下一个便签。',
      icon: 'text',
      anchor: WbGuideAnchor.center,
    ),
    WbGuideStep(
      id: 'connector',
      title: '创建连线',
      message: '拖拽便签边缘的连接点，拉出连线。',
      icon: 'connector',
      anchor: WbGuideAnchor.center,
    ),
    WbGuideStep(
      id: 'ai',
      title: '使用 AI',
      message: '点击左侧栏 AI 图标，输入指令让 AI 帮你创作。',
      icon: 'ai',
      anchor: WbGuideAnchor.leftSide,
    ),
    WbGuideStep(
      id: 'pages',
      title: '页面管理',
      message: '点击左侧栏页面管理，查看缩略图并切换页面。',
      icon: 'page',
      anchor: WbGuideAnchor.leftSide,
    ),
    WbGuideStep(
      id: 'done',
      title: '引导完成',
      message: '已掌握基本操作，开始创作吧！',
      icon: 'check',
      anchor: WbGuideAnchor.center,
    ),
  ];

  // ---------------------------------------------------------------------
  // §4.1 5 分钟上手（8 步）
  // ---------------------------------------------------------------------

  /// 5 分钟上手步骤。
  static const List<WbQuickStartStep> quickStart = <WbQuickStartStep>[
    WbQuickStartStep(title: '打开圆盘', detail: '点击右下角齿轮圆盘，展开工具。'),
    WbQuickStartStep(title: '创建便签', detail: '选择便签工具，点击画布创建。'),
    WbQuickStartStep(title: '编辑便签', detail: '双击便签编辑，Tab 创建下一个。'),
    WbQuickStartStep(title: '创建连线', detail: '拖拽便签边缘连接点，拉出连线。'),
    WbQuickStartStep(title: '使用 AI', detail: '点击左侧栏 AI 图标，输入指令。'),
    WbQuickStartStep(title: '切换页面', detail: '点击左侧栏页面，查看缩略图。'),
    WbQuickStartStep(title: '分享白板', detail: '点击左侧栏顶部菜单，分享链接。'),
    WbQuickStartStep(title: '返回桌面', detail: '点击左侧栏菜单，返回桌面批注。'),
  ];

  // ---------------------------------------------------------------------
  // §4.3 快捷键卡片 / §10.1 快捷键总表
  // ---------------------------------------------------------------------

  /// 快捷键分组（覆盖 §10.1 总表；带快捷服务 id 的条目动态解析键位）。
  static const List<WbGuideShortcutGroup> shortcutGroups =
      <WbGuideShortcutGroup>[
    WbGuideShortcutGroup(
      id: 'general',
      name: '通用',
      icon: 'board',
      entries: <WbGuideShortcut>[
        WbGuideShortcut(id: 'radial', label: '圆盘', keys: '长按画布 / 点击右下角'),
        WbGuideShortcut(id: 'cmd.palette', label: '命令面板', keys: 'Ctrl/Cmd + K'),
        WbGuideShortcut(id: 'ai.panel', label: 'AI 面板', keys: 'Ctrl/Cmd + Shift + A'),
        WbGuideShortcut(id: 'voice', label: '语音输入', keys: '按住 Alt + Space'),
        WbGuideShortcut(id: 'pages', label: '页面管理', keys: 'Ctrl/Cmd + P'),
        WbGuideShortcut(id: 'sidebar', label: '左侧栏', keys: r'Ctrl/Cmd + \'),
        WbGuideShortcut(id: 'help', label: '帮助', keys: 'F1'),
        WbGuideShortcut(id: 'shortcuts', label: '快捷键', keys: '?'),
        WbGuideShortcut(
          id: 'file.save',
          label: '保存',
          keys: 'Ctrl/Cmd + S',
          shortcutId: 'file.save',
        ),
        WbGuideShortcut(
          id: 'file.export',
          label: '导出',
          keys: 'Ctrl/Cmd + E',
          shortcutId: 'file.export',
        ),
      ],
    ),
    WbGuideShortcutGroup(
      id: 'tools',
      name: '工具切换',
      icon: 'pen',
      entries: <WbGuideShortcut>[
        WbGuideShortcut(id: 'tool.select', label: '选择', keys: 'V'),
        WbGuideShortcut(id: 'tool.sticky', label: '便签', keys: 'N'),
        WbGuideShortcut(id: 'tool.text', label: '文本', keys: 'T'),
        WbGuideShortcut(id: 'tool.shape', label: '形状', keys: 'R'),
        WbGuideShortcut(id: 'tool.connector', label: '连线', keys: 'L'),
        WbGuideShortcut(id: 'tool.pen', label: '画笔', keys: 'P'),
        WbGuideShortcut(id: 'tool.image', label: '图片', keys: 'I'),
        WbGuideShortcut(id: 'tool.frame', label: 'Frame', keys: 'F'),
        WbGuideShortcut(id: 'tool.eraser', label: '橡皮', keys: 'E'),
        WbGuideShortcut(id: 'tool.hand', label: '手', keys: 'H'),
      ],
    ),
    WbGuideShortcutGroup(
      id: 'edit',
      name: '编辑操作',
      icon: 'undo',
      entries: <WbGuideShortcut>[
        WbGuideShortcut(
          id: 'edit.undo',
          label: '撤销',
          keys: 'Ctrl/Cmd + Z',
          shortcutId: 'edit.undo',
        ),
        WbGuideShortcut(
          id: 'edit.redo',
          label: '重做',
          keys: 'Ctrl/Cmd + Shift + Z',
          shortcutId: 'edit.redo',
        ),
        WbGuideShortcut(
          id: 'edit.copy',
          label: '复制',
          keys: 'Ctrl/Cmd + C',
          shortcutId: 'edit.copy',
        ),
        WbGuideShortcut(
          id: 'edit.cut',
          label: '剪切',
          keys: 'Ctrl/Cmd + X',
          shortcutId: 'edit.cut',
        ),
        WbGuideShortcut(
          id: 'edit.paste',
          label: '粘贴',
          keys: 'Ctrl/Cmd + V',
          shortcutId: 'edit.paste',
        ),
        WbGuideShortcut(
          id: 'edit.duplicate',
          label: '创建副本',
          keys: 'Ctrl/Cmd + D',
          shortcutId: 'edit.duplicate',
        ),
        WbGuideShortcut(
          id: 'edit.delete',
          label: '删除所选',
          keys: 'Delete',
          shortcutId: 'edit.delete',
        ),
        WbGuideShortcut(
          id: 'edit.selectAll',
          label: '全选',
          keys: 'Ctrl/Cmd + A',
          shortcutId: 'edit.selectAll',
        ),
      ],
    ),
    WbGuideShortcutGroup(
      id: 'view',
      name: '视图与页面',
      icon: 'zoomIn',
      entries: <WbGuideShortcut>[
        WbGuideShortcut(id: 'page.new', label: '新建页面', keys: 'Ctrl/Cmd + Shift + N'),
        WbGuideShortcut(id: 'page.duplicate', label: '复制页面', keys: 'Ctrl/Cmd + D'),
        WbGuideShortcut(id: 'page.next', label: '下一页', keys: 'PageDown'),
        WbGuideShortcut(id: 'page.prev', label: '上一页', keys: 'PageUp'),
        WbGuideShortcut(id: 'view.zoom', label: '缩放', keys: 'Ctrl/Cmd + 滚轮'),
        WbGuideShortcut(id: 'view.pan', label: '平移', keys: '空格 + 拖拽'),
        WbGuideShortcut(
          id: 'view.resetZoom',
          label: '重置缩放',
          keys: 'Ctrl/Cmd + 0',
          shortcutId: 'view.resetZoom',
        ),
        WbGuideShortcut(
          id: 'view.fitScreen',
          label: '适应画布',
          keys: 'Ctrl/Cmd + 1',
          shortcutId: 'view.fitScreen',
        ),
        WbGuideShortcut(id: 'annotate', label: '透明批注', keys: 'Alt + Shift + A'),
      ],
    ),
  ];

  /// 引导完成页展示的精简快捷键（§3.2 步骤 7）。
  static const List<WbGuideShortcut> highlightShortcuts = <WbGuideShortcut>[
    WbGuideShortcut(id: 'tool.sticky', label: '便签', keys: 'N'),
    WbGuideShortcut(id: 'tool.text', label: '文本', keys: 'T'),
    WbGuideShortcut(
      id: 'edit.undo',
      label: '撤销',
      keys: 'Ctrl/Cmd + Z',
      shortcutId: 'edit.undo',
    ),
    WbGuideShortcut(
      id: 'edit.redo',
      label: '重做',
      keys: 'Ctrl/Cmd + Shift + Z',
      shortcutId: 'edit.redo',
    ),
    WbGuideShortcut(id: 'cmd.palette', label: '命令面板', keys: 'Ctrl/Cmd + K'),
    WbGuideShortcut(id: 'ai.panel', label: 'AI 面板', keys: 'Ctrl/Cmd + Shift + A'),
  ];

  /// §4.2 10 个常用操作（帮助中心「快速上手」内嵌表）。
  static const List<WbGuideShortcut> commonOperations = <WbGuideShortcut>[
    WbGuideShortcut(id: 'radial', label: '打开圆盘', keys: '长按画布 / 点击右下角'),
    WbGuideShortcut(id: 'tool.select', label: '选择工具', keys: 'V'),
    WbGuideShortcut(id: 'tool.sticky', label: '便签', keys: 'N'),
    WbGuideShortcut(id: 'tool.text', label: '文本', keys: 'T'),
    WbGuideShortcut(id: 'tool.shape', label: '形状', keys: 'R'),
    WbGuideShortcut(id: 'tool.connector', label: '连线', keys: 'L'),
    WbGuideShortcut(id: 'tool.pen', label: '画笔', keys: 'P'),
    WbGuideShortcut(
      id: 'edit.undo',
      label: '撤销',
      keys: 'Ctrl/Cmd + Z',
      shortcutId: 'edit.undo',
    ),
    WbGuideShortcut(
      id: 'edit.redo',
      label: '重做',
      keys: 'Ctrl/Cmd + Shift + Z',
      shortcutId: 'edit.redo',
    ),
    WbGuideShortcut(id: 'ai.panel', label: '打开 AI', keys: 'Ctrl/Cmd + Shift + A'),
    WbGuideShortcut(id: 'pages', label: '页面管理', keys: 'Ctrl/Cmd + P'),
    WbGuideShortcut(id: 'cmd.palette', label: '命令面板', keys: 'Ctrl/Cmd + K'),
  ];

  // ---------------------------------------------------------------------
  // §5.1 用户手册结构
  // ---------------------------------------------------------------------

  /// 用户手册章节（10 章，条目对齐 §5.1）。
  static const List<WbManualChapter> manualChapters = <WbManualChapter>[
    WbManualChapter(
      title: '01 入门',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 安装与启动', summary: '安装应用、首次启动与硬件要求。'),
        WbManualTopic(title: '02 界面概览', summary: '画布、左侧栏、圆盘与工具栏布局。'),
        WbManualTopic(title: '03 圆盘工具栏', summary: '圆盘工具的选择与自定义。'),
        WbManualTopic(title: '04 左侧栏', summary: '页面、AI、协作与菜单入口。'),
        WbManualTopic(title: '05 页面管理', summary: '新建、重命名与切换页面。'),
        WbManualTopic(title: '06 快捷键', summary: '常用快捷键与自定义键位。'),
      ],
    ),
    WbManualChapter(
      title: '02 基础功能',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 便签', summary: '创建、编辑与批量整理便签。'),
        WbManualTopic(title: '02 文本', summary: '文本框的创建与富文本编辑。'),
        WbManualTopic(title: '03 形状', summary: '绘制形状并调整样式。'),
        WbManualTopic(title: '04 连线', summary: '连接元素、调整箭头与折线。'),
        WbManualTopic(title: '05 图片', summary: '导入图片与文档。'),
        WbManualTopic(title: '06 画笔', summary: '手绘与荧光笔。'),
        WbManualTopic(title: '07 Frame', summary: '用 Frame 组织区域与场景。'),
        WbManualTopic(title: '08 图层', summary: '调整层级与锁定。'),
      ],
    ),
    WbManualChapter(
      title: '03 进阶功能',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 思维导图', summary: '快速构建与整理导图。'),
        WbManualTopic(title: '02 表格', summary: '表格编辑与公式。'),
        WbManualTopic(title: '03 流程图', summary: '流程图创建与自动布局。'),
        WbManualTopic(title: '04 函数渲染', summary: '绘制函数图像。'),
        WbManualTopic(title: '05 3D 渲染', summary: '创建与操作 3D 元素。'),
        WbManualTopic(title: '06 2D 渲染', summary: '矢量图形与数据图表。'),
        WbManualTopic(title: '07 PDF', summary: '打开与标注 PDF。'),
      ],
    ),
    WbManualChapter(
      title: '04 AI 助手',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 打开 AI', summary: 'AI 面板入口与布局。'),
        WbManualTopic(title: '02 文字指令', summary: '用自然语言描述任务。'),
        WbManualTopic(title: '03 语音指令', summary: '按住 Alt + Space 语音输入。'),
        WbManualTopic(title: '04 上下文', summary: '用 @ / # 引用元素与 Frame。'),
        WbManualTopic(title: '05 执行卡片', summary: '查看计划并执行。'),
        WbManualTopic(title: '06 撤销', summary: '回滚 AI 操作。'),
      ],
    ),
    WbManualChapter(
      title: '05 协作',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 分享白板', summary: '生成分享链接。'),
        WbManualTopic(title: '02 权限设置', summary: '查看、编辑与评论权限。'),
        WbManualTopic(title: '03 实时协作', summary: '多人同时编辑。'),
        WbManualTopic(title: '04 评论', summary: '在元素上留言讨论。'),
        WbManualTopic(title: '05 跟随', summary: '跟随他人视角。'),
      ],
    ),
    WbManualChapter(
      title: '06 主题与背景',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 主题切换', summary: '9 个内置主题一键切换。'),
        WbManualTopic(title: '02 背景切换', summary: '预设图案与自定义背景。'),
        WbManualTopic(title: '03 黑板模式', summary: '黑板色调与粉笔风格。'),
        WbManualTopic(title: '04 绿板模式', summary: '绿板色调与笔迹。'),
        WbManualTopic(title: '05 自定义主题', summary: '导入与导出主题包。'),
      ],
    ),
    WbManualChapter(
      title: '07 透明批注',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 返回桌面', summary: '进入桌面批注模式。'),
        WbManualTopic(title: '02 批注态', summary: '直接在桌面上标注。'),
        WbManualTopic(title: '03 穿透态', summary: '点击穿透到桌面应用。'),
        WbManualTopic(title: '04 保存批注', summary: '保存并管理批注内容。'),
      ],
    ),
    WbManualChapter(
      title: '08 导出与分享',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 导出 PNG', summary: '导出整页或选区为图片。'),
        WbManualTopic(title: '02 导出 PDF', summary: '导出为 PDF 文档。'),
        WbManualTopic(title: '03 导出 SVG', summary: '导出矢量格式。'),
        WbManualTopic(title: '04 分享链接', summary: '生成可访问链接。'),
        WbManualTopic(title: '05 嵌入', summary: '通过 iframe 嵌入网页。'),
      ],
    ),
    WbManualChapter(
      title: '09 设置',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 主题', summary: '主题与跟随系统。'),
        WbManualTopic(title: '02 背景', summary: '背景与图案参数。'),
        WbManualTopic(title: '03 快捷键', summary: '查看与检查键位冲突。'),
        WbManualTopic(title: '04 圆盘', summary: '圆盘工具与布局。'),
        WbManualTopic(title: '05 页面', summary: '页面默认行为。'),
        WbManualTopic(title: '06 AI', summary: 'AI 提供商与配额。'),
        WbManualTopic(title: '07 语言', summary: '界面语言切换。'),
        WbManualTopic(title: '08 通知', summary: '通知与提醒。'),
        WbManualTopic(title: '09 账号', summary: '登录与账号管理。'),
      ],
    ),
    WbManualChapter(
      title: '10 故障排查',
      topics: <WbManualTopic>[
        WbManualTopic(title: '01 常见问题', summary: '高频问题速查。'),
        WbManualTopic(title: '02 性能问题', summary: '卡顿与内存排查。'),
        WbManualTopic(title: '03 兼容性问题', summary: '平台与显卡兼容。'),
        WbManualTopic(title: '04 反馈', summary: '提交问题与日志。'),
      ],
    ),
  ];

  // ---------------------------------------------------------------------
  // §6 进阶技巧
  // ---------------------------------------------------------------------

  /// 效率技巧（§6.1）。
  static const List<WbTipEntry> efficiencyTips = <WbTipEntry>[
    WbTipEntry(name: 'Tab 快速创建', detail: '创建下一个便签或节点。'),
    WbTipEntry(name: 'Enter 创建分支', detail: '流程图分支。'),
    WbTipEntry(name: 'Alt 拖拽复制', detail: '复制元素。'),
    WbTipEntry(name: '空格拖拽平移', detail: '平移画布。'),
    WbTipEntry(name: 'Ctrl 滚轮缩放', detail: '缩放画布。'),
    WbTipEntry(name: 'Shift 多选', detail: '多选元素。'),
    WbTipEntry(name: 'Ctrl+D 复制页面', detail: '复制页面。'),
    WbTipEntry(name: 'Ctrl+K 命令面板', detail: '快速执行。'),
    WbTipEntry(name: '@ 引用元素', detail: 'AI 上下文。'),
    WbTipEntry(name: '/ 快捷指令', detail: '命令。'),
  ];

  /// 高级功能（§6.2）。
  static const List<WbTipEntry> advancedFeatures = <WbTipEntry>[
    WbTipEntry(name: '自定义主题', detail: '调整颜色 token，打造个人风格。'),
    WbTipEntry(name: '自定义背景', detail: '预设图案或自定义颜色。'),
    WbTipEntry(name: '多页面', detail: '一个白板组织多个页面。'),
    WbTipEntry(name: '演示模式', detail: '全屏逐页演示。'),
    WbTipEntry(name: '透明批注', detail: '在桌面应用上直接标注。'),
    WbTipEntry(name: '3D 渲染', detail: '创建可旋转的 3D 元素。'),
    WbTipEntry(name: '函数渲染', detail: '绘制函数图像。'),
    WbTipEntry(name: '流程图自动布局', detail: '一键整理流程结构。'),
    WbTipEntry(name: '表格公式', detail: '在表格内直接计算。'),
    WbTipEntry(name: '思维导图布局', detail: '自动整理导图层级。'),
  ];

  /// 集成（§6.3）。
  static const List<WbTipEntry> integrations = <WbTipEntry>[
    WbTipEntry(name: 'Open API', detail: '通过 REST API 读写白板数据。'),
    WbTipEntry(name: 'MCP Server', detail: '让 AI 助手接入白板工具。'),
    WbTipEntry(name: 'Webhook', detail: '事件回调通知。'),
    WbTipEntry(name: 'SDK', detail: '集成到你的应用。'),
    WbTipEntry(name: '嵌入 iframe', detail: '在网页中嵌入白板。'),
  ];

  // ---------------------------------------------------------------------
  // §7 FAQ / 故障排查 / 反馈
  // ---------------------------------------------------------------------

  /// 常见问题（§7.1，15 条）。
  static const List<WbFaqEntry> faq = <WbFaqEntry>[
    WbFaqEntry(
      id: 'create-board',
      question: '如何创建白板？',
      answer: '点击白板列表的「新建」按钮。',
      category: '基础',
    ),
    WbFaqEntry(
      id: 'share-board',
      question: '如何分享白板？',
      answer: '点击左侧栏顶部菜单，选择「分享」。',
      category: '协作',
    ),
    WbFaqEntry(
      id: 'export-board',
      question: '如何导出白板？',
      answer: '点击左侧栏顶部菜单，选择「导出」。',
      category: '导出',
    ),
    WbFaqEntry(
      id: 'switch-theme',
      question: '如何切换主题？',
      answer: '设置 > 主题。',
      category: '主题',
    ),
    WbFaqEntry(
      id: 'switch-background',
      question: '如何切换背景？',
      answer: '设置 > 背景。',
      category: '背景',
    ),
    WbFaqEntry(
      id: 'use-ai',
      question: '如何使用 AI？',
      answer: '点击左侧栏 AI 图标，或按 Ctrl/Cmd + Shift + A。',
      category: 'AI',
    ),
    WbFaqEntry(
      id: 'voice-input',
      question: '如何语音输入？',
      answer: '按住 Alt + Space 说话。',
      category: 'AI',
    ),
    WbFaqEntry(
      id: 'back-to-desktop',
      question: '如何返回桌面批注？',
      answer: '点击左侧栏菜单，选择「返回桌面」。',
      category: '透明批注',
    ),
    WbFaqEntry(
      id: 'undo-ai',
      question: '如何撤销 AI 操作？',
      answer: '在 AI 执行卡片点击「撤销」，或按 Ctrl/Cmd + Z。',
      category: 'AI',
    ),
    WbFaqEntry(
      id: 'create-3d',
      question: '如何创建 3D 元素？',
      answer: '圆盘 > 更多 > 3D 渲染。',
      category: '3D',
    ),
    WbFaqEntry(
      id: 'create-function',
      question: '如何创建函数图？',
      answer: '圆盘 > 更多 > 函数渲染。',
      category: '函数',
    ),
    WbFaqEntry(
      id: 'create-flowchart',
      question: '如何创建流程图？',
      answer: '圆盘 > 更多 > 流程图。',
      category: '流程图',
    ),
    WbFaqEntry(
      id: 'create-mindmap',
      question: '如何创建思维导图？',
      answer: '圆盘 > 更多 > 思维导图。',
      category: '导图',
    ),
    WbFaqEntry(
      id: 'create-table',
      question: '如何创建表格？',
      answer: '圆盘 > 更多 > 表格。',
      category: '表格',
    ),
    WbFaqEntry(
      id: 'open-pdf',
      question: '如何打开 PDF？',
      answer: '圆盘 > 图片/文档 > PDF。',
      category: 'PDF',
    ),
  ];

  /// 故障排查（§7.2，9 条）。
  static const List<WbFaqEntry> troubleshooting = <WbFaqEntry>[
    WbFaqEntry(
      id: 'lag',
      question: '白板卡顿',
      answer: '检查元素数量\n关闭不必要的 3D 元素\n降低渲染质量\n清理缓存',
      category: '故障',
    ),
    WbFaqEntry(
      id: 'open-fail',
      question: '无法打开白板',
      answer: '检查网络\n检查权限\n检查版本\n重启应用',
      category: '故障',
    ),
    WbFaqEntry(
      id: 'ai-no-response',
      question: 'AI 无响应',
      answer: '检查网络\n检查账号\n检查配额\n重试',
      category: '故障',
    ),
    WbFaqEntry(
      id: 'voice-fail',
      question: '语音无法识别',
      answer: '检查麦克风权限\n检查网络\n切换语言\n重试',
      category: '故障',
    ),
    WbFaqEntry(
      id: 'annotation-fail',
      question: '透明批注无法使用',
      answer: '检查系统版本\n检查权限\nLinux Wayland 不支持完整功能',
      category: '故障',
    ),
    WbFaqEntry(
      id: 'render3d-fail',
      question: '3D 渲染异常',
      answer: '检查显卡驱动\n检查 WebGL2 支持\n降级渲染\n重启应用',
      category: '故障',
    ),
    WbFaqEntry(
      id: 'web-fail',
      question: 'Web 端无法加载',
      answer: '检查浏览器版本\n检查网络\n清理缓存\n检查 WASM 支持',
      category: '故障',
    ),
    WbFaqEntry(
      id: 'sync-delay',
      question: '同步延迟',
      answer: '检查网络\n检查服务器状态\n重试',
      category: '故障',
    ),
    WbFaqEntry(
      id: 'export-fail',
      question: '导出失败',
      answer: '检查元素数量\n检查磁盘空间\n重试',
      category: '故障',
    ),
  ];

  /// 反馈渠道（§7.3）。
  static const List<WbTipEntry> feedbackChannels = <WbTipEntry>[
    WbTipEntry(name: '应用内反馈', detail: '帮助 > 反馈。'),
    WbTipEntry(name: '官网反馈', detail: '通过官网反馈表单提交。'),
    WbTipEntry(name: '邮箱', detail: 'support@example.com'),
    WbTipEntry(name: '社区', detail: '论坛提问与讨论。'),
  ];

  /// 反馈需附信息（§7.3）。
  static const List<WbTipEntry> feedbackChecklist = <WbTipEntry>[
    WbTipEntry(name: '问题描述', detail: '发生了什么，期望是什么。'),
    WbTipEntry(name: '复现步骤', detail: '按顺序列出操作步骤。'),
    WbTipEntry(name: '截图', detail: '附上问题截图。'),
    WbTipEntry(name: '日志', detail: '导出最近日志。'),
    WbTipEntry(name: '版本', detail: '应用版本号。'),
    WbTipEntry(name: '平台', detail: '操作系统与设备信息。'),
  ];

  /// 反馈响应时间（§7.3）。
  static const List<WbTipEntry> feedbackResponseTimes = <WbTipEntry>[
    WbTipEntry(name: 'P0', detail: '1 小时'),
    WbTipEntry(name: 'P1', detail: '1 天'),
    WbTipEntry(name: 'P2', detail: '3 天'),
    WbTipEntry(name: 'P3', detail: '7 天'),
  ];

  // ---------------------------------------------------------------------
  // 全局搜索
  // ---------------------------------------------------------------------

  /// 跨分节搜索（标题 / 说明包含查询词，大小写不敏感）。
  ///
  /// 空白查询返回空列表；结果顺序为：快速上手 → 快捷键 → 用户手册 →
  /// 进阶技巧 → FAQ → 故障排查。
  static List<WbGuideSearchHit> search(String query) {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return const <WbGuideSearchHit>[];
    }

    bool match(String title, String detail) {
      return title.toLowerCase().contains(q) || detail.toLowerCase().contains(q);
    }

    final List<WbGuideSearchHit> hits = <WbGuideSearchHit>[];
    for (final WbQuickStartStep step in quickStart) {
      if (match(step.title, step.detail)) {
        hits.add(WbGuideSearchHit(
          section: WbGuideSection.quickStart,
          title: step.title,
          detail: step.detail,
        ));
      }
    }
    for (final WbGuideShortcutGroup group in shortcutGroups) {
      for (final WbGuideShortcut shortcut in group.entries) {
        if (match(shortcut.label, shortcut.resolvedKeys)) {
          hits.add(WbGuideSearchHit(
            section: WbGuideSection.quickStart,
            title: '快捷键 · ${shortcut.label}',
            detail: shortcut.resolvedKeys,
          ));
        }
      }
    }
    for (final WbManualChapter chapter in manualChapters) {
      for (final WbManualTopic topic in chapter.topics) {
        if (match(topic.title, topic.summary)) {
          hits.add(WbGuideSearchHit(
            section: WbGuideSection.manual,
            title: '${chapter.title} · ${topic.title}',
            detail: topic.summary,
          ));
        }
      }
    }
    for (final WbTipEntry tip in efficiencyTips) {
      if (match(tip.name, tip.detail)) {
        hits.add(WbGuideSearchHit(
          section: WbGuideSection.advanced,
          title: tip.name,
          detail: tip.detail,
        ));
      }
    }
    for (final WbTipEntry tip in advancedFeatures) {
      if (match(tip.name, tip.detail)) {
        hits.add(WbGuideSearchHit(
          section: WbGuideSection.advanced,
          title: tip.name,
          detail: tip.detail,
        ));
      }
    }
    for (final WbTipEntry tip in integrations) {
      if (match(tip.name, tip.detail)) {
        hits.add(WbGuideSearchHit(
          section: WbGuideSection.advanced,
          title: tip.name,
          detail: tip.detail,
        ));
      }
    }
    for (final WbFaqEntry entry in faq) {
      if (match(entry.question, entry.answer)) {
        hits.add(WbGuideSearchHit(
          section: WbGuideSection.faq,
          title: entry.question,
          detail: entry.answer,
        ));
      }
    }
    for (final WbFaqEntry entry in troubleshooting) {
      if (match(entry.question, entry.answer)) {
        hits.add(WbGuideSearchHit(
          section: WbGuideSection.faq,
          title: entry.question,
          detail: entry.answer,
        ));
      }
    }
    return hits;
  }
}
