/// wb_core_bindings.dart — FFI binding table over the native `wb_core` library.
///
/// Hand-maintained mirror of `core/include/wb/wb.h` (109 C ABI exports).
/// ffigen-style: regenerate with `dart run ffigen --config ffigen.yaml` when
/// the header changes; keep the shared typedef names stable either way.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart' show Utf8;

// ---------------------------------------------------------------------------
// Shared call shapes (Native / Dart pairs).
// ---------------------------------------------------------------------------

/// `const char* f()`
typedef WbStr0Native = Pointer<Utf8> Function();
typedef WbStr0Dart = Pointer<Utf8> Function();

/// `const char* f(const char*)`
typedef WbStr1Native = Pointer<Utf8> Function(Pointer<Utf8>);
typedef WbStr1Dart = Pointer<Utf8> Function(Pointer<Utf8>);

/// `const char* f(const char*, const char*)`
typedef WbStr2Native = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef WbStr2Dart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

/// `const char* f(const char*, const char*, const char*)`
typedef WbStr3Native = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef WbStr3Dart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

/// `const char* f(int)`
typedef WbStrI1Native = Pointer<Utf8> Function(Int32);
typedef WbStrI1Dart = Pointer<Utf8> Function(int);

/// `const char* f(const char*, int)`
typedef WbStrP1I1Native = Pointer<Utf8> Function(Pointer<Utf8>, Int32);
typedef WbStrP1I1Dart = Pointer<Utf8> Function(Pointer<Utf8>, int);

/// `const char* f(const char*, int, int)`
typedef WbStrP1I2Native = Pointer<Utf8> Function(Pointer<Utf8>, Int32, Int32);
typedef WbStrP1I2Dart = Pointer<Utf8> Function(Pointer<Utf8>, int, int);

/// `const char* f(const char*, int, const char*)`
typedef WbStrP1I1P1Native = Pointer<Utf8> Function(
    Pointer<Utf8>, Int32, Pointer<Utf8>);
typedef WbStrP1I1P1Dart = Pointer<Utf8> Function(
    Pointer<Utf8>, int, Pointer<Utf8>);

/// `const char* f(const char*, float, float)`
typedef WbStrP1F2Native = Pointer<Utf8> Function(Pointer<Utf8>, Float, Float);
typedef WbStrP1F2Dart = Pointer<Utf8> Function(Pointer<Utf8>, double, double);

/// `const char* f(float, float, float)`
typedef WbStrF3Native = Pointer<Utf8> Function(Float, Float, Float);
typedef WbStrF3Dart = Pointer<Utf8> Function(double, double, double);

/// `const char* f(uint64_t)`
typedef WbStrU1Native = Pointer<Utf8> Function(Uint64);
typedef WbStrU1Dart = Pointer<Utf8> Function(int);

/// `const char* f(uint64_t, const char*)`
typedef WbStrU1P1Native = Pointer<Utf8> Function(Uint64, Pointer<Utf8>);
typedef WbStrU1P1Dart = Pointer<Utf8> Function(int, Pointer<Utf8>);

/// `const char* f(uint64_t, int)`
typedef WbStrU1I1Native = Pointer<Utf8> Function(Uint64, Int32);
typedef WbStrU1I1Dart = Pointer<Utf8> Function(int, int);

/// `const char* f(uint64_t, const char*, int, int)`
typedef WbStrU1P1I2Native = Pointer<Utf8> Function(
    Uint64, Pointer<Utf8>, Int32, Int32);
typedef WbStrU1P1I2Dart = Pointer<Utf8> Function(
    int, Pointer<Utf8>, int, int);

/// `int f(const char*)`
typedef WbInt1P1Native = Int32 Function(Pointer<Utf8>);
typedef WbInt1P1Dart = int Function(Pointer<Utf8>);

/// `uint64_t f(const char*)`
typedef WbU1P1Native = Uint64 Function(Pointer<Utf8>);
typedef WbU1P1Dart = int Function(Pointer<Utf8>);

/// `void f()`
typedef WbVoid0Native = Void Function();
typedef WbVoid0Dart = void Function();

/// `void f(uint64_t)`
typedef WbVoidU1Native = Void Function(Uint64);
typedef WbVoidU1Dart = void Function(int);

/// `void f(const char*)`
typedef WbVoidP1Native = Void Function(Pointer<Utf8>);
typedef WbVoidP1Dart = void Function(Pointer<Utf8>);

// ---------------------------------------------------------------------------
// Contract typedef names (Wave 0 surface — keep stable).
// ---------------------------------------------------------------------------

typedef WbInitNative = WbInt1P1Native;
typedef WbInitDart = WbInt1P1Dart;
typedef WbVersionNative = WbStr0Native;
typedef WbVersionDart = WbStr0Dart;
typedef WbCreateBoardNative = WbU1P1Native;
typedef WbCreateBoardDart = WbU1P1Dart;
typedef WbDestroyBoardNative = WbVoidU1Native;
typedef WbDestroyBoardDart = WbVoidU1Dart;
typedef WbBoardGetNative = WbStrU1Native;
typedef WbBoardGetDart = WbStrU1Dart;
typedef WbExecuteCommandNative = WbStrU1P1Native;
typedef WbExecuteCommandDart = WbStrU1P1Dart;
typedef WbExecuteToolNative = WbStr2Native;
typedef WbExecuteToolDart = WbStr2Dart;
typedef WbFreeNative = WbVoidP1Native;
typedef WbFreeDart = WbVoidP1Dart;

// ---------------------------------------------------------------------------
// Binding table
// ---------------------------------------------------------------------------

/// Lazily-resolved symbols of the native `wb_core` library.
///
/// Every field maps 1:1 to a `WB_API` function in `wb.h`; symbols are resolved
/// on first access, so a missing export only fails when actually used.
class WbCoreBindings {
  WbCoreBindings(this.library);

  /// Underlying handle (also used to construct companion helpers).
  final DynamicLibrary library;

  // ---- Lifecycle -----------------------------------------------------------

  late final WbInt1P1Dart wbInit =
      library.lookupFunction<WbInt1P1Native, WbInt1P1Dart>('wb_init');
  late final WbVoid0Dart wbShutdown =
      library.lookupFunction<WbVoid0Native, WbVoid0Dart>('wb_shutdown');
  late final WbStr0Dart wbVersion =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_version');
  late final WbVoidP1Dart wbFree =
      library.lookupFunction<WbVoidP1Native, WbVoidP1Dart>('wb_free');

  // ---- Board / command -----------------------------------------------------

  late final WbU1P1Dart wbCreateBoard =
      library.lookupFunction<WbU1P1Native, WbU1P1Dart>('wb_create_board');
  late final WbVoidU1Dart wbDestroyBoard = library
      .lookupFunction<WbVoidU1Native, WbVoidU1Dart>('wb_destroy_board');
  late final WbStrU1Dart wbBoardGet =
      library.lookupFunction<WbStrU1Native, WbStrU1Dart>('wb_board_get');
  late final WbStrU1P1Dart wbExecuteCommand = library
      .lookupFunction<WbStrU1P1Native, WbStrU1P1Dart>('wb_execute_command');
  late final WbStr2Dart wbExecuteTool =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_execute_tool');

  // ---- Render (generic) ----------------------------------------------------

  late final WbStrU1I1Dart wbGetDisplayList = library
      .lookupFunction<WbStrU1I1Native, WbStrU1I1Dart>('wb_get_display_list');
  late final WbStrP1I1Dart wbRenderDisplayList = library
      .lookupFunction<WbStrP1I1Native, WbStrP1I1Dart>('wb_render_display_list');
  late final WbStr2Dart wbRenderDirty =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_render_dirty');
  late final WbStrU1P1I2Dart wbRender3d = library
      .lookupFunction<WbStrU1P1I2Native, WbStrU1P1I2Dart>('wb_render_3d');
  late final WbStrP1I2Dart wbRenderThumbnail = library
      .lookupFunction<WbStrP1I2Native, WbStrP1I2Dart>('wb_render_thumbnail');
  late final WbStr0Dart wbRenderCacheStats = library
      .lookupFunction<WbStr0Native, WbStr0Dart>('wb_render_cache_stats');
  late final WbStr0Dart wbRenderCacheClear = library
      .lookupFunction<WbStr0Native, WbStr0Dart>('wb_render_cache_clear');
  late final WbStr0Dart wbRenderPerfStats = library
      .lookupFunction<WbStr0Native, WbStr0Dart>('wb_render_perf_stats');

  // ---- Tools ---------------------------------------------------------------

  late final WbStr0Dart wbToolList =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_tool_list');
  late final WbStr1Dart wbToolGet =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_tool_get');

  // ---- Page ----------------------------------------------------------------

  late final WbStr1Dart wbPageList =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_page_list');
  late final WbStr2Dart wbPageCreate =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_page_create');
  late final WbStr1Dart wbPageDuplicate =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_page_duplicate');
  late final WbStr1Dart wbPageDelete =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_page_delete');
  late final WbStrP1I1Dart wbPageMove =
      library.lookupFunction<WbStrP1I1Native, WbStrP1I1Dart>('wb_page_move');
  late final WbStr2Dart wbPageRename =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_page_rename');
  late final WbStr2Dart wbPageSetBackground = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_page_set_background');
  late final WbStrP1I1Dart wbPageLock =
      library.lookupFunction<WbStrP1I1Native, WbStrP1I1Dart>('wb_page_lock');
  late final WbStrP1I1Dart wbPageHide =
      library.lookupFunction<WbStrP1I1Native, WbStrP1I1Dart>('wb_page_hide');

  // ---- Element -------------------------------------------------------------

  late final WbStr2Dart wbElementCreate =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_element_create');
  late final WbStr2Dart wbElementUpdate =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_element_update');
  late final WbStr1Dart wbElementDelete =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_element_delete');
  late final WbStr1Dart wbElementList =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_element_list');
  late final WbStr2Dart wbElementBatch =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_element_batch');

  // ---- Toolbar -------------------------------------------------------------

  late final WbStr0Dart wbToolbarList =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_toolbar_list');
  late final WbStr1Dart wbToolbarContext = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_toolbar_context');
  late final WbStr2Dart wbToolbarInvoke = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_toolbar_invoke');

  // ---- Radial menu ---------------------------------------------------------

  late final WbStrF3Dart wbRadialLayout =
      library.lookupFunction<WbStrF3Native, WbStrF3Dart>('wb_radial_layout');
  late final WbStrP1F2Dart wbRadialHitTest = library
      .lookupFunction<WbStrP1F2Native, WbStrP1F2Dart>('wb_radial_hit_test');
  late final WbStr0Dart wbRadialStateCreate = library
      .lookupFunction<WbStr0Native, WbStr0Dart>('wb_radial_state_create');
  late final WbStr1Dart wbRadialStateGet =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_radial_state_get');

  // ---- 3D ------------------------------------------------------------------

  late final WbStr2Dart wb3dCreate =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_3d_create');
  late final WbStrP1I2Dart wb3dRender =
      library.lookupFunction<WbStrP1I2Native, WbStrP1I2Dart>('wb_3d_render');
  late final WbStrP1F2Dart wb3dPickSurface = library
      .lookupFunction<WbStrP1F2Native, WbStrP1F2Dart>('wb_3d_pick_surface');
  late final WbStrP1I1P1Dart wb3dSetFaceColor = library.lookupFunction<
      WbStrP1I1P1Native, WbStrP1I1P1Dart>('wb_3d_set_face_color');
  late final WbStr2Dart wb3dSetMaterial =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_3d_set_material');
  late final WbStr2Dart wb3dSetLight =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_3d_set_light');
  late final WbStr2Dart wb3dTransform =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_3d_transform');
  late final WbStr2Dart wb3dExport =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_3d_export');

  // ---- Function plot -------------------------------------------------------

  late final WbStr2Dart wbFunctionCreate = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_function_create');
  late final WbStr2Dart wbFunctionSetStyle = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_function_set_style');
  late final WbStr2Dart wbFunctionAdd =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_function_add');
  late final WbStr2Dart wbFunctionAnalyze = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_function_analyze');
  late final WbStr2Dart wbFunctionExport = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_function_export');

  // ---- Flowchart -----------------------------------------------------------

  late final WbStr2Dart wbFlowchartCreate = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_flowchart_create');
  late final WbStr2Dart wbFlowchartAutoLayout = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_flowchart_auto_layout');
  late final WbStrP1I1Dart wbFlowchartToSwimlane = library.lookupFunction<
      WbStrP1I1Native, WbStrP1I1Dart>('wb_flowchart_to_swimlane');
  late final WbStr1Dart wbFlowchartLabelBranches = library.lookupFunction<
      WbStr1Native, WbStr1Dart>('wb_flowchart_label_branches');

  // ---- 2D rendering --------------------------------------------------------

  late final WbStr2Dart wbRender2dCreate = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_render_2d_create');
  late final WbStr2Dart wbRender2dSetStyle = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_render_2d_set_style');
  late final WbStr2Dart wbRender2dAnnotate = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_render_2d_annotate');

  // ---- Sidebar -------------------------------------------------------------

  late final WbStr1Dart wbSidebarToggle = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_sidebar_toggle');
  late final WbStrP1I1Dart wbSidebarSetWidth = library
      .lookupFunction<WbStrP1I1Native, WbStrP1I1Dart>('wb_sidebar_set_width');

  // ---- Theme ---------------------------------------------------------------

  late final WbStr1Dart wbThemeLoad =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_theme_load');
  late final WbStr0Dart wbThemeCurrent =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_theme_current');
  late final WbStr0Dart wbThemeList =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_theme_list');

  // ---- Annotation ----------------------------------------------------------

  late final WbStr1Dart wbAnnotateEnterTransparent = library.lookupFunction<
      WbStr1Native, WbStr1Dart>('wb_annotate_enter_transparent');
  late final WbStr1Dart wbAnnotateExitTransparent = library.lookupFunction<
      WbStr1Native, WbStr1Dart>('wb_annotate_exit_transparent');
  late final WbStrI1Dart wbAnnotateSetPenetrate = library.lookupFunction<
      WbStrI1Native, WbStrI1Dart>('wb_annotate_set_penetrate');

  // ---- AI sessions ---------------------------------------------------------

  late final WbStr2Dart wbAiSessionCreate = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_ai_session_create');
  late final WbStr1Dart wbAiSessionClose = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_ai_session_close');
  late final WbStr1Dart wbAiSessionGet =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_ai_session_get');
  late final WbStr2Dart wbAiSendMessage = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_ai_send_message');
  late final WbStr2Dart wbAiSendAudio =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_ai_send_audio');
  late final WbStr1Dart wbAiListMessages = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_ai_list_messages');
  late final WbStr2Dart wbAiExecuteToolCall = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_ai_execute_tool_call');
  late final WbStr2Dart wbAiPreviewToolCall = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_ai_preview_tool_call');
  late final WbStr2Dart wbAiCancelToolCall = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_ai_cancel_tool_call');
  late final WbStr2Dart wbAiSetContext =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_ai_set_context');

  // ---- MCP server ----------------------------------------------------------

  late final WbStr1Dart wbMcpStart =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_start');
  late final WbStr0Dart wbMcpStop =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_mcp_stop');
  late final WbStr0Dart wbMcpIsRunning =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_mcp_is_running');
  late final WbStr2Dart wbMcpHandleRequest = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_mcp_handle_request');
  late final WbStr1Dart wbMcpSessionCreate = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_session_create');
  late final WbStr1Dart wbMcpSessionGet = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_session_get');
  late final WbStr1Dart wbMcpSessionClose = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_session_close');
  late final WbStr1Dart wbMcpListTools =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_list_tools');
  late final WbStr3Dart wbMcpCallTool =
      library.lookupFunction<WbStr3Native, WbStr3Dart>('wb_mcp_call_tool');
  late final WbStr1Dart wbMcpListResources = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_list_resources');
  late final WbStr2Dart wbMcpReadResource = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_mcp_read_resource');
  late final WbStr1Dart wbMcpListPrompts = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_list_prompts');
  late final WbStr3Dart wbMcpGetPrompt =
      library.lookupFunction<WbStr3Native, WbStr3Dart>('wb_mcp_get_prompt');
  late final WbStr1Dart wbMcpAuditQuery = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_audit_query');
  late final WbStr1Dart wbMcpAuditExport = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_mcp_audit_export');

  // ---- Sync (placeholder) --------------------------------------------------

  late final WbStr2Dart wbSyncConnect =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_sync_connect');
  late final WbStr0Dart wbSyncDisconnect =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_sync_disconnect');
  late final WbStr0Dart wbSyncStatus =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_sync_status');
  late final WbStrI1Dart wbSyncSetOffline = library
      .lookupFunction<WbStrI1Native, WbStrI1Dart>('wb_sync_set_offline');

  // M1 collaboration data plane — thin JSON-in/JSON-out forwards into the
  // "sync" domain (see wb.h; the four control-plane symbols above keep their
  // signatures). No callback-channel symbol (D6 stays poll-based).
  late final WbStr2Dart wbSyncJoin =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_sync_join');
  late final WbStr1Dart wbSyncSendOperation = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_sync_send_operation');
  late final WbStr0Dart wbSyncFlush =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_sync_flush');
  late final WbStr0Dart wbSyncEvents =
      library.lookupFunction<WbStr0Native, WbStr0Dart>('wb_sync_events');
  late final WbStr1Dart wbSyncSendPreview = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_sync_send_preview');

  // M2 collaboration data plane — `lock` forward into the same "sync" domain
  // (D2-C software lock; args {action, elementId} → {requested}; the async
  // outcome surfaces via events' room.lockAcks / room.locks).
  late final WbStr1Dart wbSyncLock =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_sync_lock');

  // M3 collaboration data plane — `interactive` forward into the same "sync"
  // domain (T3.2; args {action, userId?, targetUserId?} over the closed action
  // set raiseHand / lowerHand / startPresent / stopPresent / grantControl /
  // revokeControl / removeUser / follow / unfollow → {requested}; the async
  // outcome surfaces via events' interactiveAcks).
  late final WbStr1Dart wbSyncInteractive = library
      .lookupFunction<WbStr1Native, WbStr1Dart>('wb_sync_interactive');

  // ---- CRDT ----------------------------------------------------------------

  late final WbStr2Dart wbCrdtCreate =
      library.lookupFunction<WbStr2Native, WbStr2Dart>('wb_crdt_create');
  late final WbStr2Dart wbCrdtApplyLocal = library
      .lookupFunction<WbStr2Native, WbStr2Dart>('wb_crdt_apply_local');

  // ---- Permission / audit --------------------------------------------------

  late final WbStr3Dart wbPermissionCheck = library
      .lookupFunction<WbStr3Native, WbStr3Dart>('wb_permission_check');
  late final WbStr1Dart wbAuditQuery =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_audit_query');
  late final WbStr1Dart wbAuditExport =
      library.lookupFunction<WbStr1Native, WbStr1Dart>('wb_audit_export');
}
