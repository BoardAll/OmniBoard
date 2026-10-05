/// 白板编辑页：响应式布局（宽屏左侧栏 + 画布区；窄屏单栏 + 底部工具条）。
///
/// WASM 接线（《Web 端方案设计（Flutter Web + WASM）v1.0》§6.1、§9.4）：
/// 首帧后调用 [WbCoreService.initialize] —— 注入 `wb_core.js`、实例化
/// `wb_core.wasm`；就绪后画布切换为共享 [CanvasView]（选择 / 绘制 /
/// 便签 / 文本 / 形状 / 连线等完整交互，元素经 `WbWasmCanvasStore`
/// 落 `wb_element_*`，并经 `WbPersistentCanvasStore` 写穿浏览器
/// localStorage 自动保存），加载失败 / 产物缺失时降级为内置演示视图
/// （[WbDemoCanvas]）不阻塞 UI，状态见 [WbCoreStatusChip]。
///
/// 工具栏（P3）：宽屏（≥840px）为画布左上角浮动工具面板
/// （`WbCanvasToolPalette`，与桌面「顶部」风格同源：11 工具 +
/// 撤销 / 重做 + 更多菜单 + 工具参数行）；窄屏为 60px 底部工具条
/// （与端上工具行同集：11 工具 + 撤销 / 重做 + 更多，复用共享
/// `WbCanvasIconButton` 三态样式）。
///
/// 页面与图层（P2）：宽屏左侧栏由 [PageManager] + [LayersPanel]（共享包）
/// 承担——页面增删改 / 排序 / 重命名 / 锁定隐藏，图层显示隐藏 / 锁定 /
/// 排序 / 重命名 / 删除；数据经 `WbWasmPageOps` / `WbWasmCanvasEngine`
/// 桥接 WASM 域服务（page / element / render），引擎不可用时面板自身
/// 降级（内存页面 / 演示缓存）。缩略图由引擎 `wb_render_thumbnail` 渲染。
///
/// 持久化与文件互通：画布改动自动保存到 localStorage（键
/// `wb.canvas.<boardId>`；存档按页合并全部页，刷新后经存档恢复页面
/// 列表与各页元素）；AppBar 提供导出 / 导入 `.wbd` 文件入口（整板
/// 粒度），与桌面端同一格式（`whiteboard_canvas` 的
/// `WbBoardFileCodec`），两端文件可直接互相打开。
///
/// 协作层（T1.8 + M3 / T3.4）：默认**本地白板**（不自动连接）；AppBar
/// 互动白板入口（[WbCollabEntryButton]）按需输入房间号加入（两端同房间号
/// 即同步；服务器地址经 `kWbRealtimeEndpoint` 构建期静态注入），在房时
/// 点入口打开房间信息 / 退出（[showWbCollabJoinDialog] /
/// [showWbCollabRoomDialog]，对齐桌面端）；另有演示模式
/// （[WbPresentModeChip]）、举手（[WbRaiseHandButton]）、演示入口
/// （[WbPresentButton]，CoHost+）与参与者入口（[WbParticipantsButton]
/// → endDrawer [WbParticipantsPanel]）。
///
/// `room:removed` 降级：收到后展示只读横幅（[_RemovedBanner]）并禁用本地
/// 编辑入口（宽屏顶部工具面板经 `drawingEnabled` 置灰 / 窄屏底部工具条
/// 仅保留导航工具；互动入口随服务层 `isRemoved` 判定隐藏）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/canvas/canvas_tool_palette.dart';
import 'package:whiteboard_canvas/canvas/element_size_dialog.dart';
import 'package:whiteboard_canvas/canvas/professional_painter.dart';
import 'package:whiteboard_canvas/canvas_view.dart';
import 'package:whiteboard_canvas/collab/remote_cursors.dart';
import 'package:whiteboard_canvas/context_editors/quick_create.dart';
import 'package:whiteboard_canvas/services/board_file_codec.dart';
import 'package:whiteboard_canvas/services/canvas_engine.dart';
import 'package:whiteboard_canvas/state/page_state.dart';
import 'package:whiteboard_canvas/state/selection_state.dart';
import 'package:whiteboard_canvas/toolbar/toolbar_config.dart';
import 'package:whiteboard_canvas/widgets/layers_panel.dart';
import 'package:whiteboard_canvas/widgets/page_manager.dart';
import 'package:whiteboard_core/wb_core_common.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

import '../routes.dart';
import '../services/realtime_service.dart';
import '../services/wb_archive_restore.dart';
import '../services/wb_browser_io.dart';
import '../services/wb_collab_session.dart';
import '../services/wb_core_engine.dart';
import '../services/wb_core_service.dart';
import '../services/wb_persistent_canvas_store.dart';
import '../services/wb_wasm_bridges.dart';
import '../services/wb_wasm_canvas_store.dart';
import '../widgets/collab/collab_dialogs.dart';
import '../widgets/collab/collab_entry_button.dart';
import '../widgets/collab/collab_status_chip.dart';
import '../widgets/collab/participants_button.dart';
import '../widgets/collab/participants_panel.dart';
import '../widgets/collab/present_button.dart';
import '../widgets/collab/raise_hand_button.dart';
import '../widgets/context_toolbar_host.dart';
import '../widgets/core_status_chip.dart';
import '../widgets/demo_canvas.dart';
import '../widgets/element_editor_dialog.dart';

/// 宽屏断点（逻辑像素，Material 布局规范）。
const double kWideBreakpoint = 840;

/// 白板编辑页。
class BoardEditPage extends StatefulWidget {
  /// 创建编辑页。
  const BoardEditPage({
    super.key,
    required this.boardId,
    this.boardName = '',
  });

  /// 白板 id（路由参数）。
  final String boardId;

  /// 白板名称（路由查询参数，可空）。
  final String boardName;

  @override
  State<BoardEditPage> createState() => _BoardEditPageState();
}

class _BoardEditPageState extends State<BoardEditPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 上下文工具栏宿主 key（打开路由级弹层前主动隐藏浮层）。
  final GlobalKey<WbWebContextToolbarHostState> _contextToolbarKey =
      GlobalKey<WbWebContextToolbarHostState>();

  late final WbRealtimeService _realtime;

  /// 页面选区状态（共享画布控制器绑定；随页面释放）。
  final WbSelectionState _selection = WbSelectionState();

  /// 页面管理状态（随页面释放；引擎就绪后经 [WbWasmPageOps] 走引擎）。
  late final WbWasmPageOps _pageOps = WbWasmPageOps();
  late final WbPageState _pages = WbPageState(ops: _pageOps);

  /// 画布引擎桥（缩略图 / 图层行操作；引擎就绪后绑定 WASM 域服务）。
  final WbWasmCanvasEngine _canvasEngine = WbWasmCanvasEngine();

  /// 侧栏手动刷新信号（页面缩略图 / 图层区共享）。
  final ValueNotifier<int> _refreshSignal = ValueNotifier<int>(0);

  /// 元素数同步防抖（画布变更 → 防抖写回页面状态，供缩略图角标刷新）。
  static const Duration _elementCountSyncDelay = Duration(milliseconds: 500);
  Timer? _elementCountTimer;

  /// 当前画布工具（窄屏底部工具条受控态；宽屏由画布顶部浮动面板
  /// 直接驱动控制器）。
  WbCanvasTool _tool = WbCanvasTool.select;

  /// 共享画布控制器（引擎就绪后创建；引擎可用时携带元素存储）。
  WbCanvasController? _canvas;

  /// 协作会话（P4：加入房间后创建；退出 / 页面释放时销毁）。
  WbCollabSession? _collabSession;

  /// 远端在场状态（P4：光标 / 选区；加入房间后创建，驱动在场层绘制）。
  WbRemotePresenceStore? _presence;

  /// 最近一次已提示的写权拒绝指纹（`code:message`；防同错重复刷屏）。
  String? _lastNotifiedAuthError;

  @override
  void initState() {
    super.initState();
    _realtime = context.read<WbRealtimeService>();
    _realtime.addListener(_syncInteraction);
    // 首帧后按需加载 WASM 核心：失败降级演示画布，不阻塞 UI。
    // （协作默认本地：经 AppBar 互动白板入口按需加入房间。）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_initCore());
    });
  }

  /// 加载 WASM 核心并聚合引擎；就绪后创建共享画布控制器
  /// （存储为 `WbPersistentCanvasStore`：引擎可用时同步 `wb_element_*`
  /// 并写穿 localStorage，否则以纯本地模式运行），并把页面状态
  /// （`WbPageState`）与画布引擎桥（缩略图 / 图层行操作）接到 WASM 域服务。
  ///
  /// 页面与元素从本地存档（`wb.canvas.<boardId>`）恢复：刷新后引擎为
  /// 全新实例，存档是唯一权威来源（存在时按存档页对齐引擎并整板载入
  /// 画布；否则保持引擎默认页）。
  Future<void> _initCore() async {
    final WbCoreService core = context.read<WbCoreService>();
    await core.initialize(boardName: _boardTitle);
    if (!mounted) {
      return;
    }
    if (core.status != WbCoreStatus.ready) {
      // WASM 加载失败：页面区按存档恢复（画布为内置演示视图）。
      _restoreFromArchive();
      return;
    }
    final WbWebEngine? engine = core.engine;
    Map<String, List<WbCanvasElement>>? restoredBoard;
    if (engine == null) {
      // 引擎聚合失败：页面区按存档恢复（与桌面演示模式一致）。
      _restoreFromArchive();
    } else {
      // 接线共享组件：页面状态（PageManager）+ 画布引擎桥
      // （LayersPanel / PageThumbnail 经 Provider 消费，缩略图经
      // wb_render_thumbnail 渲染）。
      _pageOps.attach(engine.page);
      _canvasEngine.attach(element: engine.element, render: engine.render);
      restoredBoard = _restoreFromArchive(engine: engine);
    }
    setState(() {
      _canvas = WbCanvasController(
        store: WbPersistentCanvasStore(
          storage: createWbCanvasStorage(),
          boardId: widget.boardId,
          boardName: _boardTitle,
          engine: engine == null ? null : WbWasmCanvasStore(engine.element),
          pageId: core.pageId,
        ),
        onElementActivate: _onElementActivate,
        onSizeBadgeTap: _onSizeBadgeTap,
      )
        ..setInteractionEnabled(!_realtime.isRemoved)
        ..setTool(_tool)
        ..addListener(_onCanvasChanged)
        // P4 协作装配：本地提交出口 → 会话；远端应用谓词（防回发）；
        // 高频在场预览出口（光标 / 选区；房间内才发送）。
        // M3.1 被跟随广播：有跟随者 / 本端为演示者时外发视口与切页帧。
        ..onLocalCommit = _onLocalCommit
        ..isRemoteApplying = _isRemoteApplying
        ..onCursorMoved = _sendPresencePreview
        ..onSelectionChanged = _sendPresencePreview
        ..onViewportChanged = _onCanvasViewport
        ..onPagePreview = _onCanvasPagePreview;
    });
    if (restoredBoard != null) {
      // 整板载入（存档全部页）+ 定位存档当前页（文档按页隔离）。
      _canvas!
        ..loadBoardData(restoredBoard)
        ..setPage(_pages.currentPageId);
    }
  }

  /// 从本地存档恢复页面状态与画布数据（引擎就绪时对齐引擎页）。
  ///
  /// 存档存在时经 [restoreWbArchive] 把存档页与引擎页对齐（同 id
  /// 复用 / 缺页新建 / 余页删除），页面状态与当前页按存档恢复；无存档
  /// 时保持引擎默认（[WbPageState.attach]）或占位单页。返回整板元素
  /// （供画布 `loadBoardData`；引擎不可用时为 null）。
  Map<String, List<WbCanvasElement>>? _restoreFromArchive({
    WbWebEngine? engine,
  }) {
    final WbBoardData? archive =
        readWbArchive(createWbCanvasStorage(), widget.boardId);
    if (archive == null || archive.pages.isEmpty) {
      if (engine != null) {
        _pages.attach(engine.snapshot);
      } else {
        _pages.restore(boardId: widget.boardId, pages: const <WbPage>[]);
      }
      return null;
    }
    final WbArchiveRestoreResult restored = restoreWbArchive(
      archive: archive,
      ops: _pageOps,
      boardId: widget.boardId,
      enginePages: engine?.snapshot.pages ?? const <WbPage>[],
    );
    _pages.restore(
      boardId: widget.boardId,
      pages: restored.pages,
      currentPageId: restored.currentPageId,
    );
    return engine == null ? null : restored.elementsByPage;
  }

  /// 白板标题（AppBar / 引擎白板名共用）。
  String get _boardTitle =>
      widget.boardName.isEmpty ? '白板 ${widget.boardId}' : widget.boardName;

  /// 同步只读门控（被移出房间 → 画布手势收窄为只读）+ 写权拒绝提示。
  void _syncInteraction() {
    _canvas?.setInteractionEnabled(!_realtime.isRemoved);
    _notifyAuthErrorOnce();
  }

  /// 写权被拒（Forbidden）时轻提示一次（同错误指纹去重，防错误流刷屏）。
  ///
  /// free 默认放开的当下，该路径仅在 present 收窄等场景出现。
  void _notifyAuthErrorOnce() {
    final WbRealtimeError? error = _realtime.lastError;
    if (error == null || error.code != 'Forbidden') {
      return;
    }
    final String fingerprint = '${error.code}:${error.message}';
    if (_lastNotifiedAuthError == fingerprint) {
      return;
    }
    _lastNotifiedAuthError = fingerprint;
    _showSnack('当前角色暂无编辑权限（可向主持人申请授权）');
  }

  // ---- P4 协作会话（画布 op 链路 + 远端在场） ------------------------------

  /// 本地落定提交出口：交会话转 op 上行；不在房间时无副作用。
  void _onLocalCommit(WbCanvasCommitBatch batch) =>
      _collabSession?.handleLocalCommit(batch);

  /// 远端应用谓词（防回发第二层）：会话应用远端 op 期间为 true。
  ///
  /// 命名方法而非 lambda：级联链中 `=> x ?? false` 后的 `..` 会被
  /// Dart 解析吸入 lambda body（级联作用于 bool 字面量），编译失败。
  bool _isRemoteApplying() => _collabSession?.isApplyingRemote ?? false;

  /// 高频在场预览出口：光标 / 选区帧仅在房间内发送。
  void _sendPresencePreview(Map<String, dynamic> frame) {
    if (_realtime.boardId == null) {
      return;
    }
    _realtime.sendPreview(Map<String, Object?>.from(frame));
  }

  /// 画布视口变化出口（200ms 节流；M3.1）：有跟随者或本端为演示者时
  /// 外发 `presence:preview`（viewport 帧）；否则丢弃（应用层决定是否发送）。
  void _onCanvasViewport(Map<String, dynamic> frame) {
    if (_realtime.needsViewportBroadcast) {
      _sendPresencePreview(frame);
    }
  }

  /// 画布切页出口（M3.1）：按需外发 page 帧（跟随者据页序切到同页）；
  /// 无跟随者且非演示者时丢弃。
  void _onCanvasPagePreview(Map<String, dynamic> frame) {
    if (_realtime.needsViewportBroadcast) {
      _sendPresencePreview(frame);
    }
  }

  /// 装配协作会话与远端在场层（加入房间前调用——join 载荷取会话水位）。
  ///
  /// 远端在场层（presence store + onRemotePreviews）与引擎解耦：引擎缺失
  /// （WASM 降级）时仍装配——远端光标 / 选区可见；画布 op 链路（会话）
  /// 仅在引擎就绪时装配。返回 false 表示调用方应中止入房（当前恒不
  /// 触发，保留扩展位）。
  bool _startCollabSession(String room) {
    final WbWebEngine? engine = context.read<WbCoreService>().engine;
    _disposeCollabSession();
    final WbRemotePresenceStore presence = WbRemotePresenceStore();
    _realtime.onRemotePreviews = (List<Object?> previews) {
      presence.handlePreviews(previews, pageId: _canvas?.pageId ?? '');
    };
    if (engine == null) {
      // 引擎缺失：跳过画布 op 链路；在场层仍生效。
      _showSnack('画布引擎未就绪：协作画布同步暂不可用');
      setState(() => _presence = presence);
      return true;
    }
    final WbCollabSession session = WbCollabSession(
      engine: engine,
      realtime: _realtime,
      boardId: room,
    );
    session
      // 远端元素：先确保目标页在本地列表存在（幂等，防「幽灵页」），
      // 再写入对应页文档（对齐桌面装配）。
      ..onRemoteElement = (WbCanvasElement element, {String? pageId}) {
        if (pageId != null && pageId.isNotEmpty) {
          _pages.ensureRemotePage(pageId);
        }
        _canvas?.applyRemoteElement(element, pageId: pageId);
      }
      ..onRemoteRemove = _canvas?.applyRemoteRemove
      ..onRemotePageOp = _pages.applyRemotePageOp
      // 初始自举推送：首个加入者把本地画布已有内容全量上行。
      ..initialContentProvider = _collectLocalBatches
      ..start();
    // 页结构同步装配：本地页变更（新建 / 删除 / 重命名 / 排序）→ `pg:` op
    //（对齐桌面装配；接收侧 onRemotePageOp 已在上方级联接线）。
    _pages.onPageOp = session.handlePageOp;
    setState(() {
      _collabSession = session;
      _presence = presence;
    });
    return true;
  }

  /// 收集本地各页当前元素为提交批（初始自举推送用；空页不产批）。
  ///
  /// 画布未就绪（WASM 降级 / 装配前）时返回空列表。
  List<WbCanvasCommitBatch> _collectLocalBatches() {
    final WbCanvasController? canvas = _canvas;
    if (canvas == null) {
      return const <WbCanvasCommitBatch>[];
    }
    final List<WbCanvasCommitBatch> batches = <WbCanvasCommitBatch>[];
    for (final WbPage page in _pages.pages) {
      final List<WbCanvasElement> elements =
          canvas.document.elementsOf(page.id);
      if (elements.isNotEmpty) {
        batches.add(WbCanvasCommitBatch(pageId: page.id, upserts: elements));
      }
    }
    return batches;
  }

  /// 销毁协作会话与在场层（退出房间 / 页面释放；不触发重建）。
  void _disposeCollabSession() {
    _collabSession?.dispose();
    _collabSession = null;
    // 页结构出口解绑（退房后本地页操作不再外发）。
    _pages.onPageOp = null;
    _realtime.onRemotePreviews = null;
    _presence?.dispose();
    _presence = null;
  }

  /// 画布变更：防抖把当前页元素数写回页面状态（缩略图角标刷新）。
  void _onCanvasChanged() {
    _elementCountTimer?.cancel();
    _elementCountTimer = Timer(_elementCountSyncDelay, () {
      final WbCanvasController? canvas = _canvas;
      if (!mounted || canvas == null) {
        return;
      }
      _pages.setElementCount(canvas.pageId, canvas.elements.length);
    });
  }

  /// 只读守卫提示（被移出房间 / 无编辑权限时面板统一入口）。
  void _notifyReadOnly() {
    _showSnack('你已被移出该白板，当前为只读模式');
  }

  /// 打开路由级弹层（对话框 / 底部菜单）前隐藏上下文浮层。
  ///
  /// 弹层推入期间宿主经路由次级动画自动隐藏（本调用为主动前置，
  /// 消除弹出瞬间的一帧露头）；弹层退出后选区仍在时自动恢复显示。
  void _closeContextToolbar() => _contextToolbarKey.currentState?.close();

  @override
  void dispose() {
    _realtime.removeListener(_syncInteraction);
    _disposeCollabSession();
    _elementCountTimer?.cancel();
    _canvas?.removeListener(_onCanvasChanged);
    _canvas?.dispose();
    _pages.dispose();
    _selection.dispose();
    _refreshSignal.dispose();
    // 退出页面：离开房间（服务端广播 left 并关闭连接，§5.14）。
    // 经微任务延后：dispose 在框架锁定（finalizeTree 卸载阶段）内执行，
    // leave() 的同步状态通知会命中 Provider「markNeedsBuild while
    // tree locked」断言（同会话返回列表用例实测暴露）。
    scheduleMicrotask(() => unawaited(_realtime.leave()));
    super.dispose();
  }

  /// 返回白板列表（go 而非 pop：深链直达时无返回栈可退，且可清理 URL 查询串）。
  void _leave() => context.go(WbWebRoutes.homePath);

  /// 互动白板入口：已在房（含连接失败 / 重连中）→ 房间信息（可退出）；
  /// 否则 → 输入房间号加入（服务器地址为构建期注入的 [kWbRealtimeEndpoint]）。
  Future<void> _openCollabEntry() async {
    // 已在房：房间信息对话框（退出 → 回到本地模式）。
    if (_realtime.boardId != null) {
      _closeContextToolbar();
      final bool leave = await showWbCollabRoomDialog(context) ?? false;
      if (leave && mounted) {
        await _realtime.leave();
        if (mounted) {
          // 退出房间：解绑协作会话与远端在场（本地内容保留）。
          setState(_disposeCollabSession);
          _showSnack('已退出互动白板（回到本地模式）');
        }
      }
      return;
    }
    _closeContextToolbar();
    final String? room = await showWbCollabJoinDialog(
      context,
      serverHint: kWbRealtimeEndpoint,
    );
    if (!mounted || room == null || room.isEmpty) {
      return;
    }
    // 连接（幂等；VM 降级 / 脚本加载失败收敛为 disconnected + lastError）。
    await _realtime.connect(kWbRealtimeEndpoint);
    if (!mounted) {
      return;
    }
    if (_realtime.status == WbRealtimeStatus.disconnected) {
      final String reason = _realtime.lastError?.message ?? '未知错误';
      _showSnack('加入失败：$reason（请检查打包时注入的服务器地址）');
      return;
    }
    // 协作会话先于 joinBoard 装配（join 载荷取本地水印；P4.5）。
    if (!_startCollabSession(room)) {
      return;
    }
    // 未连接时 joinBoard 挂起，连接成功后自动补发 `board:join`。
    unawaited(_realtime.joinBoard(room));
    _showSnack('已加入互动白板：$room');
  }

  void _selectTool(WbCanvasTool tool) {
    setState(() => _tool = tool);
    _canvas?.setTool(tool);
  }

  // ---- 上下文工具栏 / 更多菜单命令（P3：对齐桌面统一出口） -----------------

  /// 工具栏统一命令分发（蓝本 = 桌面 `_handleToolbarCommand`）：
  /// 画布 API 可映射的子集执行，其余命令给出「即将支持」轻提示。
  ///
  /// 只读收窄：被移出房间（[WbRealtimeService.isRemoved]）时仅放行
  /// 设置 / 快捷键（上下文浮层已由宿主 `enabled` 收窄，此处兜底）。
  void _handleToolbarCommand(WbToolbarCommand command) {
    if (_realtime.isRemoved &&
        command.toolId != WbToolbarToolIds.settings &&
        command.toolId != WbToolbarToolIds.shortcuts) {
      _notifyReadOnly();
      return;
    }
    final WbCanvasController? canvas = _canvas;
    if (canvas == null) {
      return;
    }
    switch (command.toolId) {
      case 'element.delete':
        canvas.deleteSelected();
      case 'element.duplicate':
        canvas.duplicateSelection();
      case 'element.setColor':
        _applySelectionColor(command.args);
      case 'element.align':
        canvas.alignSelection(command.args['align'] as String? ?? 'left');
      case 'element.distribute':
        canvas.distributeSelection(
          command.args['axis'] as String? ?? 'horizontal',
        );
      case 'element.bringToFront':
        canvas.bringSelectionToFront();
      case 'element.sendToBack':
        canvas.sendSelectionToBack();
      case 'element.setFontSize':
        _applySelectionFontSize(command.args);
      case 'element.setAlign':
        canvas.setSelectionTextAlign(
          command.args['value'] as String? ?? 'left',
        );
      default:
        // 专业命令（3D / 表格 / 导图 / 连线样式…）与设置 / 快捷键尚未接线。
        _showSnack('「${command.toolId}」即将支持');
    }
  }

  /// 解析 `#AARRGGBB` 颜色参数并应用到选中元素。
  void _applySelectionColor(Map<String, Object?> args) {
    final Object? raw = args['color'];
    if (raw is! String || raw.isEmpty) {
      return;
    }
    final Color color = WbColorUtils.fromHex(raw);
    _canvas?.setSelectionColor(color.toARGB32());
  }

  /// 解析字号参数（`size` 数值优先，回落 `value`）并应用到选中文本。
  void _applySelectionFontSize(Map<String, Object?> args) {
    final Object? size = args['size'];
    if (size is num) {
      _canvas?.setSelectionFontSize(size.toDouble());
      return;
    }
    final double? parsed = double.tryParse('${args['value']}');
    if (parsed != null) {
      _canvas?.setSelectionFontSize(parsed);
    }
  }

  // ---- 专业元素（P5：高级模块入口；蓝本 = 桌面对应方法） -------------------

  /// 打开元素编辑器对话框创建专业元素：保存返回模型 → 按模型测量尺寸并
  /// 插入画布视口中心（支持 Ctrl+Z 撤销）；取消返回 null → 不插入。
  Future<void> _createProfessionalElement(WbQuickCreateKind kind) async {
    if (_realtime.isRemoved) {
      _notifyReadOnly();
      return;
    }
    _closeContextToolbar();
    final Object? model = await showWbElementEditorDialog(context, kind: kind);
    if (!mounted || model == null) {
      return;
    }
    final WbCanvasController? canvas = _canvas;
    if (canvas == null) {
      return;
    }
    final Size measured =
        WbProfessionalRenderer.measure(kind.id, model) ?? const Size(320, 240);
    canvas.insertElement(type: kind.id, size: measured, payload: model);
    // 创建完成后回切选择模式（对齐桌面）。
    _selectTool(WbCanvasTool.select);
    _showSnack('已插入「${kind.label}」到画布，可拖动调整，Ctrl+Z 撤销');
  }

  /// 双击专业元素 → 编辑器对话框：保存后按新模型回写画布（含重新测量）。
  Future<void> _onElementActivate(WbCanvasElement element) async {
    final WbQuickCreateKind? kind = WbQuickCreateKind.byId(element.type);
    if (kind == null || _realtime.isRemoved) {
      return;
    }
    _closeContextToolbar();
    final Object? model = await showWbElementEditorDialog(
      context,
      kind: kind,
      initialModel: element.payload,
      elementId: element.id,
    );
    if (!mounted || model == null) {
      return;
    }
    final WbCanvasController? canvas = _canvas;
    if (canvas == null) {
      return;
    }
    final Size measured =
        WbProfessionalRenderer.measure(kind.id, model) ?? const Size(320, 240);
    canvas.updateElement(
      element.id,
      (WbCanvasElement current) => current.copyWith(
        payload: model,
        width: measured.width,
        height: measured.height,
      ),
    );
  }

  /// 点击尺寸角标 → 尺寸设置对话框；确认后按新宽高回写（取消不修改）。
  Future<void> _onSizeBadgeTap(WbCanvasElement element) async {
    if (_realtime.isRemoved) {
      return;
    }
    _closeContextToolbar();
    final (double, double)? size = await showElementSizeDialog(
      context,
      width: element.width,
      height: element.height,
    );
    if (!mounted || size == null) {
      return;
    }
    _canvas?.resizeElementById(element.id, size.$1, size.$2);
  }

  /// 窄屏底部工具条「更多」入口：底部弹出菜单列六类专业元素创建。
  Future<void> _showMoreCreateMenu() async {
    if (_realtime.isRemoved) {
      _notifyReadOnly();
      return;
    }
    _closeContextToolbar();
    final WbQuickCreateKind? picked =
        await showModalBottomSheet<WbQuickCreateKind>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: WbText('更多 · 创建专业元素', variant: WbTextVariant.label),
            ),
            for (final WbQuickCreateKind kind in WbQuickCreateKind.values)
              ListTile(
                key: ValueKey<String>('wb-bottom-more-${kind.id}'),
                leading: Icon(kind.icon),
                title: Text(kind.label),
                onTap: () => Navigator.of(sheetContext).pop(kind),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    await _createProfessionalElement(picked);
  }

  /// 导出整板为 `.wbd` 文件（浏览器下载；格式与桌面端互通）。
  Future<void> _exportBoard() async {
    final WbCanvasController? canvas = _canvas;
    final WbCoreService core = context.read<WbCoreService>();
    if (canvas == null || core.status != WbCoreStatus.ready) {
      _showSnack('画布未就绪，暂不能导出');
      return;
    }
    try {
      final String pageId = canvas.pageId;
      // 全页导出（与桌面端一致）：页面状态列表逐页取画布文档。
      final List<WbBoardPageData> pages = <WbBoardPageData>[
        for (final WbPage page in _pages.pages)
          WbBoardPageData(
            id: page.id,
            name: page.name,
            locked: page.locked,
            hidden: page.hidden,
            background: page.background.isEmpty ? null : page.background,
            elements: canvas.document.elementsOf(page.id),
          ),
      ];
      if (pages.isEmpty) {
        pages.add(
          WbBoardPageData(
            id: pageId.isEmpty
                ? WbPersistentCanvasStore.fallbackPageId
                : pageId,
            elements: canvas.document.elementsOf(pageId),
          ),
        );
      }
      final String text = WbBoardFileCodec.encode(
        WbBoardData(
          boardId: widget.boardId,
          boardName: _boardTitle,
          currentPageId: pageId.isEmpty ? pages.first.id : pageId,
          pages: pages,
        ),
      );
      await wbDownloadTextFile('$_fileBaseName.wbd', text);
      if (mounted) {
        _showSnack('已导出 $_fileBaseName.wbd');
      }
    } catch (e) {
      if (mounted) {
        _showSnack('导出失败：$e');
      }
    }
  }

  /// 导入 `.wbd` 文件并整板替换（页面列表 + 各页元素；写穿本地存档）。
  Future<void> _importBoard() async {
    final WbCanvasController? canvas = _canvas;
    final WbCoreService core = context.read<WbCoreService>();
    if (canvas == null || core.status != WbCoreStatus.ready) {
      _showSnack('画布未就绪，暂不能导入');
      return;
    }
    final String? text = await wbPickTextFile();
    if (!mounted || text == null) {
      // 用户取消 / 页面已离开。
      return;
    }
    try {
      final WbBoardData data = WbBoardFileCodec.decode(text);
      // 整板替换（与刷新恢复同一路径）：存档页与引擎页对齐，页面状态
      // 与画布整板载入；后续操作写穿本地存档。
      final WbArchiveRestoreResult restored = restoreWbArchive(
        archive: data,
        ops: _pageOps,
        boardId: widget.boardId,
        enginePages: _pages.pages,
      );
      _pages.restore(
        boardId: widget.boardId,
        pages: restored.pages,
        currentPageId: restored.currentPageId,
      );
      canvas.loadBoardData(restored.elementsByPage);
      canvas.setPage(_pages.currentPageId);
      final int elementCount = restored.elementsByPage.values.fold(
        0,
        (int sum, List<WbCanvasElement> list) => sum + list.length,
      );
      _showSnack('已导入 ${restored.pages.length} 个页面、$elementCount 个元素');
    } on FormatException catch (e) {
      _showSnack('导入失败：${e.message}');
    } catch (e) {
      _showSnack('导入失败：$e');
    }
  }

  /// 建议文件名基名（白板名清洗路径非法字符）。
  String get _fileBaseName {
    final String cleaned =
        _boardTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'whiteboard' : cleaned;
  }

  /// 轻提示（SnackBar）。
  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final bool removed = context.watch<WbRealtimeService>().isRemoved;
    // 页面级 Provider：页面状态（PageManager）/ 画布引擎桥（LayersPanel、
    // PageThumbnail）/ 选区状态（图层行与画布共用），随页面释放。
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<WbPageState>.value(value: _pages),
        Provider<WbCanvasEngine>.value(value: _canvasEngine),
        ChangeNotifierProvider<WbSelectionState>.value(value: _selection),
      ],
      child: Scaffold(
        key: _scaffoldKey,
        endDrawer: const WbParticipantsPanel(),
        appBar: AppBar(
          backgroundColor: colors.surface,
          leading: IconButton(
            tooltip: '返回列表',
            icon: const Icon(LinearIcons.back),
            onPressed: _leave,
          ),
          title: Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  widget.boardName.isEmpty
                      ? '白板 ${widget.boardId}'
                      : widget.boardName,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              const WbCoreStatusChip(),
              const SizedBox(width: 8),
              WbCollabEntryButton(onPressed: _openCollabEntry),
              const SizedBox(width: 8),
              const WbPresentModeChip(),
            ],
          ),
          actions: <Widget>[
            IconButton(
              tooltip: '导出 .wbd 文件',
              icon: const Icon(LinearIcons.export),
              onPressed: _exportBoard,
            ),
            IconButton(
              tooltip: '导入 .wbd 文件',
              icon: const Icon(LinearIcons.import),
              onPressed: removed ? null : _importBoard,
            ),
            const WbRaiseHandButton(),
            const WbPresentButton(),
            WbParticipantsButton(
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
            const _FullscreenButton(),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: <Widget>[
            const _RemovedBanner(),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final bool wide = constraints.maxWidth >= kWideBreakpoint;
                  return Column(
                    children: <Widget>[
                      Expanded(
                        child: wide
                            ? Row(
                                children: <Widget>[
                                  SizedBox(
                                    width: 240,
                                    child: _EditSidebar(
                                      canvas: _canvas,
                                      canEdit: !removed,
                                      onBlockedEdit: _notifyReadOnly,
                                      refreshSignal: _refreshSignal,
                                    ),
                                  ),
                                  const VerticalDivider(width: 1),
                                  Expanded(child: _canvasArea(wide: wide)),
                                ],
                              )
                            : _canvasArea(wide: wide),
                      ),
                      if (!wide)
                        _BottomToolBar(
                          tool: _tool,
                          onSelect: _selectTool,
                          controller: _canvas,
                          onMore: () => unawaited(_showMoreCreateMenu()),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 画布区：引擎就绪且控制器就位时使用共享 [CanvasView]（完整交互，
  /// 元素经 `WbWasmCanvasStore` 落引擎），否则演示画布降级。
  ///
  /// [wide] 为真时渲染画布左上角浮动工具面板（`showToolPalette`，
  /// 与桌面「顶部」风格同源）；窄屏工具选择由底部工具条承担。
  ///
  /// 当前页信息（pageId / 背景）由 [WbPageState] 驱动：切页 / 换背景 →
  /// CanvasView 自动切换画布文档并重建 painter（与桌面同一驱动方式）。
  Widget _canvasArea({required bool wide}) {
    final WbCoreService core = context.watch<WbCoreService>();
    final bool removed = context.watch<WbRealtimeService>().isRemoved;
    final WbCanvasController? canvas = _canvas;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: core.status == WbCoreStatus.ready && canvas != null
              ? Consumer<WbPageState>(
                  builder: (
                    BuildContext context,
                    WbPageState pages,
                    Widget? child,
                  ) {
                    return WbWebContextToolbarHost(
                      key: _contextToolbarKey,
                      controller: canvas,
                      enabled: !removed,
                      onCommand: _handleToolbarCommand,
                      child: CanvasView(
                        controller: canvas,
                        selection: _selection,
                        showToolPalette: wide,
                        onQuickCreate: _createProfessionalElement,
                        drawingEnabled: !removed,
                        pageId: pages.currentPageId,
                        pageBackground: pages.currentPage?.background,
                      ),
                    );
                  },
                )
              : const WbDemoCanvas(),
        ),
        // 远端在场层（P4）：远端光标 / 选区浮标（IgnorePointer，不拦截交互）。
        if (_presence != null &&
            canvas != null &&
            core.status == WbCoreStatus.ready)
          Positioned.fill(
            child: WbRemoteCursorsOverlay(
              store: _presence!,
              controller: canvas,
            ),
          ),
        // 宽屏快速创建入口（对齐桌面左下角浮出「+」；窄屏走底部工具条
        // 「更多」菜单）。
        if (wide && canvas != null && core.status == WbCoreStatus.ready)
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
        const Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Center(child: _FallbackBanner()),
        ),
      ],
    );
  }
}

/// 移出只读横幅（M3 / T3.4）：`room:removed` 单播后展示。
///
/// 被移出后本地编辑入口禁用（宽屏顶部工具面板经 `drawingEnabled`
/// 置灰 / 窄屏底部工具条置为不可点），互动入口（举手 / 演示 / 授权）
/// 由服务层 `isRemoved` 判定隐藏。
class _RemovedBanner extends StatelessWidget {
  const _RemovedBanner();

  @override
  Widget build(BuildContext context) {
    final WbRealtimeService realtime = context.watch<WbRealtimeService>();
    if (!realtime.isRemoved) {
      return const SizedBox.shrink();
    }
    final WbThemeColors colors = context.wbColors;
    return Material(
      key: const Key('wb-removed-banner'),
      color: colors.elevated,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(LinearIcons.warning, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            const Expanded(
              child: WbText(
                '你已被移出该白板，当前为只读模式',
                variant: WbTextVariant.label,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 降级提示条：仅当 WASM 核心不可用时显示（不阻塞画布交互）。
class _FallbackBanner extends StatelessWidget {
  const _FallbackBanner();

  @override
  Widget build(BuildContext context) {
    final WbCoreService core = context.watch<WbCoreService>();
    if (core.status != WbCoreStatus.unavailable) {
      return const SizedBox.shrink();
    }
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: colors.elevated,
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LinearIcons.info, size: 16, color: colors.primary),
            const SizedBox(width: 8),
            const Flexible(
              child: WbText(
                'WASM 核心不可用（加载失败或资源缺失），当前为内置演示画布',
                variant: WbTextVariant.caption,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 宽屏左侧栏（编辑页）：页面 / 图层两分区（工具为画布顶部浮动面板）。
///
/// 页面与图层分区为共享包组件（[PageManager] / [LayersPanel]），
/// 消费页面级 Provider（[WbPageState] / [WbCanvasEngine]）；引擎不可用
/// （WASM 加载失败）时面板自身降级（内存页面 / 演示缓存），不阻塞画布。
class _EditSidebar extends StatelessWidget {
  const _EditSidebar({
    required this.canvas,
    required this.canEdit,
    required this.onBlockedEdit,
    required this.refreshSignal,
  });

  /// 共享画布控制器（可空：引擎就绪前图层区走演示缓存）。
  final WbCanvasController? canvas;

  /// 是否允许编辑（被移出房间后为 false，编辑入口统一拦截）。
  final bool canEdit;

  /// 编辑被拦时的统一提示回调。
  final VoidCallback onBlockedEdit;

  /// 手动刷新信号（缩略图 / 图层共享）。
  final ValueNotifier<int> refreshSignal;

  /// 新建页面（只读守卫：无编辑权限时提示并拒绝）。
  void _addPage(BuildContext context) {
    if (!canEdit) {
      onBlockedEdit();
      return;
    }
    context.read<WbPageState>().addPage();
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: colors.sidebarBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SidebarSectionHeader(
            icon: LinearIcons.page,
            title: '页面',
            actions: <Widget>[
              IconButton(
                key: const ValueKey<String>('web-pages-refresh'),
                tooltip: '刷新缩略图',
                icon: Icon(LinearIcons.refresh, size: 14, color: colors.icon),
                onPressed: () => refreshSignal.value++,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                splashRadius: 12,
              ),
              IconButton(
                key: const ValueKey<String>('web-pages-add'),
                tooltip: '新建页面',
                icon: Icon(LinearIcons.addPage, size: 14, color: colors.icon),
                onPressed: () => _addPage(context),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                splashRadius: 12,
              ),
            ],
          ),
          Expanded(
            flex: 3,
            child: PageManager(
              refreshSignal: refreshSignal,
              canEdit: canEdit,
              onBlockedEdit: onBlockedEdit,
            ),
          ),
          Divider(height: 1, color: colors.border),
          const _SidebarSectionHeader(
            icon: LinearIcons.layers,
            title: '图层',
          ),
          Expanded(
            flex: 2,
            child: LayersPanel(
              refreshSignal: refreshSignal,
              canvasController: canvas,
              canEdit: canEdit,
              onBlockedEdit: onBlockedEdit,
            ),
          ),
        ],
      ),
    );
  }
}

/// 侧栏分区标题（图标 + 标题 + 可选操作按钮）。
class _SidebarSectionHeader extends StatelessWidget {
  const _SidebarSectionHeader({
    required this.icon,
    required this.title,
    this.actions = const <Widget>[],
  });

  /// 分区图标。
  final IconData icon;

  /// 分区标题。
  final String title;

  /// 右侧操作按钮。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return SizedBox(
      height: 34,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 14, color: colors.icon),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.icon,
                ),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 画布工具清单（工具 + 图标；窄屏底部工具条）。
///
/// 与端上 `WbCanvasToolPalette` 工具行同序同图标（11 工具全量，含
/// 图片 / 3D）；宽屏工具选择由画布浮动面板（`WbCanvasToolPalette`）
/// 直接驱动控制器，不经本清单。
const List<(WbCanvasTool, IconData)> _canvasTools = <(WbCanvasTool, IconData)>[
  (WbCanvasTool.select, LinearIcons.select),
  (WbCanvasTool.hand, LinearIcons.hand),
  (WbCanvasTool.pen, LinearIcons.pen),
  (WbCanvasTool.highlighter, LinearIcons.highlighter),
  (WbCanvasTool.eraser, LinearIcons.eraser),
  (WbCanvasTool.note, LinearIcons.stickyNote),
  (WbCanvasTool.text, LinearIcons.text),
  (WbCanvasTool.shape, LinearIcons.shape),
  (WbCanvasTool.image, LinearIcons.image),
  (WbCanvasTool.connector, LinearIcons.connector),
  (WbCanvasTool.render3d, LinearIcons.cube),
];

/// 底部工具条（窄屏单栏布局；与端上 `WbCanvasToolPalette` 工具行同集：
/// 11 工具 + 撤销 / 重做 + 「更多」，复用共享 `WbCanvasIconButton` 三态样式）。
///
/// 只读收窄（M3，与端上 `drawingEnabled` 同口径）：被移出房间时仅保留
/// 导航工具（选择 / 抓手），撤销 / 重做与「更多」置灰。
class _BottomToolBar extends StatelessWidget {
  const _BottomToolBar({
    required this.tool,
    required this.onSelect,
    this.controller,
    this.onMore,
  });

  /// 当前工具。
  final WbCanvasTool tool;

  /// 工具切换回调。
  final ValueChanged<WbCanvasTool> onSelect;

  /// 画布控制器（撤销 / 重做状态源；演示模式为 null → 两者置灰）。
  final WbCanvasController? controller;

  /// 「更多」入口回调（null 时不显示；P3：专业元素创建菜单）。
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final bool canEdit = !context.watch<WbRealtimeService>().isRemoved;
    final VoidCallback? onMoreTap = onMore;
    return Material(
      color: colors.toolbarBackground,
      child: SizedBox(
        height: 60,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: <Widget>[
            for (final (WbCanvasTool itemTool, IconData icon) in _canvasTools)
              _bottomSlot(
                WbCanvasIconButton(
                  key: ValueKey<String>('wb-bottom-tool-${itemTool.id}'),
                  icon: icon,
                  tooltip: itemTool.label,
                  active: itemTool == tool,
                  enabled: canEdit || _isNavigationTool(itemTool),
                  onTap: () => onSelect(itemTool),
                ),
              ),
            _divider(colors),
            _BottomUndoRedo(controller: controller, enabled: canEdit),
            _divider(colors),
            if (onMoreTap != null)
              _bottomSlot(
                WbCanvasIconButton(
                  key: const Key('wb-bottom-more'),
                  icon: LinearIcons.more,
                  tooltip: '更多',
                  enabled: canEdit,
                  onTap: onMoreTap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 竖分隔线（与端上工具行 `1×20` 同规格）。
  Widget _divider(WbThemeColors colors) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 20),
        child: SizedBox(
          width: 1,
          child: ColoredBox(color: colors.border),
        ),
      );
}

/// 底部条槽位（32px 按钮 + 上下 14px，撑满 60px 条高，与端上同密度）。
Widget _bottomSlot(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 14),
      child: child,
    );

/// 导航类工具（只读收窄时保留可用：选择 / 抓手；与端上同口径）。
bool _isNavigationTool(WbCanvasTool tool) =>
    tool == WbCanvasTool.select || tool == WbCanvasTool.hand;

/// 底部条撤销 / 重做（监听 [controller]；与端上 `WbCanvasToolPalette`
/// 工具行同口径：`enabled && canUndo / canRedo`）。
class _BottomUndoRedo extends StatelessWidget {
  const _BottomUndoRedo({required this.controller, required this.enabled});

  /// 画布控制器（null = 演示模式 → 置灰）。
  final WbCanvasController? controller;

  /// 是否允许编辑（被移出房间时为 false）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final WbCanvasController? canvas = controller;
    if (canvas == null) {
      return _pair(canUndo: false, canRedo: false);
    }
    return ListenableBuilder(
      listenable: canvas,
      builder: (BuildContext context, Widget? child) => _pair(
        canUndo: canvas.canUndo,
        canRedo: canvas.canRedo,
      ),
    );
  }

  Widget _pair({required bool canUndo, required bool canRedo}) {
    final WbCanvasController? canvas = controller;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _bottomSlot(
          WbCanvasIconButton(
            key: const Key('wb-bottom-undo'),
            icon: LinearIcons.undo,
            tooltip: '撤销 (Ctrl+Z)',
            enabled: enabled && canUndo,
            onTap: () => canvas?.undo(),
          ),
        ),
        _bottomSlot(
          WbCanvasIconButton(
            key: const Key('wb-bottom-redo'),
            icon: LinearIcons.redo,
            tooltip: '重做 (Ctrl+Shift+Z)',
            enabled: enabled && canRedo,
            onTap: () => canvas?.redo(),
          ),
        ),
      ],
    );
  }
}

/// 全屏切换按钮（映射浏览器 Fullscreen API，见 platform/web）。
class _FullscreenButton extends StatefulWidget {
  const _FullscreenButton();

  @override
  State<_FullscreenButton> createState() => _FullscreenButtonState();
}

class _FullscreenButtonState extends State<_FullscreenButton> {
  final WebWindowPlugin _window = WebWindowPlugin();
  bool _fullscreen = false;

  Future<void> _toggle() async {
    // 非 Web / 被浏览器拒绝时静默 no-op（见 platform/web 文档）。
    await _window.setFullscreen(!_fullscreen);
    if (mounted) {
      setState(() => _fullscreen = !_fullscreen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: _fullscreen ? '退出全屏' : '全屏',
      icon: const Icon(LinearIcons.fullscreen),
      onPressed: () => unawaited(_toggle()),
    );
  }
}
