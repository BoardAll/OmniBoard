/// Web 专业元素编辑器对话框（P5：高级模块入口）。
///
/// 对齐桌面 `ElementEditorPage`（全屏路由）的 Web 形态：go_router 在浏览器
/// 刷新后会丢失 `extra`，故改用 [Dialog.fullscreen] 承载六类上下文编辑器
/// （[WbQuickCreateKind.buildEditor]），不走路由：
/// - AppBar：取消（key `wb-element-editor-cancel`）/ 标题（新建 · 类型 /
///   编辑 · 类型）/ 保存（key `wb-element-editor-save`）；
/// - 流程图 / 表格 / 思维导图为全窗工作区布局，其余为居中面板
///   （宽 [WbContextMetrics.defaultWidth] / 高 620，对齐桌面视觉）；
/// - 流程图编辑器注入 localStorage 图形库偏好存储
///   （[WbWebFlowLibraryStore]）与「我的组件」二进制导入
///   （`wb_browser_io.dart` 的 `wbPickBinaryFile`）；
/// - 保存返回 `_latest ?? initialModel ?? kind.defaultModel()`；取消返回
///   null（宿主不写回）；`barrierDismissible: false`（仅按钮出口）；
/// - [showWbElementEditorDialog.onLiveChanged] 非空时编辑器每次上报即
///   回调一次（Markdown debounce 300ms 实时回写画布 payload）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:whiteboard_canvas/context_editors/context_editor_shell.dart';
import 'package:whiteboard_canvas/context_editors/flow_components.dart';
import 'package:whiteboard_canvas/context_editors/flowchart_editor.dart';
import 'package:whiteboard_canvas/context_editors/quick_create.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../services/wb_browser_io.dart';

/// 打开专业元素编辑器对话框。
///
/// 返回编辑器保存的模型（未修改时为 [initialModel] / 默认示例模型）；
/// 取消 / 页面销毁时返回 null。
Future<Object?> showWbElementEditorDialog(
  BuildContext context, {
  required WbQuickCreateKind kind,
  Object? initialModel,
  String? elementId,
  ValueChanged<Object>? onLiveChanged,
}) {
  return showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) => _WbElementEditorDialog(
      kind: kind,
      initialModel: initialModel,
      elementId: elementId,
      onLiveChanged: onLiveChanged,
    ),
  );
}

/// 编辑器对话框（状态承载「最新模型」捕获）。
class _WbElementEditorDialog extends StatefulWidget {
  const _WbElementEditorDialog({
    required this.kind,
    this.initialModel,
    this.elementId,
    this.onLiveChanged,
  });

  /// 元素类型（决定编辑器与默认模型）。
  final WbQuickCreateKind kind;

  /// 初始模型（编辑既有元素时传入）。
  final Object? initialModel;

  /// 画布元素 id（编辑既有元素时非空；新建为 null）。
  final String? elementId;

  /// 实时回写回调（可选）：编辑器每次上报即回调（Markdown debounce
  /// 300ms），宿主据此即时写回画布 payload；null 时不启用。
  final ValueChanged<Object>? onLiveChanged;

  @override
  State<_WbElementEditorDialog> createState() => _WbElementEditorDialogState();
}

class _WbElementEditorDialogState extends State<_WbElementEditorDialog> {
  /// 编辑器上报的最新模型（未做修改时为 null → 保存用初始 / 默认模型）。
  Object? _latest;

  /// 图形库偏好存储（localStorage 适配器；非 Web 环境为内存实现）。
  late final WbWebFlowLibraryStore _libraryStore = WbWebFlowLibraryStore();

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

  /// 编辑器上报：记录最新模型并按需实时回写（Markdown 等）。
  void _handleChanged(Object model) {
    _latest = model;
    widget.onLiveChanged?.call(model);
  }

  /// 「我的组件」导入：浏览器文件选择（用户取消返回 null）。
  Future<WbFlowComponentAsset?> _importComponent() async {
    final ({String name, Uint8List bytes})? picked =
        await wbPickBinaryFile();
    if (picked == null) {
      return null;
    }
    return WbFlowComponentAsset(name: picked.name, bytes: picked.bytes);
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
                  onChanged: _handleChanged,
                  libraryStore: _libraryStore,
                  componentImporter: _importComponent,
                ),
              )
            : Center(
                child: SizedBox(
                  width: WbContextMetrics.defaultWidth,
                  height: 620,
                  child: kind.buildEditor(
                    initialModel: widget.initialModel,
                    onClose: _cancel,
                    onChanged: _handleChanged,
                    libraryStore: _libraryStore,
                    componentImporter: _importComponent,
                  ),
                ),
              ),
      ),
    );
  }
}

/// Web 图形库偏好存储（localStorage 适配器）。
///
/// 与桌面 settings.json 适配器对应：经 [createWbCanvasStorage]（Web 编译
/// = localStorage / 桩编译 = 内存）持久化图形库勾选 / 折叠与我的组件。
class WbWebFlowLibraryStore implements WbFlowLibraryStore {
  /// 创建适配器（可注入存储，缺省共享单例）。
  WbWebFlowLibraryStore([WbCanvasStorage? storage])
      : _storage = storage ?? createWbCanvasStorage();

  /// 存档键（与画布存档键隔离）。
  static const String storageKey = 'wb-flow-library';

  final WbCanvasStorage _storage;

  @override
  WbFlowLibraryPrefs? read() {
    final String? raw = _storage.read(storageKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return WbFlowLibraryPrefs.fromJson(
        decoded,
        defaultEnabled: <String>{
          for (final WbFlowShapeLibrary library in WbFlowShapeLibrary.values)
            library.id,
        },
      );
    } catch (_) {
      // 坏存档：视为无偏好（编辑器回落默认全选）。
      return null;
    }
  }

  @override
  void write(WbFlowLibraryPrefs prefs) {
    _storage.write(storageKey, jsonEncode(prefs.toJson()));
  }
}
