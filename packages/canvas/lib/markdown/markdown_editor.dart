/// Markdown 上下文编辑器（全屏工作区：源码 + 实时预览）。
///
/// 依据《OmniBoard Markdown 渲染与交互实现方案》§16 / §17：
/// - 左源码（等宽 [TextField]）+ 右实时预览（[WbMarkdownView]），
///   输入 debounce 300ms 后刷新预览并上报 [WbMarkdownEditor.onChanged]
///   （宿主据此回写元素 payload）；
/// - 顶部工具条：类型标识 / 行数·字符数统计 / 源码·预览·双栏切换 / 关闭；
/// - 源码区提供插入工具条（标题 / 粗斜体 / 行内代码 / 链接 / 列表 /
///   引用 / 表格 / 代码块 / 公式 / 图表），作用于当前选区或光标处。
///
/// 组件自包含（无 Provider / FFI 依赖），由宿主以全窗工作区挂载
/// （桌面 `ElementEditorPage` / Web `showWbElementEditorDialog`）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../canvas/canvas_model.dart';
import '../context_editors/context_editor_shell.dart';
import '../context_editors/editor_workspace.dart';
import 'markdown_model.dart';
import 'markdown_theme.dart';
import 'markdown_view.dart';

/// 编辑视图模式（源码 / 预览 / 双栏）。
enum WbMarkdownEditorMode {
  /// 仅源码。
  source('source', '源码', LinearIcons.text),

  /// 仅预览。
  preview('preview', '预览', LinearIcons.visible),

  /// 左源码 + 右预览（默认）。
  split('split', '双栏', LinearIcons.grid);

  const WbMarkdownEditorMode(this.id, this.label, this.icon);

  /// 稳定 id（测试 / 宿主引用）。
  final String id;

  /// 中文显示名。
  final String label;

  /// 模式图标。
  final IconData icon;
}

/// Markdown 编辑器（全屏工作区）。
class WbMarkdownEditor extends StatefulWidget {
  /// 创建编辑器。
  const WbMarkdownEditor({
    super.key,
    this.initialModel,
    this.onChanged,
    this.onClose,
    this.theme = WbMarkdownTheme.light,
  });

  /// 初始模型（null 使用 [WbMarkdownModel.sample]）。
  final WbMarkdownModel? initialModel;

  /// 变更回调（debounce 后上报最新模型，宿主回写 payload）。
  final ValueChanged<WbMarkdownModel>? onChanged;

  /// 关闭回调（null 时不显示关闭按钮）。
  final VoidCallback? onClose;

  /// 预览渲染主题。
  final WbMarkdownTheme theme;

  /// 预览刷新防抖间隔（方案 §16：300ms）。
  static const Duration debounce = Duration(milliseconds: 300);

  /// 源码字号（等宽字体）。
  static const double sourceFontSize = 13.5;

  /// 预览最大宽度（阅读舒适列宽）。
  static const double previewMaxWidth = 760;

  @override
  State<WbMarkdownEditor> createState() => _WbMarkdownEditorState();
}

class _WbMarkdownEditorState extends State<WbMarkdownEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  final WbCanvasTextCache _textCache = WbCanvasTextCache();

  late final bool _autoHeight = widget.initialModel?.autoHeight ?? false;

  Timer? _debounceTimer;

  /// 已上报 / 已渲染的源码（用于「最后一次编辑来不及 debounce 就退出」
  /// 的兜底补发）。
  String _emittedSource = '';

  /// 预览显示的源码（debounce 后才跟上输入）。
  String _previewSource = '';

  WbMarkdownEditorMode _mode = WbMarkdownEditorMode.split;

  late final List<_WbMdInsertAction> _insertActions = <_WbMdInsertAction>[
    _WbMdInsertAction('title', '标题', () => _toggleLinePrefix('# ')),
    _WbMdInsertAction('bold', '粗体', () => _wrapSelection('**', '**', '粗体')),
    _WbMdInsertAction('italic', '斜体', () => _wrapSelection('*', '*', '斜体')),
    _WbMdInsertAction(
      'strike',
      '删除线',
      () => _wrapSelection('~~', '~~', '删除线'),
    ),
    _WbMdInsertAction('code', '行内代码', () => _wrapSelection('`', '`', 'code')),
    _WbMdInsertAction(
      'link',
      '链接',
      () => _wrapSelection('[', '](https://)', '链接文本'),
    ),
    _WbMdInsertAction('list', '列表', () => _toggleLinePrefix('- ')),
    _WbMdInsertAction('quote', '引用', () => _toggleLinePrefix('> ')),
    _WbMdInsertAction(
      'table',
      '表格',
      () => _insertBlock('| 列 A | 列 B |\n| --- | --- |\n| 单元格 | 单元格 |'),
    ),
    _WbMdInsertAction(
      'codeblock',
      '代码块',
      () => _insertBlock('```dart\n// code\n```'),
    ),
    _WbMdInsertAction(
      'math',
      '公式',
      () => _insertBlock('\$\$\nE = mc^2\n\$\$'),
    ),
    _WbMdInsertAction(
      'mermaid',
      '图表',
      () => _insertBlock(
        '```mermaid\nflowchart TD\n    A[开始] --> B{判断}\n    B -->|是| C[结束]\n```',
      ),
    ),
  ];

  @override
  void initState() {
    super.initState();
    final WbMarkdownModel model =
        widget.initialModel ?? WbMarkdownModel.sample();
    _controller = TextEditingController(text: model.source);
    _previewSource = model.source;
    _emittedSource = model.source;
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    final String pending = _controller.text;
    final ValueChanged<WbMarkdownModel>? onChanged = widget.onChanged;
    if (onChanged != null && pending != _emittedSource) {
      // 最后一次编辑来不及走 debounce：帧后安全补发（dispose 期间直接
      // 回调可能触发宿主在 build 期 setState）。
      final WbMarkdownModel model =
          WbMarkdownModel(source: pending, autoHeight: _autoHeight);
      SchedulerBinding.instance.addPostFrameCallback((_) => onChanged(model));
    }
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ---- 变更管线 ----------------------------------------------------------

  /// 输入变更：统计即时刷新，预览与上报走 debounce。
  void _handleInput(String text) {
    setState(() {});
    _debounceTimer?.cancel();
    _debounceTimer = Timer(WbMarkdownEditor.debounce, () {
      if (!mounted) {
        return;
      }
      _previewSource = text;
      _emittedSource = text;
      setState(() {});
      widget.onChanged?.call(
        WbMarkdownModel(source: text, autoHeight: _autoHeight),
      );
    });
  }

  /// 立即提交未上报的编辑（关闭 / 插入等离散操作）。
  void _flushNow() {
    _debounceTimer?.cancel();
    final String text = _controller.text;
    if (text == _emittedSource) {
      return;
    }
    _previewSource = text;
    _emittedSource = text;
    widget.onChanged?.call(
      WbMarkdownModel(source: text, autoHeight: _autoHeight),
    );
  }

  void _handleClose() {
    _flushNow();
    widget.onClose?.call();
  }

  /// 应用源码与选区（插入类操作即时刷新预览并上报，不走 debounce）。
  void _applySource(String text, TextSelection selection) {
    _controller.value = TextEditingValue(text: text, selection: selection);
    _previewSource = text;
    _emittedSource = text;
    setState(() {});
    _focusNode.requestFocus();
    widget.onChanged?.call(
      WbMarkdownModel(source: text, autoHeight: _autoHeight),
    );
  }

  // ---- 插入操作 ----------------------------------------------------------

  int _lineStart(String text, int offset) {
    final int index = text.lastIndexOf('\n', offset > 0 ? offset - 1 : 0);
    return index < 0 ? 0 : index + 1;
  }

  int _lineEnd(String text, int offset) {
    final int index = text.indexOf('\n', offset);
    return index < 0 ? text.length : index;
  }

  /// 在选区两侧包裹标记；无选区时插入占位文本并选中占位。
  void _wrapSelection(String prefix, String suffix, String placeholder) {
    final String src = _controller.text;
    final TextSelection sel = _controller.selection;
    int start = sel.isValid ? sel.start : src.length;
    int end = sel.isValid ? sel.end : src.length;
    if (end < start) {
      final int swap = start;
      start = end;
      end = swap;
    }
    final String selected = src.substring(start, end);
    final String body = selected.isEmpty ? placeholder : selected;
    final String next = src.replaceRange(start, end, '$prefix$body$suffix');
    _applySource(
      next,
      TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + body.length,
      ),
    );
  }

  /// 行首前缀切换（多行选中时逐行处理；已全部带前缀时移除）。
  void _toggleLinePrefix(String prefix) {
    final String src = _controller.text;
    final TextSelection sel = _controller.selection;
    final int start = sel.isValid ? sel.start : 0;
    final int end = sel.isValid ? sel.end : src.length;
    final int lineStart = _lineStart(src, start);
    final int lineEnd = _lineEnd(src, end);
    final List<String> lines = src.substring(lineStart, lineEnd).split('\n');
    final bool allPrefixed = lines.every(
      (String line) => line.trimLeft().isEmpty || line.startsWith(prefix),
    );
    final String body = lines
        .map((String line) {
          if (line.trimLeft().isEmpty) {
            return line;
          }
          return allPrefixed ? line.substring(prefix.length) : '$prefix$line';
        })
        .join('\n');
    _applySource(
      src.replaceRange(lineStart, lineEnd, body),
      TextSelection.collapsed(offset: lineStart + body.length),
    );
  }

  /// 插入块级片段（表格 / 代码块 / 公式 / 图表），必要时补换行分隔。
  void _insertBlock(String snippet) {
    final String src = _controller.text;
    final TextSelection sel = _controller.selection;
    int start = sel.isValid ? sel.start : src.length;
    int end = sel.isValid ? sel.end : src.length;
    if (end < start) {
      final int swap = start;
      start = end;
      end = swap;
    }
    final bool needsLeading = start > 0 && src[start - 1] != '\n';
    final bool needsTrailing = end < src.length && src[end] != '\n';
    final String insertion =
        '${needsLeading ? '\n' : ''}$snippet${needsTrailing ? '\n' : ''}';
    final String next = src.replaceRange(start, end, insertion);
    _applySource(
      next,
      TextSelection.collapsed(offset: start + insertion.length),
    );
  }

  // ---- 构建 --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return WbEditorWorkspace(
      key: const ValueKey<String>('wb-md-editor'),
      toolbar: _buildToolbar(colors),
      child: switch (_mode) {
        WbMarkdownEditorMode.source => _buildSourcePane(colors),
        WbMarkdownEditorMode.preview => _buildPreviewPane(colors),
        WbMarkdownEditorMode.split => Row(
            children: <Widget>[
              Expanded(child: _buildSourcePane(colors)),
              VerticalDivider(width: 1, thickness: 1, color: colors.cardBorder),
              Expanded(child: _buildPreviewPane(colors)),
            ],
          ),
      },
    );
  }

  /// 顶部工具条：标识 / 统计 / 模式切换 / 关闭。
  Widget _buildToolbar(WbThemeColors colors) {
    final String source = _controller.text;
    final int lines = source.isEmpty ? 1 : '\n'.allMatches(source).length + 1;
    return Row(
      children: <Widget>[
        Icon(LinearIcons.page, size: 18, color: colors.primary),
        const SizedBox(width: 8),
        Text(
          'Markdown',
          style: WbTypography.title.copyWith(color: colors.icon),
        ),
        const SizedBox(width: 12),
        WbEditorHint('$lines 行 · ${source.length} 字符'),
        const Spacer(),
        for (final WbMarkdownEditorMode mode in WbMarkdownEditorMode.values)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: WbEditorChip(
              key: ValueKey<String>('wb-md-editor-mode-${mode.id}'),
              label: mode.label,
              icon: mode.icon,
              selected: _mode == mode,
              dense: true,
              onTap: () => setState(() => _mode = mode),
            ),
          ),
        if (widget.onClose != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: WbEditorIconButton(
              key: const ValueKey<String>('wb-md-editor-close'),
              icon: LinearIcons.close,
              tooltip: '关闭编辑器',
              onTap: _handleClose,
            ),
          ),
      ],
    );
  }

  /// 源码区：插入工具条 + 等宽源码输入框。
  Widget _buildSourcePane(WbThemeColors colors) {
    return Container(
      key: const ValueKey<String>('wb-md-editor-source-pane'),
      color: colors.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final _WbMdInsertAction action in _insertActions)
                  WbEditorChip(
                    key: ValueKey<String>(
                      'wb-md-editor-insert-${action.id}',
                    ),
                    label: action.label,
                    dense: true,
                    onTap: action.onInsert,
                  ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: colors.cardBorder),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: TextField(
                key: const ValueKey<String>('wb-md-editor-source'),
                controller: _controller,
                focusNode: _focusNode,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                cursorColor: colors.primary,
                style: TextStyle(
                  fontFamily: WbMarkdownTheme.monoFontFallback.first,
                  fontFamilyFallback: WbMarkdownTheme.monoFontFallback,
                  fontSize: WbMarkdownEditor.sourceFontSize,
                  height: 1.5,
                  color: colors.icon,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '# 输入 Markdown 源码…',
                  hintStyle: WbTypography.body.copyWith(
                    color: colors.icon.withValues(alpha: 0.35),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: _handleInput,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 预览区：实时渲染（debounce 后的 source）。
  Widget _buildPreviewPane(WbThemeColors colors) {
    return Container(
      key: const ValueKey<String>('wb-md-editor-preview'),
      color: colors.canvas.withValues(alpha: 0.55),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WbMarkdownEditor.previewMaxWidth,
            ),
            child: WbMarkdownView(
              source: _previewSource,
              theme: widget.theme,
              textCache: _textCache,
              cachePrefix: 'wb-md-editor',
              background: true,
              minHeight: 260,
            ),
          ),
        ),
      ),
    );
  }
}

/// 插入工具条动作（标签 + 行为）。
class _WbMdInsertAction {
  const _WbMdInsertAction(this.id, this.label, this.onInsert);

  /// 稳定 id（key 后缀）。
  final String id;

  /// 中文标签。
  final String label;

  /// 插入行为。
  final VoidCallback onInsert;
}
