/// 专业元素独立编辑页（问题 6 / 波次 C）：全屏路由承载六类上下文编辑器。
///
/// 「创建」（快速创建 / 圆盘工具）与「编辑」（双击画布上的专业元素）
/// 共用本页：宿主经 [WbRoutes.elementEditorPath] 以 [WbElementEditorRequest]
/// 作为 `extra` 进入，编辑结果经 `pop(model)` 返回；取消 / 关闭返回 null
/// （宿主不写回）。页内工具栏提供「取消 / 保存」，内容复用
/// [WbQuickCreateKind.buildEditor]。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_windows/whiteboard_windows.dart';

import '../services/settings_store.dart';
import '../widgets/context_editors/context_editor_shell.dart';
import '../widgets/context_editors/flowchart_editor.dart';
import '../widgets/context_editors/quick_create.dart';

/// 元素编辑请求（路由 `extra`；新建时 [elementId] 为 null）。
class WbElementEditorRequest {
  const WbElementEditorRequest({
    required this.kind,
    this.initialModel,
    this.elementId,
    this.onLiveChanged,
  });

  /// 元素类型（决定编辑器与默认模型）。
  final WbQuickCreateKind kind;

  /// 初始模型（编辑既有元素时传入；null 时编辑器使用默认示例模型）。
  final Object? initialModel;

  /// 画布元素 id（编辑既有元素时非空；新建为 null）。
  final String? elementId;

  /// 实时回写回调（可选）：编辑器每次上报（如 Markdown debounce 300ms）
  /// 即回调一次，宿主可据此即时写回画布 payload；null 时不启用
  /// （仅保存时经 `pop(model)` 一次性回写）。
  final ValueChanged<Object>? onLiveChanged;

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

  /// 构建编辑器：流程图经 [WbDesktopFlowLibraryStore] 持久化图形库偏好，
  /// 并接入 Windows 原生对话框作为「我的组件」导入源（其余类型忽略）。
  Widget _buildEditor(BuildContext context, WbQuickCreateKind kind) {
    final WbSettingsStore? settings = context.read<WbSettingsStore?>();
    return kind.buildEditor(
      initialModel: widget.request.initialModel,
      onClose: _cancel,
      onChanged: (Object model) {
        _latest = model;
        widget.request.onLiveChanged?.call(model);
      },
      libraryStore:
          settings == null ? null : WbDesktopFlowLibraryStore(settings),
      componentImporter: _importComponent,
    );
  }

  /// 组件导入源：Windows 原生「选择组件」对话框（SVG / 图片）。
  ///
  /// 返回文件名 + 字节；用户取消 / 原生未注册（测试环境）/ 读文件
  /// 失败返回 null。归一化（判型 / 限量 / 重编码）由编辑器统一处理。
  Future<WbFlowComponentAsset?> _importComponent() async {
    final String? path = await WindowsWindowPlugin().openComponentFile();
    if (path == null || path.isEmpty) {
      return null;
    }
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      return WbFlowComponentAsset(name: _baseName(path), bytes: bytes);
    } on FileSystemException {
      return null;
    }
  }

  /// 路径末段（无 path 依赖的手写 basename；兼容两种分隔符）。
  static String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

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
              child: _buildEditor(context, kind),
            )
          : Center(
              child: SizedBox(
                width: WbContextMetrics.defaultWidth,
                height: 620,
                child: _buildEditor(context, kind),
              ),
            ),
    );
  }
}

/// 桌面图形库偏好存储：桥接 [WbSettingsStore]（settings.json `flowLibrary` 键）。
class WbDesktopFlowLibraryStore implements WbFlowLibraryStore {
  /// 创建适配器。
  const WbDesktopFlowLibraryStore(this.settings);

  /// 设置存储（Provider 下发；未挂载 Provider 时不注入本适配器）。
  final WbSettingsStore settings;

  @override
  WbFlowLibraryPrefs? read() => settings.flowLibrary;

  @override
  void write(WbFlowLibraryPrefs prefs) => settings.flowLibrary = prefs;
}
