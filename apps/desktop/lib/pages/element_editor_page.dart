/// 专业元素独立编辑页（问题 6 / 波次 C）：全屏路由承载六类上下文编辑器。
///
/// 「创建」（快速创建 / 圆盘工具）与「编辑」（双击画布上的专业元素）
/// 共用本页：宿主经 [WbRoutes.elementEditorPath] 以 [WbElementEditorRequest]
/// 作为 `extra` 进入，编辑结果经 `pop(model)` 返回；取消 / 关闭返回 null
/// （宿主不写回）。页内工具栏提供「取消 / 保存」，内容复用
/// [WbQuickCreateKind.buildEditor]。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../widgets/context_editors/context_editor_shell.dart';
import '../widgets/context_editors/quick_create.dart';

/// 元素编辑请求（路由 `extra`；新建时 [elementId] 为 null）。
class WbElementEditorRequest {
  const WbElementEditorRequest({
    required this.kind,
    this.initialModel,
    this.elementId,
  });

  /// 元素类型（决定编辑器与默认模型）。
  final WbQuickCreateKind kind;

  /// 初始模型（编辑既有元素时传入；null 时编辑器使用默认示例模型）。
  final Object? initialModel;

  /// 画布元素 id（编辑既有元素时非空；新建为 null）。
  final String? elementId;

  /// 是否为编辑既有元素（否则为新建）。
  bool get isEditing => elementId != null && elementId!.isNotEmpty;
}

/// 专业元素全屏编辑页（AppBar：取消 / 类型标题 / 保存）。
class ElementEditorPage extends StatefulWidget {
  /// 创建编辑页。
  const ElementEditorPage({super.key, required this.request});

  /// 编辑请求。
  final WbElementEditorRequest request;

  /// 保存按钮 key（测试与集成可读取）。
  static const ValueKey<String> saveKey =
      ValueKey<String>('element-editor-save');

  /// 取消按钮 key。
  static const ValueKey<String> cancelKey =
      ValueKey<String>('element-editor-cancel');

  @override
  State<ElementEditorPage> createState() => _ElementEditorPageState();
}

class _ElementEditorPageState extends State<ElementEditorPage> {
  /// 编辑器上报的最新模型（未做修改时为 null → 保存用初始 / 默认模型）。
  Object? _latest;

  void _cancel() {
    if (mounted) {
      context.pop();
    }
  }

  void _save() {
    final Object model = _latest ??
        widget.request.initialModel ??
        widget.request.kind.defaultModel();
    context.pop(model);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbQuickCreateKind kind = widget.request.kind;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.surface,
        leading: IconButton(
          key: ElementEditorPage.cancelKey,
          tooltip: '取消',
          icon: const Icon(LinearIcons.back),
          onPressed: _cancel,
        ),
        title: Text(
          widget.request.isEditing ? '编辑${kind.label}' : '新建${kind.label}',
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: ElementEditorPage.saveKey,
              onPressed: _save,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      // 全窗工作区编辑器（流程图 / 表格 / 思维导图）直接铺满页面；
      // 其余专业编辑器保持居中面板卡片。
      body: kind.isWorkspace
          ? SizedBox.expand(
              child: kind.buildEditor(
                initialModel: widget.request.initialModel,
                onClose: _cancel,
                onChanged: (Object model) => _latest = model,
              ),
            )
          : Center(
              child: SizedBox(
                width: WbContextMetrics.defaultWidth,
                height: 620,
                child: kind.buildEditor(
                  initialModel: widget.request.initialModel,
                  onClose: _cancel,
                  onChanged: (Object model) => _latest = model,
                ),
              ),
            ),
    );
  }
}
