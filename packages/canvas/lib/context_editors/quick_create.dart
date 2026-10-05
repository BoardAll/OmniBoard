/// 快速创建入口（Wave 3.6）。
///
/// 依据《白板软件设计文档》§6「工具栏」与《流程图模块设计》§10「快速创建」实现：
/// - [WbQuickCreateBar]：五类专业元素（流程图 / 表格 / 思维导图 / 函数图像 /
///   3D 对象）的按钮条，供画布空选中时浮出（挂载时机由宿主决定）；
/// - [WbQuickCreateLauncher]：自包含浮出入口 —— 圆形 `+` 按钮展开 / 收起
///   按钮条，创建时回调 [WbQuickCreateLauncher.onCreate] 并自动收起；
/// - [WbQuickCreateKind.buildEditor]：按类型构建对应上下文编辑器，供宿主
///   统一挂载（插入位置 / 摆放逻辑留给后续集成）。
///
/// 组件自包含（无 Provider / FFI 依赖），可独立挂载于画布之上。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import 'context_editor_shell.dart';
import 'flow_components.dart';
import 'flowchart_editor.dart';
import 'function_editor.dart';
import 'mindmap_editor.dart';
import 'render2d_editor.dart';
import 'render3d_editor.dart';
import 'table_editor.dart';

/// 可快速创建的专业元素类型。
enum WbQuickCreateKind {
  /// 流程图。
  flowchart('flowchart', '流程图', LinearIcons.flowchart),

  /// 表格。
  table('table', '表格', LinearIcons.table),

  /// 思维导图。
  mindmap('mindmap', '思维导图', LinearIcons.mindmap),

  /// 函数图像。
  functionCurve('function', '函数图像', LinearIcons.formula),

  /// 3D 对象。
  render3d('render3d', '3D 对象', LinearIcons.cube),

  /// 2D 图元。
  render2d('render2d', '2D 图元', LinearIcons.shape);

  const WbQuickCreateKind(this.id, this.label, this.icon);

  /// 稳定 id（跨端序列化 / 数据契约用）。
  final String id;

  /// 中文显示名。
  final String label;

  /// 按钮图标（来自 `whiteboard_icons`）。
  final IconData icon;

  /// 是否为全窗工作区编辑器（第三轮问题 2）：流程图 / 表格 / 思维导图
  /// 在独立编辑页中全窗三区显示；函数 / 3D / 2D 保持居中面板。
  bool get isWorkspace => switch (this) {
        WbQuickCreateKind.flowchart ||
        WbQuickCreateKind.table ||
        WbQuickCreateKind.mindmap =>
          true,
        WbQuickCreateKind.functionCurve ||
        WbQuickCreateKind.render3d ||
        WbQuickCreateKind.render2d =>
          false,
      };

  /// 按类型构建对应的上下文编辑器。
  ///
  /// [initialModel] 为编辑既有元素时的初始模型（类型匹配才注入，否则
  /// 编辑器回落默认示例）；[onChanged] 透传编辑器的最新模型（泛化为
  /// [Object]，供宿主捕获后插入 / 回写画布；类型在各类编辑器内保证）；
  /// [onClose] 透传；[libraryStore] / [componentImporter] 仅流程图编辑器
  /// 使用（图形库偏好持久化 / 「我的组件」导入源，其余类型忽略）。
  Widget buildEditor({
    Object? initialModel,
    VoidCallback? onClose,
    ValueChanged<Object>? onChanged,
    WbFlowLibraryStore? libraryStore,
    Future<WbFlowComponentAsset?> Function()? componentImporter,
  }) {
    switch (this) {
      case WbQuickCreateKind.flowchart:
        return WbFlowchartEditor(
          initialModel:
              initialModel is WbFlowchartModel ? initialModel : null,
          onClose: onClose,
          onChanged: (WbFlowchartModel model) => onChanged?.call(model),
          libraryStore: libraryStore,
          componentImporter: componentImporter,
        );
      case WbQuickCreateKind.table:
        return WbTableEditor(
          initialModel: initialModel is WbTableModel ? initialModel : null,
          onClose: onClose,
          onChanged: (WbTableModel model) => onChanged?.call(model),
        );
      case WbQuickCreateKind.mindmap:
        return WbMindmapEditor(
          initialRoot: initialModel is WbMindNode ? initialModel : null,
          onClose: onClose,
          onChanged: (WbMindNode root) => onChanged?.call(root),
        );
      case WbQuickCreateKind.functionCurve:
        return WbFunctionEditor(
          initialScene:
              initialModel is WbFunctionScene ? initialModel : null,
          onClose: onClose,
          onChanged: (WbFunctionScene scene) => onChanged?.call(scene),
        );
      case WbQuickCreateKind.render3d:
        return WbRender3dEditor(
          initialScene: initialModel is Wb3dScene ? initialModel : null,
          onClose: onClose,
          onChanged: (Wb3dScene scene) => onChanged?.call(scene),
        );
      case WbQuickCreateKind.render2d:
        return WbRender2dEditor(
          initialScene:
              initialModel is WbRender2dScene ? initialModel : null,
          onClose: onClose,
          onChanged: (WbRender2dScene scene) => onChanged?.call(scene),
        );
    }
  }

  /// 按稳定 id 反查类型（未知 id 返回 null；用于双击元素打开编辑页）。
  static WbQuickCreateKind? byId(String id) {
    for (final WbQuickCreateKind kind in values) {
      if (kind.id == id) {
        return kind;
      }
    }
    return null;
  }

  /// 各类型的默认（示例）模型。
  ///
  /// 用户在编辑器中未做任何修改就确认时，宿主用它作为插入内容。
  Object defaultModel() {
    switch (this) {
      case WbQuickCreateKind.flowchart:
        return WbFlowchartModel.sample();
      case WbQuickCreateKind.table:
        return WbTableModel.sample();
      case WbQuickCreateKind.mindmap:
        return WbMindNode.sample();
      case WbQuickCreateKind.functionCurve:
        return WbFunctionScene.sample();
      case WbQuickCreateKind.render3d:
        return const Wb3dScene();
      case WbQuickCreateKind.render2d:
        return const WbRender2dScene();
    }
  }
}

/// 快速创建按钮条（五类元素入口）。
class WbQuickCreateBar extends StatelessWidget {
  /// 创建按钮条。
  const WbQuickCreateBar({
    super.key,
    required this.onCreate,
    this.onDismiss,
    this.title = '快速创建',
  });

  /// 创建回调（宿主据此插入元素并挂载编辑器）。
  final ValueChanged<WbQuickCreateKind> onCreate;

  /// 收起回调（null 时不显示收起按钮）。
  final VoidCallback? onDismiss;

  /// 标题文本。
  final String title;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey<String>('wb-ctx-quick-create-bar'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: BorderRadius.circular(WbContextMetrics.panelRadius),
          border: Border.all(color: colors.cardBorder),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                title,
                style: WbTypography.caption.copyWith(
                  color: colors.icon.withValues(alpha: 0.62),
                ),
              ),
            ),
            for (final WbQuickCreateKind kind in WbQuickCreateKind.values)
              _WbQuickCreateButton(
                kind: kind,
                onTap: () => onCreate(kind),
              ),
            if (onDismiss != null) ...<Widget>[
              const SizedBox(width: 2),
              WbEditorIconButton(
                key: const ValueKey<String>('wb-ctx-quick-create-dismiss'),
                icon: LinearIcons.close,
                tooltip: '收起快速创建',
                onTap: onDismiss!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单个快速创建按钮（图标 + 文字竖排）。
class _WbQuickCreateButton extends StatelessWidget {
  const _WbQuickCreateButton({required this.kind, required this.onTap});

  final WbQuickCreateKind kind;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
      child: InkWell(
        key: ValueKey<String>('wb-ctx-quick-create-${kind.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
        hoverColor: colors.cardHover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(kind.icon, size: 18, color: colors.toolbarIcon),
              const SizedBox(height: 4),
              Text(
                kind.label,
                style: WbTypography.caption.copyWith(
                  color: colors.icon,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 画布浮出的快速创建入口（圆形 `+` 展开 / 收起按钮条）。
///
/// 作为自包含覆盖层使用：宿主将其 Stack 在画布之上（建议仅在空选中时显示），
/// [onCreate] 回调触发后按钮条自动收起。
class WbQuickCreateLauncher extends StatefulWidget {
  /// 创建入口。
  const WbQuickCreateLauncher({
    super.key,
    required this.onCreate,
    this.alignment = Alignment.bottomCenter,
    this.margin = const EdgeInsets.all(16),
    this.title = '快速创建',
  });

  /// 创建回调。
  final ValueChanged<WbQuickCreateKind> onCreate;

  /// 入口在父容器内的对齐位置。
  final Alignment alignment;

  /// 入口外边距。
  final EdgeInsets margin;

  /// 按钮条标题。
  final String title;

  @override
  State<WbQuickCreateLauncher> createState() => _WbQuickCreateLauncherState();
}

class _WbQuickCreateLauncherState extends State<WbQuickCreateLauncher> {
  bool _open = false;

  void _toggle() => setState(() => _open = !_open);

  void _handleCreate(WbQuickCreateKind kind) {
    setState(() => _open = false);
    widget.onCreate(kind);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Align(
      alignment: widget.alignment,
      child: Padding(
        padding: widget.margin,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (_open)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: WbQuickCreateBar(
                    title: widget.title,
                    onCreate: _handleCreate,
                    onDismiss: _toggle,
                  ),
                ),
              ),
            Material(
              color: colors.elevated,
              shape: const CircleBorder(),
              child: InkWell(
                key: const ValueKey<String>('wb-ctx-quick-create-toggle'),
                customBorder: const CircleBorder(),
                onTap: _toggle,
                hoverColor: colors.cardHover,
                child: Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.cardBorder),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x1F000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    _open ? LinearIcons.close : LinearIcons.add,
                    size: 20,
                    color: _open ? colors.primary : colors.toolbarIcon,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
