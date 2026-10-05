/// Web 专业元素编辑器对话框（P5：高级模块入口）。
///
/// 对齐桌面 `ElementEditorPage`（全屏路由）的 Web 形态：go_router 在浏览器
/// 刷新后会丢失 `extra`，故改用 [Dialog.fullscreen] 承载六类上下文编辑器
/// （[WbQuickCreateKind.buildEditor]），不走路由：
/// - AppBar：取消（key `wb-element-editor-cancel`）/ 标题（新建 · 类型 /
///   编辑 · 类型）/ 保存（key `wb-element-editor-save`）；
/// - 流程图 / 表格 / 思维导图为全窗工作区布局，其余为居中面板
///   （宽 [WbContextMetrics.defaultWidth] / 高 620，对齐桌面视觉）；
/// - 保存返回 `_latest ?? initialModel ?? kind.defaultModel()`；取消返回
///   null（宿主不写回）；`barrierDismissible: false`（仅按钮出口）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_canvas/context_editors/context_editor_shell.dart';
import 'package:whiteboard_canvas/context_editors/quick_create.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

/// 打开专业元素编辑器对话框。
///
/// 返回编辑器保存的模型（未修改时为 [initialModel] / 默认示例模型）；
/// 取消 / 页面销毁时返回 null。
Future<Object?> showWbElementEditorDialog(
  BuildContext context, {
  required WbQuickCreateKind kind,
  Object? initialModel,
  String? elementId,
}) {
  return showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) => _WbElementEditorDialog(
      kind: kind,
      initialModel: initialModel,
      elementId: elementId,
    ),
  );
}

/// 编辑器对话框（状态承载「最新模型」捕获）。
class _WbElementEditorDialog extends StatefulWidget {
  const _WbElementEditorDialog({
    required this.kind,
    this.initialModel,
    this.elementId,
  });

  /// 元素类型（决定编辑器与默认模型）。
  final WbQuickCreateKind kind;

  /// 初始模型（编辑既有元素时传入）。
  final Object? initialModel;

  /// 画布元素 id（编辑既有元素时非空；新建为 null）。
  final String? elementId;

  @override
  State<_WbElementEditorDialog> createState() => _WbElementEditorDialogState();
}

class _WbElementEditorDialogState extends State<_WbElementEditorDialog> {
  /// 编辑器上报的最新模型（未做修改时为 null → 保存用初始 / 默认模型）。
  Object? _latest;

  /// 是否为编辑既有元素（否则为新建）。
  bool get _isEditing =>
      widget.elementId != null && widget.elementId!.isNotEmpty;

  void _cancel() {
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _save() {
    Navigator.of(context).pop(
      _latest ?? widget.initialModel ?? widget.kind.defaultModel(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbQuickCreateKind kind = widget.kind;
    return Dialog.fullscreen(
      child: Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(
          backgroundColor: colors.surface,
          leading: IconButton(
            key: const ValueKey<String>('wb-element-editor-cancel'),
            tooltip: '取消',
            icon: const Icon(LinearIcons.back),
            onPressed: _cancel,
          ),
          title: Text(_isEditing ? '编辑${kind.label}' : '新建${kind.label}'),
          actions: <Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                key: const ValueKey<String>('wb-element-editor-save'),
                onPressed: _save,
                child: const Text('保存'),
              ),
            ),
          ],
        ),
        // 全窗工作区编辑器（流程图 / 表格 / 思维导图）直接铺满；
        // 其余专业编辑器保持居中面板（对齐桌面尺寸）。
        body: kind.isWorkspace
            ? SizedBox.expand(
                child: kind.buildEditor(
                  initialModel: widget.initialModel,
                  onClose: _cancel,
                  onChanged: (Object model) => _latest = model,
                ),
              )
            : Center(
                child: SizedBox(
                  width: WbContextMetrics.defaultWidth,
                  height: 620,
                  child: kind.buildEditor(
                    initialModel: widget.initialModel,
                    onClose: _cancel,
                    onChanged: (Object model) => _latest = model,
                  ),
                ),
              ),
      ),
    );
  }
}
