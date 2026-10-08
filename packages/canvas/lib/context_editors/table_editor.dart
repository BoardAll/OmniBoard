/// 表格上下文编辑器（Wave 3.6；第三轮问题 2 / 波次 B3：全窗三区工作区）。
///
/// 依据《白板软件设计文档》§6.5「表格工具栏」实现：
/// - **全窗三区**（[WbEditorWorkspace] / [WbEditorPanes]）：左侧行列操作
///   面板（176 宽）、中间最大化网格（双向滚动）、右侧属性面板（240 宽）；
///   标题 / 保存由宿主编辑页 AppBar 承担，本组件不再渲染面板卡片；
/// - **行列编辑**：左面板按钮（作用于选中单元格所在行 / 列，未选中时作用
///   于末行末列并在按钮 tooltip 注明）与悬停把手两套入口。悬停表格左侧
///   边界浮现行把手：在上方插入行 / 在下方插入行 / 删除行；悬停表格上方
///   边界浮现列把手：在左侧插入列 / 在右侧插入列 / 删除列；
/// - **单元格输入**：单击 / 双击单元格进入内联编辑（原位 TextField），输入
///   实时上报，回车或点击输入框外部提交，Esc 取消并恢复编辑前文本；
/// - **样式**：表头加粗 / 表头底色 / 边框 / 斑马纹 / 对齐（左中右）。
///
/// 模型 [WbTableModel] 为不可变值对象，行列定点增删由
/// [WbTableModel.insertRowAt] / [WbTableModel.removeRowAt] /
/// [WbTableModel.insertColumnAt] / [WbTableModel.removeColumnAt] 提供，
/// 删除恒维持至少一行 / 一列；各操作均原样保留样式 [WbTableStyle]。
/// 组件自包含（无 Provider / 主题扩展依赖），通过 [WbTableEditor.onChanged]
/// 上报最新表格。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import 'context_editor_shell.dart';
import 'editor_workspace.dart';

/// 单元格水平对齐。
enum WbTableAlign {
  /// 左对齐。
  left('left', '左对齐', TextAlign.left, Alignment.centerLeft),

  /// 居中。
  center('center', '居中', TextAlign.center, Alignment.center),

  /// 右对齐。
  right('right', '右对齐', TextAlign.right, Alignment.centerRight);

  const WbTableAlign(this.id, this.label, this.textAlign, this.alignment);

  /// 稳定 id。
  final String id;

  /// 中文显示名。
  final String label;

  /// Flutter 文本对齐。
  final TextAlign textAlign;

  /// 容器内对齐。
  final Alignment alignment;
}

/// 表格样式（不可变）。
@immutable
class WbTableStyle {
  /// 创建样式。
  const WbTableStyle({
    this.headerBold = true,
    this.showBorders = true,
    this.zebraStripes = false,
    this.headerBackground = const Color(0xFFEAF1FF),
    this.align = WbTableAlign.left,
  });

  /// 表头是否加粗。
  final bool headerBold;

  /// 是否显示边框。
  final bool showBorders;

  /// 是否显示斑马纹。
  final bool zebraStripes;

  /// 表头底色。
  final Color headerBackground;

  /// 单元格对齐。
  final WbTableAlign align;

  /// 复制并覆盖字段。
  WbTableStyle copyWith({
    bool? headerBold,
    bool? showBorders,
    bool? zebraStripes,
    Color? headerBackground,
    WbTableAlign? align,
  }) {
    return WbTableStyle(
      headerBold: headerBold ?? this.headerBold,
      showBorders: showBorders ?? this.showBorders,
      zebraStripes: zebraStripes ?? this.zebraStripes,
      headerBackground: headerBackground ?? this.headerBackground,
      align: align ?? this.align,
    );
  }
}

/// 表格模型（不可变；行列以 `List<List<String>>` 表示）。
@immutable
class WbTableModel {
  /// 创建模型。
  const WbTableModel({
    this.cells = const <List<String>>[],
    this.style = const WbTableStyle(),
  });

  /// 演示用示例表格（3 列 x 3 行）。
  factory WbTableModel.sample() {
    return const WbTableModel(
      cells: <List<String>>[
        <String>['项目', '负责人', '状态'],
        <String>['需求评审', '张三', '进行中'],
        <String>['开发实现', '李四', '未开始'],
      ],
    );
  }

  /// 单元格数据（行优先）。
  final List<List<String>> cells;

  /// 样式。
  final WbTableStyle style;

  /// 行数。
  int get rowCount => cells.length;

  /// 列数（按最长行计算）。
  int get columnCount {
    int count = 0;
    for (final List<String> row in cells) {
      count = math.max(count, row.length);
    }
    return count;
  }

  /// 读取单元格（越界返回空串）。
  String cellAt(int row, int column) {
    if (row < 0 || row >= cells.length) {
      return '';
    }
    final List<String> values = cells[row];
    if (column < 0 || column >= values.length) {
      return '';
    }
    return values[column];
  }

  /// 复制并覆盖字段。
  WbTableModel copyWith({List<List<String>>? cells, WbTableStyle? style}) {
    return WbTableModel(
      cells: cells ?? this.cells,
      style: style ?? this.style,
    );
  }

  /// 写入单元格（自动补齐到矩形；越界忽略）。
  WbTableModel setCell(int row, int column, String text) {
    if (row < 0 || column < 0) {
      return this;
    }
    final List<List<String>> grid = normalize(cells);
    while (grid.length <= row) {
      grid.add(List<String>.filled(math.max(grid.isEmpty ? 0 : grid.first.length, column + 1), ''));
    }
    final int width = math.max(grid[row].length, column + 1);
    for (final List<String> line in grid) {
      while (line.length < width) {
        line.add('');
      }
    }
    grid[row][column] = text;
    return copyWith(cells: grid);
  }

  /// 追加空行（[values] 不再补齐时按列数填充空串）。
  WbTableModel addRow([List<String>? values]) {
    final List<List<String>> grid = normalize(cells);
    final int width = math.max(columnCount, 1);
    final List<String> row = values == null
        ? List<String>.filled(width, '')
        : List<String>.generate(
            math.max(width, values.length),
            (int i) => i < values.length ? values[i] : '',
          );
    return copyWith(cells: <List<String>>[...grid, row]);
  }

  /// 在 [index] 处插入空行（合法范围 `0..rowCount`；越界返回自身）。
  ///
  /// 新行按当前列数填充空串；空表插入生成 1x1 空表；样式原样保留。
  WbTableModel insertRowAt(int index) {
    if (index < 0 || index > cells.length) {
      return this;
    }
    final List<List<String>> grid = normalize(cells);
    final int width = math.max(columnCount, 1);
    return copyWith(
      cells: <List<String>>[
        ...grid.sublist(0, index),
        List<String>.filled(width, ''),
        ...grid.sublist(index),
      ],
    );
  }

  /// 删除行（保留至少一行；越界忽略）。语义与 [removeRowAt] 一致。
  WbTableModel removeRow(int index) => removeRowAt(index);

  /// 删除 [index] 行（保留至少一行；越界返回自身）。
  WbTableModel removeRowAt(int index) {
    if (index < 0 || index >= cells.length || cells.length <= 1) {
      return this;
    }
    return copyWith(
      cells: <List<String>>[
        for (int i = 0; i < cells.length; i++)
          if (i != index) List<String>.of(cells[i]),
      ],
    );
  }

  /// 追加一列（表头默认「列 N」）。
  WbTableModel addColumn() {
    final List<List<String>> grid = normalize(cells);
    if (grid.isEmpty) {
      return copyWith(cells: <List<String>>[
        <String>['列 1'],
      ]);
    }
    final int width = columnCount;
    return copyWith(
      cells: <List<String>>[
        for (int r = 0; r < grid.length; r++)
          <String>[...grid[r], r == 0 ? '列 ${width + 1}' : ''],
      ],
    );
  }

  /// 在 [index] 处插入空列（合法范围 `0..columnCount`；越界返回自身）。
  ///
  /// 新列在所有行填充空串；空表插入生成 1x1 空表；样式原样保留。
  WbTableModel insertColumnAt(int index) {
    final int width = columnCount;
    if (index < 0 || index > width) {
      return this;
    }
    final List<List<String>> grid = normalize(cells);
    if (grid.isEmpty) {
      return copyWith(cells: <List<String>>[<String>['']]);
    }
    return copyWith(
      cells: <List<String>>[
        for (final List<String> row in grid)
          <String>[
            ...row.sublist(0, index),
            '',
            ...row.sublist(index),
          ],
      ],
    );
  }

  /// 删除列（保留至少一列；越界忽略）。语义与 [removeColumnAt] 一致。
  WbTableModel removeColumn(int index) => removeColumnAt(index);

  /// 删除 [index] 列（保留至少一列；越界返回自身）。
  WbTableModel removeColumnAt(int index) {
    final int width = columnCount;
    if (index < 0 || index >= width || width <= 1) {
      return this;
    }
    return copyWith(
      cells: <List<String>>[
        for (final List<String> row in normalize(cells))
          <String>[
            for (int c = 0; c < row.length; c++)
              if (c != index) row[c],
          ],
      ],
    );
  }

  /// 归一化为矩形（短行补空串）。
  static List<List<String>> normalize(List<List<String>> source) {
    int width = 0;
    for (final List<String> row in source) {
      width = math.max(width, row.length);
    }
    return <List<String>>[
      for (final List<String> row in source)
        <String>[
          for (int c = 0; c < width; c++) c < row.length ? row[c] : '',
        ],
    ];
  }
}

/// 表格上下文编辑器。
class WbTableEditor extends StatefulWidget {
  /// 创建编辑器。
  const WbTableEditor({
    super.key,
    this.initialModel,
    this.onChanged,
    this.onClose,
    this.width = WbContextMetrics.defaultWidth,
  });

  /// 初始模型（null 使用 [WbTableModel.sample]）。
  final WbTableModel? initialModel;

  /// 变更回调。
  final ValueChanged<WbTableModel>? onChanged;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 面板宽度（兼容保留，全窗工作区不再参与布局）。
  final double width;

  @override
  State<WbTableEditor> createState() => _WbTableEditorState();
}

class _WbTableEditorState extends State<WbTableEditor> {
  /// 单元格默认宽 / 高。
  static const double _cellWidth = 112;
  static const double _cellHeight = 34;

  /// 行把手宽度（3 个 18px 按钮 + 间隙与右内边距）。
  static const double _rowHandleWidth = 58;

  /// 列把手高度。
  static const double _columnHandleHeight = 24;

  /// 把手按钮边长 / 图标尺寸。
  static const double _handleButtonSize = 18;
  static const double _handleIconSize = 12;

  /// 把手淡入 / 淡出时长。
  static const Duration _handleFadeDuration = Duration(milliseconds: 120);

  late WbTableModel _model;
  final TextEditingController _cellController = TextEditingController();
  final FocusNode _cellFocus = FocusNode();

  /// 是否处于就地编辑态（单元格内展示 TextField）。
  bool _editing = false;

  /// 进入编辑前的单元格文本（Esc 取消时恢复）。
  String _editSnapshot = '';

  int? _selectedRow;
  int? _selectedColumn;

  /// 悬停行 / 列（把手浮现依据）。
  int? _hoverRow;
  int? _hoverColumn;

  @override
  void initState() {
    super.initState();
    _model = widget.initialModel ?? WbTableModel.sample();
  }

  @override
  void dispose() {
    _cellFocus.dispose();
    _cellController.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged?.call(_model);

  /// 应用样式 / 内容类变更。
  void _apply(WbTableModel next) {
    if (identical(next, _model)) {
      return;
    }
    setState(() => _model = next);
    _emit();
  }

  /// 应用结构性变更（行列增删）：退出编辑并修正越界的选中位置。
  void _applyStructure(WbTableModel next) {
    if (identical(next, _model)) {
      return;
    }
    setState(() {
      _model = next;
      _editing = false;
      _clampSelection();
    });
    _emit();
  }

  /// 选中位置越界时清除（行列增删后调用）。
  void _clampSelection() {
    final int? row = _selectedRow;
    final int? column = _selectedColumn;
    if (row != null && row >= _model.rowCount) {
      _selectedRow = null;
    }
    if (column != null && column >= _model.columnCount) {
      _selectedColumn = null;
    }
  }

  /// 进入单元格就地编辑（单击 / 双击均可；重复点击同一格不重置文本）。
  void _beginEdit(int row, int column) {
    if (_editing && _selectedRow == row && _selectedColumn == column) {
      return;
    }
    setState(() {
      _selectedRow = row;
      _selectedColumn = column;
      _editing = true;
      _editSnapshot = _model.cellAt(row, column);
      _cellController.text = _editSnapshot;
    });
    // 与 TextField.autofocus 双保险：切换单元格后确保新输入框获得焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) {
        _cellFocus.requestFocus();
      }
    });
  }

  /// 编辑内容实时写入模型（保持逐字上报的历史行为）。
  void _editCell(String value) {
    final int? row = _selectedRow;
    final int? column = _selectedColumn;
    if (!_editing || row == null || column == null) {
      return;
    }
    setState(() => _model = _model.setCell(row, column, value));
    _emit();
  }

  /// 提交当前编辑（回车 / 点击输入框外提交并退出编辑态；内容已实时同步）。
  void _commitEdit() {
    if (!_editing) {
      return;
    }
    setState(() => _editing = false);
  }

  /// 取消当前编辑（Esc）：恢复进入编辑前的文本。
  void _cancelEdit() {
    final int? row = _selectedRow;
    final int? column = _selectedColumn;
    if (!_editing || row == null || column == null) {
      return;
    }
    final String snapshot = _editSnapshot;
    setState(() {
      _editing = false;
      _model = _model.setCell(row, column, snapshot);
      _cellController.text = snapshot;
    });
    _emit();
  }

  /// 编辑框键盘事件：Esc 取消编辑（其余按键正常输入）。
  KeyEventResult _handleCellKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelEdit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _setHoverRow(int? row) {
    if (_hoverRow == row) {
      return;
    }
    setState(() => _hoverRow = row);
  }

  void _setHoverColumn(int? column) {
    if (_hoverColumn == column) {
      return;
    }
    setState(() => _hoverColumn = column);
  }

  /// 鼠标离开表格区域时清空悬停态（把手随之淡出）。
  void _clearHover() {
    if (_hoverRow == null && _hoverColumn == null) {
      return;
    }
    setState(() {
      _hoverRow = null;
      _hoverColumn = null;
    });
  }

  int get _rowTarget => _selectedRow ?? (_model.rowCount - 1);

  int get _columnTarget => _selectedColumn ?? (_model.columnCount - 1);

  /// 行操作 tooltip：未选中时注明作用于末行。
  String _rowScopeTip(String action) => _selectedRow == null
      ? '$action（未选中，作用于末行）'
      : '$action（作用于选中行 R${_selectedRow! + 1}）';

  /// 列操作 tooltip：未选中时注明作用于末列。
  String _columnScopeTip(String action) => _selectedColumn == null
      ? '$action（未选中，作用于末列）'
      : '$action（作用于选中列 C${_selectedColumn! + 1}）';

  @override
  Widget build(BuildContext context) {
    return WbEditorWorkspace(
      toolbar: _buildToolbar(context),
      child: WbEditorPanes(
        left: _buildLeftPanel(context),
        center: _buildGridArea(context),
        right: _buildRightPanel(context),
      ),
    );
  }

  /// 左面板：行列操作（作用于选中单元格所在行列；未选中时作用于末行末列）。
  Widget _buildLeftPanel(BuildContext context) {
    final int? row = _selectedRow;
    final int? column = _selectedColumn;
    final String selection = row == null || column == null
        ? '未选中单元格'
        : '已选中 R${row + 1}C${column + 1}';
    return Container(
      key: const ValueKey<String>('wb-ctx-table-left-panel'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            WbEditorSectionTitle(
              title: '行操作',
              trailing: WbEditorHint(row == null ? '末行' : 'R${row + 1}'),
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-table-insert-row-above'),
              icon: LinearIcons.bringForward,
              label: '上方插入行',
              tooltip: _rowScopeTip('在上方插入行'),
              onTap: () => _applyStructure(_model.insertRowAt(_rowTarget)),
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-table-insert-row-below'),
              icon: LinearIcons.sendBackward,
              label: '下方插入行',
              tooltip: _rowScopeTip('在下方插入行'),
              onTap: () => _applyStructure(_model.insertRowAt(_rowTarget + 1)),
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-table-remove-row'),
              icon: LinearIcons.delete,
              label: '删除行',
              tooltip: _rowScopeTip('删除行'),
              enabled: _model.rowCount > 1,
              onTap: () => _applyStructure(_model.removeRowAt(_rowTarget)),
            ),
            const SizedBox(height: 8),
            WbEditorSectionTitle(
              title: '列操作',
              trailing: WbEditorHint(column == null ? '末列' : 'C${column + 1}'),
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-table-insert-col-left'),
              icon: LinearIcons.back,
              label: '左侧插入列',
              tooltip: _columnScopeTip('在左侧插入列'),
              onTap: () =>
                  _applyStructure(_model.insertColumnAt(_columnTarget)),
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-table-insert-col-right'),
              icon: LinearIcons.forward,
              label: '右侧插入列',
              tooltip: _columnScopeTip('在右侧插入列'),
              onTap: () =>
                  _applyStructure(_model.insertColumnAt(_columnTarget + 1)),
            ),
            _panelAction(
              key: const ValueKey<String>('wb-ctx-table-remove-col'),
              icon: LinearIcons.delete,
              label: '删除列',
              tooltip: _columnScopeTip('删除列'),
              enabled: _model.columnCount > 1,
              onTap: () =>
                  _applyStructure(_model.removeColumnAt(_columnTarget)),
            ),
            const SizedBox(height: 10),
            Text(
              '${_model.rowCount} 行 × ${_model.columnCount} 列 · $selection',
              style: WbTypography.caption.copyWith(
                color: context.wbColors.icon.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 4),
            const WbEditorHint(
              '提示：单击 / 双击单元格即可就地编辑；悬停网格行 / 列把手亦可'
              '插入、删除行列。',
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

  /// 中间：最大化网格（双向滚动 + 悬停行列把手 + 单元格就地编辑）。
  Widget _buildGridArea(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Container(
        key: const ValueKey<String>('wb-ctx-table-grid-area'),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
          border: Border.all(color: colors.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Container(
          key: const ValueKey<String>('wb-ctx-table-grid'),
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _buildGrid(context),
            ),
          ),
        ),
      ),
    );
  }

  /// 右面板：属性（选中单元格信息 / 表头底色；垂直可滚动）。
  Widget _buildRightPanel(BuildContext context) {
    return Container(
      key: const ValueKey<String>('wb-ctx-table-right-panel'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: _buildInspector(context),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final WbTableStyle style = _model.style;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-table-add-row'),
          icon: LinearIcons.add,
          tooltip: '添加行（追加末尾）',
          onTap: () => _applyStructure(_model.addRow()),
        ),
        WbEditorIconButton(
          key: const ValueKey<String>('wb-ctx-table-add-col'),
          icon: LinearIcons.distributeHorizontal,
          tooltip: '添加列（追加末尾）',
          onTap: () => _applyStructure(_model.addColumn()),
        ),
        for (final WbTableAlign align in WbTableAlign.values)
          WbEditorChip(
            key: ValueKey<String>('wb-ctx-table-align-${align.id}'),
            label: align.label,
            dense: true,
            selected: style.align == align,
            onTap: () => _apply(_model.copyWith(style: style.copyWith(align: align))),
          ),
        WbEditorChip(
          key: const ValueKey<String>('wb-ctx-table-borders'),
          label: '边框',
          icon: LinearIcons.borderStyle,
          dense: true,
          selected: style.showBorders,
          onTap: () => _apply(
            _model.copyWith(style: style.copyWith(showBorders: !style.showBorders)),
          ),
        ),
        WbEditorChip(
          key: const ValueKey<String>('wb-ctx-table-zebra'),
          label: '斑马纹',
          dense: true,
          selected: style.zebraStripes,
          onTap: () => _apply(
            _model.copyWith(
              style: style.copyWith(zebraStripes: !style.zebraStripes),
            ),
          ),
        ),
        WbEditorChip(
          key: const ValueKey<String>('wb-ctx-table-header-bold'),
          label: '表头加粗',
          dense: true,
          selected: style.headerBold,
          onTap: () => _apply(
            _model.copyWith(style: style.copyWith(headerBold: !style.headerBold)),
          ),
        ),
      ],
    );
  }

  /// 网格：列把手行（表格上方）+ 每行（行把手 + 单元格）。
  Widget _buildGrid(BuildContext context) {
    final List<List<String>> grid = WbTableModel.normalize(_model.cells);
    final int columns = grid.isEmpty ? 0 : grid.first.length;
    return MouseRegion(
      onExit: (_) => _clearHover(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildColumnHandleRow(context, columns),
          for (int r = 0; r < grid.length; r++) _buildRow(context, r, grid[r]),
        ],
      ),
    );
  }

  /// 列把手行：悬停某列上方边界时浮现「左侧插入 / 右侧插入 / 删除」。
  Widget _buildColumnHandleRow(BuildContext context, int columns) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 左上角占位：与行把手同宽，保证列把手与单元格对齐。
        const SizedBox(width: _rowHandleWidth, height: _columnHandleHeight),
        for (int c = 0; c < columns; c++)
          MouseRegion(
            onEnter: (_) => _setHoverColumn(c),
            onExit: (_) {
              if (_hoverColumn == c) {
                _setHoverColumn(null);
              }
            },
            child: SizedBox(
              width: _cellWidth,
              height: _columnHandleHeight,
              child: _buildColumnHandles(context, c, columns),
            ),
          ),
      ],
    );
  }

  Widget _buildColumnHandles(BuildContext context, int column, int columns) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 2),
        child: AnimatedOpacity(
          opacity: _hoverColumn == column ? 1 : 0,
          duration: _handleFadeDuration,
          child: _buildHandleGroup(<Widget>[
            _handleButton(
              key: ValueKey<String>('wb-ctx-table-col-insert-left-$column'),
              icon: LinearIcons.back,
              tooltip: '在左侧插入列',
              onTap: () => _applyStructure(_model.insertColumnAt(column)),
            ),
            _handleButton(
              key: ValueKey<String>('wb-ctx-table-col-insert-right-$column'),
              icon: LinearIcons.forward,
              tooltip: '在右侧插入列',
              onTap: () => _applyStructure(_model.insertColumnAt(column + 1)),
            ),
            _handleButton(
              key: ValueKey<String>('wb-ctx-table-col-remove-$column'),
              icon: LinearIcons.delete,
              tooltip: '删除该列',
              enabled: columns > 1,
              onTap: () => _applyStructure(_model.removeColumnAt(column)),
            ),
          ]),
        ),
      ),
    );
  }

  /// 单元格行：整行悬停时行把手浮现「上方插入 / 下方插入 / 删除」。
  Widget _buildRow(BuildContext context, int row, List<String> values) {
    return MouseRegion(
      onEnter: (_) => _setHoverRow(row),
      onExit: (_) {
        if (_hoverRow == row) {
          _setHoverRow(null);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: _rowHandleWidth,
            height: _cellHeight,
            child: _buildRowHandles(context, row),
          ),
          for (int c = 0; c < values.length; c++)
            _buildCell(context, row, c, values[c]),
        ],
      ),
    );
  }

  Widget _buildRowHandles(BuildContext context, int row) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: AnimatedOpacity(
          opacity: _hoverRow == row ? 1 : 0,
          duration: _handleFadeDuration,
          child: _buildHandleGroup(<Widget>[
            _handleButton(
              key: ValueKey<String>('wb-ctx-table-row-insert-above-$row'),
              icon: LinearIcons.bringForward,
              tooltip: '在上方插入行',
              onTap: () => _applyStructure(_model.insertRowAt(row)),
            ),
            _handleButton(
              key: ValueKey<String>('wb-ctx-table-row-insert-below-$row'),
              icon: LinearIcons.sendBackward,
              tooltip: '在下方插入行',
              onTap: () => _applyStructure(_model.insertRowAt(row + 1)),
            ),
            _handleButton(
              key: ValueKey<String>('wb-ctx-table-row-remove-$row'),
              icon: LinearIcons.delete,
              tooltip: '删除该行',
              enabled: _model.rowCount > 1,
              onTap: () => _applyStructure(_model.removeRowAt(row)),
            ),
          ]),
        ),
      ),
    );
  }

  /// 把手按钮组（横向排列，1px 间隙）。
  Widget _buildHandleGroup(List<Widget> buttons) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < buttons.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 1),
          buttons[i],
        ],
      ],
    );
  }

  /// 紧凑的把手图标按钮。
  Widget _handleButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return WbEditorIconButton(
      key: key,
      icon: icon,
      tooltip: tooltip,
      enabled: enabled,
      size: _handleButtonSize,
      iconSize: _handleIconSize,
      onTap: onTap,
    );
  }

  Widget _buildCell(BuildContext context, int row, int column, String text) {
    final WbThemeColors colors = context.wbColors;
    final WbTableStyle style = _model.style;
    final bool header = row == 0;
    final bool selected = _selectedRow == row && _selectedColumn == column;
    final bool editing = selected && _editing;
    Color background = header ? style.headerBackground : colors.surface;
    if (!header && style.zebraStripes && row.isOdd) {
      background = colors.canvas.withValues(alpha: 0.7);
    }
    if (_hoverRow == row) {
      // 悬停行轻微底色提示（与把手呼应）。
      background = Color.lerp(background, colors.primary, 0.08) ?? background;
    }
    final TextStyle textStyle = WbTypography.body.copyWith(
      fontSize: 12,
      color: colors.icon,
      fontWeight: header && style.headerBold ? FontWeight.w600 : FontWeight.w400,
    );
    final Widget content = editing
        ? Focus(
            onKeyEvent: _handleCellKeyEvent,
            child: TextField(
              key: const ValueKey<String>('wb-ctx-table-cell-edit'),
              controller: _cellController,
              focusNode: _cellFocus,
              autofocus: true,
              style: textStyle,
              textAlign: style.align.textAlign,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                hintText: '输入内容',
                hintStyle:
                    textStyle.copyWith(color: colors.icon.withValues(alpha: 0.35)),
              ),
              onChanged: _editCell,
              onSubmitted: (_) => _commitEdit(),
              onTapOutside: (_) => _commitEdit(),
            ),
          )
        : Text(
            text,
            textAlign: style.align.textAlign,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          );
    return MouseRegion(
      // 悬停单元格时同步显示所在行 / 列的把手。
      onEnter: (_) {
        _setHoverRow(row);
        _setHoverColumn(column);
      },
      child: InkWell(
        key: ValueKey<String>('wb-ctx-table-cell-$row-$column'),
        onTap: () => _beginEdit(row, column),
        child: Container(
          width: _cellWidth,
          height: _cellHeight,
          alignment: style.align.alignment,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: selected ? colors.primary.withValues(alpha: 0.08) : background,
            border: style.showBorders
                ? Border(
                    right: BorderSide(color: colors.cardBorder),
                    bottom: BorderSide(color: colors.cardBorder),
                  )
                : null,
          ),
          child: content,
        ),
      ),
    );
  }

  /// 右面板内容（竖排）：选中单元格信息 + 表头底色色板。
  Widget _buildInspector(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final int? row = _selectedRow;
    final int? column = _selectedColumn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        WbEditorSectionTitle(
          title: '单元格',
          trailing: row == null || column == null
              ? null
              : WbEditorHint('R${row + 1}C${column + 1}'),
        ),
        if (row == null || column == null)
          const WbEditorHint(
            '单击或双击单元格即可就地编辑（回车 / 点击外部提交，Esc 取消）。'
            '行列结构可在左侧面板或网格把手处调整。',
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: colors.canvas.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(WbContextMetrics.controlRadius),
            ),
            child: Text(
              _model.cellAt(row, column).isEmpty
                  ? '（空单元格）'
                  : _model.cellAt(row, column),
              style: WbTypography.body.copyWith(fontSize: 12, color: colors.icon),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(height: 12),
        const WbEditorSectionTitle(title: '外观'),
        const WbEditorHint('表头底色：'),
        const SizedBox(height: 6),
        WbEditorColorRow(
          colors: WbContextPalette.swatches,
          selected: _model.style.headerBackground,
          keyPrefix: 'wb-ctx-table-header-color',
          swatchSize: 16,
          onSelect: (Color color) => _apply(
            _model.copyWith(
              style: _model.style.copyWith(
                headerBackground: color.withValues(alpha: 0.24),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
