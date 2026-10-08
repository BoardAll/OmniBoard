/// 白板编辑页：画布 + 左侧栏 + AI 面板 + 径向/浮动工具栏。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';
import 'package:whiteboard_windows/whiteboard_windows.dart';

import '../platform/desktop_backdrop_controller.dart';
import '../platform/transparent_overlay_service.dart';
import '../routes.dart';
import '../services/ai_canvas_executor.dart';
import '../services/board_file_service.dart';
import '../services/ffi_service.dart';
import '../services/sync_service.dart';
import '../services/theme_service.dart';
import '../state/ai_state.dart';
import '../state/annotation_state.dart';
import '../state/board_state.dart';
import '../state/page_state.dart';
import '../state/selection_state.dart';
import '../state/theme_state.dart';
import '../widgets/ai_panel.dart';
import '../widgets/annotation/annotation_controller.dart';
import '../widgets/annotation/annotation_layer.dart';
import '../widgets/canvas/canvas_controller.dart';
import '../widgets/canvas/canvas_model.dart';
import '../widgets/canvas/element_size_dialog.dart';
import '../widgets/canvas/professional_painter.dart';
import '../widgets/canvas_view.dart';
import '../widgets/command_palette.dart';
import '../widgets/context_editors/quick_create.dart';
import '../widgets/floating_toolbar.dart';
import '../widgets/guide/help_center.dart';
import '../widgets/guide/onboarding_overlay.dart';
import '../widgets/guide/shortcut_card_dialog.dart';
import '../widgets/radial/radial_models.dart';
import '../widgets/radial/radial_popup.dart';
import '../widgets/radial/radial_tool_mapping.dart';
import '../widgets/radial_toolbar.dart';
import '../widgets/sidebar.dart';
import '../widgets/toolbar/toolbar_config.dart';
import '../widgets/unsaved_changes_dialog.dart';
import 'element_editor_page.dart';

/// 白板编辑页。
class BoardEditPage extends StatefulWidget {
  const BoardEditPage({
    super.key,
    required this.boardId,
    this.boardName = '',
    this.openFilePath = '',
  });

  /// 白板 id（路由参数）。
  final String boardId;

  /// 白板名称（路由查询参数，可空）。
  final String boardName;

  /// 待打开的本地 `.wbd` 文件路径（列表页入口经路由 extra 传入；空 = 新建）。
  final String openFilePath;

  @override
  State<BoardEditPage> createState() => _BoardEditPageState();
}

class _BoardEditPageState extends State<BoardEditPage> {
  /// 长按空白画布弹出临时圆盘的触发延时（文档 §5.3：300ms）。
  static const Duration _longPressDelay = Duration(milliseconds: 320);

  /// 长按期间允许的指针位移（超过视为拖拽并取消弹出）。
  static const double _longPressSlop = 8;

  /// 画布元素数同步防抖窗口（缩略图「N 元素」角标）。
  static const Duration _elementCountSyncDelay = Duration(milliseconds: 500);

  late final WbBoardState _boardState;
  late final WbPageState _pageState;
  late final WbBoardFileService? _fileService;
  late final WbCanvasController _canvas;
  late final WbAiState _aiState;
  late final WbAiCanvasExecutor _aiExecutor;
  late final WbTransparentOverlayService _overlay;
  late final WbAnnotationController _annotation;
  late final WbDesktopBackdropController _backdrop;
  bool _aiOpen = true;
  bool _paletteOpen = false;

  /// 桌面批注（显示桌面）模式：批注激活时隐藏白板内容，仅保留批注层。
  bool _desktopAnnotation = false;

  Timer? _longPressTimer;
  Offset? _longPressOrigin;
  PointerDownEvent? _longPressEvent;

  /// 元素数同步防抖计时器（画布变更后延迟写入页面状态）。
  Timer? _elementCountTimer;

  /// 圆盘工具栏拖动偏移（相对初始右下位置，已 clamp）。
  Offset _radialOffset = Offset.zero;

  /// 画布区域尺寸（由 [LayoutBuilder] 更新，用于拖动 clamp 与 resize 校正）。
  Size _canvasAreaSize = Size.zero;

  /// 圆盘布局外框边长（`RadialMetrics.frame` 基准值）。
  static const double _radialFrameExtent = 360;

  /// 圆盘初始位置右 / 下边距。
  static const double _radialRightInset = 20;
  static const double _radialBottomInset = 96;

  @override
  void initState() {
    super.initState();
    _boardState = context.read<WbBoardState>();
    _pageState = context.read<WbPageState>();
    // 白板文件服务（可空：未挂载 Provider 时保存 / 打开入口给出轻提示）。
    _fileService = context.read<WbBoardFileService?>();
    _canvas = WbCanvasController(
      selection: context.read<WbSelectionState>(),
      // 图片工具：系统文件选择对话框（问题 2）。
      imagePicker: _pickImageFile,
      // 双击专业元素 → 独立编辑页（问题 6）。
      onElementActivate: _onElementActivate,
      // 尺寸角标点击 → 尺寸设置对话框（波次 C：3D / 2D 宽高可调整）。
      onSizeBadgeTap: _onSizeBadgeTap,
    );
    _canvas.addListener(_onCanvasChanged);
    // AI 工具调用 → 画布落地执行器：面板执行卡片「执行」真正编辑白板
    // （element_create / element_update / element_move / element_delete）。
    _aiState = context.read<WbAiState>();
    _aiExecutor = WbAiCanvasExecutor(canvas: _canvas);
    _aiState.bindExecutor(_aiExecutor);
    _overlay = WbTransparentOverlayService();
    _annotation = WbAnnotationController(
      overlay: _overlay,
      ffi: context.read<WbFfiService>(),
    );
    // 显示桌面兜底：原生真透明失败时以虚拟屏截图垫底（问题 5）。
    _backdrop = WbDesktopBackdropController();
    _backdrop.addListener(_onBackdropChanged);
    _annotation.addListener(_onAnnotationChanged);
    HardwareKeyboard.instance.addHandler(_onGlobalKeyEvent);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(_openBoard()));
  }

  @override
  void dispose() {
    // 仅解绑自己注入的执行器（新页面可能已抢先绑定）。
    if (identical(_aiState.executor, _aiExecutor)) {
      _aiState.bindExecutor(null);
    }
    HardwareKeyboard.instance.removeHandler(_onGlobalKeyEvent);
    _longPressTimer?.cancel();
    _elementCountTimer?.cancel();
    _annotation.removeListener(_onAnnotationChanged);
    _annotation.dispose();
    _backdrop.removeListener(_onBackdropChanged);
    _backdrop.dispose();
    _overlay.dispose();
    _fileService?.unbind();
    _canvas.removeListener(_onCanvasChanged);
    _canvas.dispose();
    super.dispose();
  }

  /// 初始化白板：有 [BoardEditPage.openFilePath] 时打开本地文件，
  /// 否则走新建流程；完成后把文件服务绑定到三源（干净基线）。
  Future<void> _openBoard() async {
    if (!mounted) {
      return;
    }
    final WbBoardFileService? files = _fileService;
    if (widget.openFilePath.isNotEmpty && files != null) {
      // 先绑定（干净基线），openPath 成功后自行更新 filePath 并清脏。
      files.bindBoard(board: _boardState, pages: _pageState, canvas: _canvas);
      final WbOpenOutcome outcome = await files.openPath(widget.openFilePath);
      if (!mounted) {
        return;
      }
      if (outcome.isOpened) {
        _snack('已打开：${files.fileDisplayName}');
        return;
      }
      if (outcome.status == WbOpenStatus.failed) {
        _snack(outcome.message);
      }
      // 打开失败：回退为空白新板（走下方新建流程，页面仍可用）。
    }
    _boardState.open(widget.boardId, name: widget.boardName);
    final WbBoard? board = _boardState.board;
    if (board != null) {
      _pageState.attach(board);
    }
    // 新建流程在加载完成后绑定：初始化通知不误标脏。
    _fileService?.bindBoard(
        board: _boardState, pages: _pageState, canvas: _canvas);
  }

  /// 返回列表：有未保存改动先走三选询问（保存成功 / 不保存才离开）。
  Future<void> _leave() async {
    if (!await _confirmUnsaved()) {
      return;
    }
    if (!mounted) {
      return;
    }
    context.read<WbSelectionState>().clear();
    context.pop();
  }

  /// 图片工具文件选择：Windows 原生模态对话框（未打包 / 测试环境返回 null）。
  Future<String?> _pickImageFile() => WindowsWindowPlugin().openImageFile();

  // ---- 本地文件：保存 / 打开（白板数据持久化） ------------------------------

  /// 保存白板到本地 `.wbd`（首存 / 另存为弹对话框；结果均有提示）。
  Future<void> _saveBoard({bool saveAs = false}) async {
    final WbBoardFileService? files = _fileService;
    if (files == null || !files.isBound) {
      _snack('保存不可用（文件服务未挂载）');
      return;
    }
    final WbSaveOutcome outcome = await files.save(saveAs: saveAs);
    if (!mounted) {
      return;
    }
    switch (outcome.status) {
      case WbSaveStatus.saved:
        _snack('已保存：${outcome.message}');
      case WbSaveStatus.cancelled:
        break;
      case WbSaveStatus.failed:
        _snack(outcome.message);
    }
  }

  /// 打开本地白板：有未保存改动先询问；随后弹文件对话框并载入。
  Future<void> _openLocalBoard() async {
    final WbBoardFileService? files = _fileService;
    if (files == null || !files.isBound) {
      _snack('打开不可用（文件服务未挂载）');
      return;
    }
    if (!await _confirmUnsaved()) {
      return;
    }
    final WbOpenOutcome outcome = await files.openWithDialog();
    if (!mounted) {
      return;
    }
    if (outcome.isOpened) {
      _snack('已打开：${files.fileDisplayName}');
    } else if (outcome.status == WbOpenStatus.failed) {
      _snack(outcome.message);
    }
  }

  /// 未保存改动三选确认；返回 false = 取消（含保存被取消 / 失败）。
  Future<bool> _confirmUnsaved() async {
    final WbBoardFileService? files = _fileService;
    if (files == null || !files.hasUnsavedChanges) {
      return true;
    }
    if (!mounted) {
      return false;
    }
    final WbUnsavedChoice choice = await showUnsavedChangesDialog(
      context,
      boardName: _boardState.board?.name ?? '',
    );
    if (!mounted || choice == WbUnsavedChoice.cancel) {
      return false;
    }
    if (choice == WbUnsavedChoice.save) {
      final WbSaveOutcome outcome = await files.save();
      if (!mounted) {
        return false;
      }
      if (!outcome.isSaved) {
        if (outcome.status == WbSaveStatus.failed) {
          _snack(outcome.message);
        }
        return false;
      }
    }
    return true;
  }

  /// 画布变更：元素数量防抖同步到页面状态（缩略图「N 元素」角标与画布同源）。
  void _onCanvasChanged() {
    _elementCountTimer?.cancel();
    _elementCountTimer = Timer(_elementCountSyncDelay, () {
      if (!mounted) {
        return;
      }
      _pageState.setElementCount(_canvas.pageId, _canvas.elements.length);
    });
  }

  // ---- 桌面批注（显示桌面）模式（问题 7 / C2） -----------------------------

  /// 批注模式开关联动：进入时白板内容整体让位（窗口已由覆盖层服务透明
  /// 全屏置顶），退出时恢复主界面；同时同步桌面截图兜底背景。
  void _onAnnotationChanged() {
    final bool active = _annotation.isActive;
    _syncBackdrop();
    if (!mounted || active == _desktopAnnotation) {
      return;
    }
    setState(() => _desktopAnnotation = active);
  }

  /// 同步桌面截图兜底：原生真透明失败时以虚拟屏截图垫底（防黑屏）。
  void _syncBackdrop() {
    _backdrop.sync(
      annotationActive: _annotation.isActive,
      transparentApplied: _overlay.isTransparentApplied,
      penetrating: _annotation.isPenetratingInEffect,
    );
  }

  /// 兜底背景就绪 / 释放：批注模式内刷新即可。
  void _onBackdropChanged() {
    if (mounted && _desktopAnnotation) {
      setState(() {});
    }
  }

  /// 桌面批注布局：仅叠批注组合层 + 所选风格工具栏（圆盘风格时保留圆盘，
  /// 工具映射为批注工具；顶部面板依附画布，画布隐藏时随主界面让位）。
  Widget _buildDesktopAnnotation(bool topToolbar) {
    final ui.Image? desktop = _backdrop.image;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: <Widget>[
          // 兜底背景：原生真透明不可用时以虚拟屏截图垫底（问题 5 防黑屏）。
          if (_backdrop.isActive && desktop != null)
            Positioned.fill(
              child: IgnorePointer(
                child: RawImage(
                  key: const ValueKey<String>('desktop-backdrop-image'),
                  image: desktop,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                ),
              ),
            ),
          if (!topToolbar)
            Positioned(
              right: _radialRightInset,
              bottom: _radialBottomInset,
              child: RadialToolbar(
                onToolSelected: _applyDesktopAnnotationTool,
                onAction: _handleDesktopAnnotationAction,
              ),
            ),
          // 批注组合层：覆盖层画布 + 右上角批注工具条 + 退出弹窗。
          Positioned.fill(child: AnnotationLayer(controller: _annotation)),
        ],
      ),
    );
  }

  /// 桌面批注模式：圆盘工具 id → 批注工具（其余工具给出轻提示）。
  void _applyDesktopAnnotationTool(String toolId) {
    final WbAnnotationTool? tool = switch (toolId) {
      'pen' => WbAnnotationTool.pen,
      'highlighter' => WbAnnotationTool.highlighter,
      'eraser' => WbAnnotationTool.eraser,
      'laser' => WbAnnotationTool.laser,
      _ => null,
    };
    if (tool == null) {
      _snack('桌面批注：该工具暂不可用，请使用右上角批注工具条');
      return;
    }
    _annotation.state.selectTool(tool);
    // 选绘图工具即回到批注态（穿透态下无法在桌面绘制）。
    unawaited(_annotation.setPenetrate(false));
  }

  /// 桌面批注模式：AI / 设置等动作入口暂不可用（保持批注层不离开桌面）。
  void _handleDesktopAnnotationAction(String actionId) {
    _snack('桌面批注模式：请先退出（Esc）再使用该功能');
  }

  // ---- 全局快捷键 ---------------------------------------------------------

  /// 命令面板接棒：AI 面板展开时由其内部处理器负责，收起时由本页接管
  /// `Ctrl/Cmd + K`，保证命令面板始终可用；`Ctrl/Cmd + S` 保存与面板无关。
  bool _onGlobalKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) {
      return false;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool ctrlOrCmd = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyS) {
      unawaited(_saveBoard());
      return true;
    }
    if (_aiOpen) {
      return false;
    }
    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyK) {
      unawaited(_openPalette());
      return true;
    }
    return false;
  }

  Future<void> _openPalette() async {
    if (_paletteOpen || !mounted) {
      return;
    }
    _paletteOpen = true;
    try {
      await showCommandPalette(context, onCommand: _runBoardCommand);
    } finally {
      _paletteOpen = false;
    }
  }

  /// 执行命令：与 AI 面板内入口行为一致；prompt 类命令展开面板并转投对话。
  void _runBoardCommand(WbCommand command) {
    final WbAiState ai = context.read<WbAiState>();
    switch (command.builtin) {
      case WbCommandCatalog.builtinReset:
        ai.reset();
        break;
      case WbCommandCatalog.builtinVoice:
        setState(() => _aiOpen = true);
        break;
      case WbCommandCatalog.builtinSettings:
        context.push(WbRoutes.settingsPath);
        break;
      case WbCommandCatalog.builtinHelpCenter:
        unawaited(showHelpCenter(context));
        break;
      case WbCommandCatalog.builtinOnboarding:
        unawaited(showOnboardingOverlay(context));
        break;
      case WbCommandCatalog.builtinShortcuts:
        unawaited(showShortcutCard(context));
        break;
      default:
        break;
    }
    if (command.prompt.isNotEmpty) {
      setState(() => _aiOpen = true);
      unawaited(ai.send(command.prompt));
    }
  }

  // ---- 圆盘工具 / 动作（常驻圆盘与临时圆盘共用） --------------------------

  /// 圆盘 / 底部工具栏工具 id → 画布行为（全量映射见 [WbRadialToolMapping]，
  /// 覆盖 `RadialCatalog` 全部绘图工具；动作工具走 [_handleRadialAction]）。
  void _applyRadialTool(String toolId) {
    final WbRadialToolPlan? plan = WbRadialToolMapping.resolve(toolId);
    if (plan == null) {
      return;
    }
    final WbShapeKind? shapeKind = plan.shapeKind;
    if (shapeKind != null) {
      _canvas.setShapeKind(shapeKind);
    }
    final WbCanvasTool? tool = plan.tool;
    if (tool != null) {
      _canvas.setTool(tool);
    }
    if (plan.pasteClipboard) {
      _canvas.pasteClipboard();
    }
    final WbQuickCreateKind? editorKind = plan.editorKind;
    if (editorKind != null) {
      unawaited(_createProfessionalElement(editorKind));
    }
    final String? hint = plan.hint;
    if (hint != null) {
      _snack(hint);
    }
  }

  /// 圆盘动作：AI 助手展开面板；设置走路由；`more` 菜单由组件内部处理。
  void _handleRadialAction(String actionId) {
    switch (actionId) {
      case kRadialAiAssistantId:
        setState(() => _aiOpen = true);
        break;
      case kRadialSettingsId:
        context.push(WbRoutes.settingsPath);
        break;
      default:
        break;
    }
  }

  // ---- 长按空白画布：临时圆盘（文档 §5.3） --------------------------------

  void _handleCanvasPointerDown(PointerDownEvent event) {
    _cancelLongPress();
    final bool primary = event.buttons & kPrimaryButton != 0;
    if (!primary && event.kind != PointerDeviceKind.touch) {
      return;
    }
    _longPressOrigin = event.position;
    _longPressEvent = event;
    _longPressTimer = Timer(_longPressDelay, _maybePopRadial);
  }

  void _handleCanvasPointerMove(PointerMoveEvent event) {
    final Offset? origin = _longPressOrigin;
    if (origin != null && (event.position - origin).distance > _longPressSlop) {
      _cancelLongPress();
    }
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressEvent = null;
    _longPressOrigin = null;
  }

  /// 长按计时到点：空白处弹圆盘；命中对象或文本编辑中不弹（文档 §5.3）。
  ///
  /// B3：顶部工具面板风格下禁用长按弹盘（圆盘与面板二选一）。
  void _maybePopRadial() {
    final PointerDownEvent? down = _longPressEvent;
    _cancelLongPress();
    if (!mounted || down == null || _canvas.editingElementId != null) {
      return;
    }
    if (context.read<WbThemeState>().appearance.toolbarStyle ==
        WbAppearancePrefs.toolbarStyleTop) {
      return;
    }
    if (_canvas.hitTestElement(_canvas.screenToWorld(down.localPosition)) !=
        null) {
      return;
    }
    // 取消画布内已开始的手势（如画笔起点），避免长按后残留笔迹。
    _canvas.handlePointerCancel(down.pointer);
    unawaited(
      RadialPopup.show(
        context,
        globalPosition: down.position,
        onToolSelected: _applyRadialTool,
        onAction: _handleRadialAction,
      ),
    );
  }

  // ---- 底部 / 上下文工具栏命令（A2：统一出口） --------------------------

  /// 工具栏统一命令分发：结构性命令执行，未实现命令给出轻提示。
  void _handleToolbarCommand(WbToolbarCommand command) {
    switch (command.toolId) {
      case 'element.delete':
        _canvas.deleteSelected();
      case 'element.duplicate':
        _canvas.duplicateSelection();
      case 'element.setColor':
        _applySelectionColor(command.args);
      case 'element.align':
        _canvas.alignSelection(command.args['align'] as String? ?? 'left');
      case 'element.distribute':
        _canvas.distributeSelection(
          command.args['axis'] as String? ?? 'horizontal',
        );
      case 'element.bringToFront':
        _canvas.bringSelectionToFront();
      case 'element.sendToBack':
        _canvas.sendSelectionToBack();
      case 'element.setFontSize':
        _applySelectionFontSize(command.args);
      case 'element.setAlign':
        _canvas.setSelectionTextAlign(
          command.args['value'] as String? ?? 'left',
        );
      case WbToolbarToolIds.settings:
        context.push(WbRoutes.settingsPath);
      case WbToolbarToolIds.shortcuts:
        unawaited(showShortcutCard(context));
      default:
        _snack('「${command.toolId}」即将支持');
    }
  }

  /// 解析 `#AARRGGBB` 颜色参数并应用到选中元素。
  void _applySelectionColor(Map<String, Object?> args) {
    final Object? raw = args['color'];
    if (raw is! String || raw.isEmpty) {
      return;
    }
    final Color color = WbColorUtils.fromHex(raw);
    _canvas.setSelectionColor(color.toARGB32());
  }

  /// 解析字号参数（`size` 数值优先，回落 `value`）并应用到选中文本。
  void _applySelectionFontSize(Map<String, Object?> args) {
    final Object? size = args['size'];
    if (size is num) {
      _canvas.setSelectionFontSize(size.toDouble());
      return;
    }
    final double? parsed = double.tryParse('${args['value']}');
    if (parsed != null) {
      _canvas.setSelectionFontSize(parsed);
    }
  }

  /// 轻提示（未实现命令的反馈出口，避免静默无响应）。
  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  // ---- 圆盘整体拖动（A3：折叠态中心拖动） -------------------------------

  /// 拖动后钳制圆盘偏移：布局外框保持在画布区域内（resize 后同样生效）。
  Offset _clampRadialOffset(Offset offset, Size area) {
    if (area.width <= 0 || area.height <= 0) {
      return offset;
    }
    final double freeX = area.width - _radialRightInset - _radialFrameExtent;
    final double freeY = area.height - _radialBottomInset - _radialFrameExtent;
    final double dxMin = math.min(-freeX, _radialRightInset);
    final double dxMax = math.max(-freeX, _radialRightInset);
    final double dyMin = math.min(-freeY, _radialBottomInset);
    final double dyMax = math.max(-freeY, _radialBottomInset);
    return Offset(
      offset.dx.clamp(dxMin, dxMax),
      offset.dy.clamp(dyMin, dyMax),
    );
  }

  /// 圆盘折叠态拖动回调：累加偏移并钳制。
  void _onRadialMoved(Offset delta) {
    setState(() {
      _radialOffset = _clampRadialOffset(
        _radialOffset + delta,
        _canvasAreaSize,
      );
    });
  }

  // ---- 快速创建（《流程图模块设计》§10） ----------------------------------

  /// 打开独立编辑页创建专业元素（问题 6 / 波次 C）。
  ///
  /// 编辑页「保存」返回模型 → 插入画布视口中心并选中（支持 Ctrl+Z
  /// 撤销）；「取消 / 关闭」返回 null → 不插入。
  Future<void> _createProfessionalElement(WbQuickCreateKind kind) async {
    final Object? model = await context.push<Object>(
      WbRoutes.elementEditorPath(widget.boardId),
      extra: WbElementEditorRequest(kind: kind),
    );
    if (!mounted || model == null) {
      return;
    }
    final Size measured =
        WbProfessionalRenderer.measure(kind.id, model) ?? const Size(320, 240);
    _canvas.insertElement(type: kind.id, size: measured, payload: model);
    // 问题 4：创建完成后回切选择模式。
    _canvas.setTool(WbCanvasTool.select);
    _snack('已插入「${kind.label}」到画布，可拖动调整，Ctrl+Z 撤销');
  }

  /// 双击专业元素 → 独立编辑页（问题 6）：保存后按新模型回写画布。
  Future<void> _onElementActivate(WbCanvasElement element) async {
    final WbQuickCreateKind? kind = WbQuickCreateKind.byId(element.type);
    if (kind == null) {
      return;
    }
    final Object? model = await context.push<Object>(
      WbRoutes.elementEditorPath(widget.boardId),
      extra: WbElementEditorRequest(
        kind: kind,
        initialModel: element.payload,
        elementId: element.id,
      ),
    );
    if (!mounted || model == null) {
      return;
    }
    final Size measured =
        WbProfessionalRenderer.measure(kind.id, model) ?? const Size(320, 240);
    _canvas.updateElement(
      element.id,
      (WbCanvasElement current) => current.copyWith(
        payload: model,
        width: measured.width,
        height: measured.height,
      ),
    );
  }

  /// 点击尺寸角标 → 尺寸设置对话框；确认后按新宽高回写（波次 C）。
  ///
  /// 取消返回 null 时不修改；调整保持元素中心不变并入撤销栈
  /// （[WbCanvasController.resizeElementById] 内处理）。
  Future<void> _onSizeBadgeTap(WbCanvasElement element) async {
    final (double, double)? size = await showElementSizeDialog(
      context,
      width: element.width,
      height: element.height,
    );
    if (!mounted || size == null) {
      return;
    }
    _canvas.resizeElementById(element.id, size.$1, size.$2);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    // B3：工具栏风格二选一（圆盘 / 顶部工具面板）。
    final WbThemeState themeState = context.watch<WbThemeState>();
    final bool topToolbar =
        themeState.appearance.toolbarStyle == WbAppearancePrefs.toolbarStyleTop;
    // C2：显示桌面（透明批注）时白板内容整体让位，仅保留批注组合层。
    if (_desktopAnnotation) {
      return _buildDesktopAnnotation(topToolbar);
    }
    return Scaffold(
      body: Column(
        children: <Widget>[
          MiuixTheme(
            data: MiuixThemeData.of(Theme.of(context).brightness),
            child: _buildTopBar(colors),
          ),
          Expanded(child: _buildBody(topToolbar)),
        ],
      ),
    );
  }

  Widget _action(String tooltip, IconData icon, VoidCallback onPressed) {
    return Tooltip(
      message: tooltip,
      child: MiuixIconButton(
        onPressed: onPressed,
        child: MiuixIcon(icon: icon),
      ),
    );
  }

  Widget _buildTopBar(WbThemeColors colors) {
    return Consumer<WbBoardState>(
      builder: (BuildContext context, WbBoardState state, Widget? child) {
        // 未保存脏标记（文件服务未挂载时不显示）。
        final bool dirty =
            context.watch<WbBoardFileService?>()?.hasUnsavedChanges == true;
        return MiuixSmallTopAppBar(
          title: '${state.board?.name ?? '加载中…'}${dirty ? ' •' : ''}',
          subtitle: state.isDemoMode ? '演示模式 · 核心引擎未加载' : '',
          color: colors.surface,
          // 右侧 7 个操作与标题同层叠放，留白避免长名称压住按钮。
          titlePadding: 340,
          navigationIcon: _action(
            '返回列表',
            LinearIcons.back,
            () => unawaited(_leave()),
          ),
          actions: <Widget>[
            _action(
              '保存白板（Ctrl+S）',
              LinearIcons.save,
              () => unawaited(_saveBoard()),
            ),
            _action(
              '打开本地白板',
              LinearIcons.folder,
              () => unawaited(_openLocalBoard()),
            ),
            const _SyncStatusChip(),
            _action(
              '显示桌面',
              LinearIcons.fitScreen,
              () => unawaited(_annotation.enter()),
            ),
            _action(
              _aiOpen ? '收起 AI 面板' : '展开 AI 面板',
              _aiOpen ? LinearIcons.close : LinearIcons.ai,
              () => setState(() => _aiOpen = !_aiOpen),
            ),
            _action(
              '帮助中心',
              LinearIcons.info,
              () => unawaited(showHelpCenter(context)),
            ),
            _action(
              '设置',
              LinearIcons.settings,
              () => context.push(WbRoutes.settingsPath),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBody(bool topToolbar) {
    return Row(
      children: <Widget>[
        SizedBox(width: 240, child: Sidebar(canvasController: _canvas)),
        const VerticalDivider(width: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              _canvasAreaSize = constraints.biggest;
              final Offset radialOffset = _clampRadialOffset(
                _radialOffset,
                constraints.biggest,
              );
              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: Listener(
                      onPointerDown: _handleCanvasPointerDown,
                      onPointerMove: _handleCanvasPointerMove,
                      onPointerUp: (PointerUpEvent _) => _cancelLongPress(),
                      onPointerCancel: (PointerCancelEvent _) =>
                          _cancelLongPress(),
                      child: CanvasView(
                        controller: _canvas,
                        showToolPalette: topToolbar,
                        onQuickCreate: (WbQuickCreateKind kind) =>
                            unawaited(_createProfessionalElement(kind)),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 16,
                    child: Center(
                      child: ListenableBuilder(
                        listenable: _canvas,
                        builder: (BuildContext context, Widget? child) {
                          return FloatingToolbar(
                            // 受控高亮：与画布工具同步（含创建完成 / 圆盘切换
                            // 回选择等程序化切换）。
                            activeTool: _canvas.tool.id,
                            onToolChanged: _applyRadialTool,
                            onCommand: _handleToolbarCommand,
                            onUndo: _canvas.undo,
                            onRedo: _canvas.redo,
                            penColor: Color(
                              _canvas.tool == WbCanvasTool.highlighter
                                  ? _canvas.highlightColor
                                  : _canvas.penColor,
                            ),
                            penColorLabel:
                                _canvas.tool == WbCanvasTool.highlighter
                                    ? '荧光笔颜色'
                                    : '画笔颜色',
                            penStyle: _canvas.penStyle,
                            onPenStyleChanged: _canvas.setPenStyle,
                            onPenColorChanged: (Color color) {
                              if (_canvas.tool == WbCanvasTool.highlighter) {
                                _canvas.setHighlightColor(color.toARGB32());
                              } else {
                                _canvas.setPenColor(color.toARGB32());
                              }
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  if (!topToolbar)
                    Positioned(
                      left: constraints.maxWidth -
                          _radialRightInset -
                          _radialFrameExtent +
                          radialOffset.dx,
                      top: constraints.maxHeight -
                          _radialBottomInset -
                          _radialFrameExtent +
                          radialOffset.dy,
                      child: RadialToolbar(
                        onToolSelected: _applyRadialTool,
                        onAction: _handleRadialAction,
                        onMoved: _onRadialMoved,
                      ),
                    ),
                  Positioned(
                    left: 16,
                    bottom: 16,
                    child: WbQuickCreateLauncher(
                      alignment: Alignment.bottomLeft,
                      margin: EdgeInsets.zero,
                      onCreate: (WbQuickCreateKind kind) =>
                          unawaited(_createProfessionalElement(kind)),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (_aiOpen) ...<Widget>[
          const VerticalDivider(width: 1),
          const SizedBox(width: 320, child: AiPanel()),
        ],
      ],
    );
  }
}

/// 同步状态指示 chip。
class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip();

  @override
  Widget build(BuildContext context) {
    final WbSyncService sync = context.watch<WbSyncService>();
    final bool online = sync.isOnline;
    final MiuixThemeData theme = MiuixTheme.of(context);
    final Color muted = theme.colors.onSurfaceVariantSummary;
    return Tooltip(
      message: sync.serverUrl.isEmpty ? '未配置协作服务地址' : sync.serverUrl,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: ShapeDecoration(
          color: theme.colors.surfaceContainer,
          shape: const MiuixSquircleBorder(cornerRadius: 12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MiuixIcon(
              icon: online ? LinearIcons.cloud : LinearIcons.offline,
              size: 16,
              tint: muted,
            ),
            const SizedBox(width: 6),
            MiuixText(
              sync.status.label,
              style: theme.textStyles.footnote1.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
