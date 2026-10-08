#pragma once

// wb.h — C ABI export surface of the whiteboard core engine.
//
// CONTRACT FILE (Wave 0). Every task package MUST implement/consume these
// exact signatures. Do not rename or reorder; new functions may only be added
// by the coordinator.
//
// Aggregated from design docs:
//   《C++ 核心引擎接口设计》§5.1   (lifecycle / board / command / page / element / toolbar / radial / 3d / function / flowchart / sidebar / theme)
//   《渲染引擎设计》§15.3          (render display list / 2d / 3d / function / cache / perf)
//   《AI 助手与 MCP 设计》§7.5     (ai sessions)
//   《MCP_Server详细设计》§11.10   (mcp server / session / tools / resources / prompts / audit)
//   《互动白板预留接口设计》M10.1   (sync placeholders)
//   《互动白板实时协同设计文档》§8.2/§8.3 (M1 collaboration data plane forwards)
//   《互动白板实时协同设计文档》§5.6/§6   (M2 lock forward, wb_sync_lock)
//   《互动白板实时协同设计文档》§5.10/§6 (M3 interactive forward,
//                                          wb_sync_interactive)
//
// Conventions:
//   - All inputs/outputs are UTF-8 JSON strings unless noted otherwise.
//   - Returned const char* MUST be released with wb_free().
//   - All functions are thread-safe unless documented otherwise.

#include <cstdint>

#if defined(_WIN32)
#if defined(WB_STATIC)
#define WB_API
#elif defined(WB_CORE_EXPORTS)
#define WB_API __declspec(dllexport)
#else
#define WB_API __declspec(dllimport)
#endif
#else
#define WB_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
WB_API int wb_init(const char* configJson);
WB_API void wb_shutdown();
WB_API const char* wb_version();

// ---------------------------------------------------------------------------
// Memory — releases any const char* returned by this API.
// ---------------------------------------------------------------------------
WB_API void wb_free(const char* ptr);

// ---------------------------------------------------------------------------
// Board
// ---------------------------------------------------------------------------
WB_API uint64_t wb_create_board(const char* json);
WB_API void wb_destroy_board(uint64_t handle);
WB_API const char* wb_board_get(uint64_t handle);

// ---------------------------------------------------------------------------
// Command
// ---------------------------------------------------------------------------
WB_API const char* wb_execute_command(uint64_t handle, const char* cmdJson);
WB_API const char* wb_execute_tool(const char* toolId, const char* argsJson);

// ---------------------------------------------------------------------------
// Render (generic)
// ---------------------------------------------------------------------------
WB_API const char* wb_get_display_list(uint64_t handle, int layer);
WB_API const char* wb_render_display_list(const char* pageId, int layer);
WB_API const char* wb_render_dirty(const char* pageId, const char* dirtyJson);
WB_API const char* wb_render_3d(uint64_t handle, const char* elementId, int width, int height);
WB_API const char* wb_render_thumbnail(const char* pageId, int width, int height);
WB_API const char* wb_render_cache_stats();
WB_API const char* wb_render_cache_clear();
WB_API const char* wb_render_perf_stats();

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------
WB_API const char* wb_tool_list();
WB_API const char* wb_tool_get(const char* toolId);

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------
WB_API const char* wb_page_list(const char* boardId);
WB_API const char* wb_page_create(const char* boardId, const char* json);
WB_API const char* wb_page_duplicate(const char* pageId);
WB_API const char* wb_page_delete(const char* pageId);
WB_API const char* wb_page_move(const char* pageId, int newIndex);
WB_API const char* wb_page_rename(const char* pageId, const char* name);
WB_API const char* wb_page_set_background(const char* pageId, const char* bgJson);
WB_API const char* wb_page_lock(const char* pageId, int locked);
WB_API const char* wb_page_hide(const char* pageId, int hidden);

// ---------------------------------------------------------------------------
// Element
// ---------------------------------------------------------------------------
WB_API const char* wb_element_create(const char* pageId, const char* json);
WB_API const char* wb_element_update(const char* elementId, const char* json);
WB_API const char* wb_element_delete(const char* elementId);
WB_API const char* wb_element_list(const char* pageId);
WB_API const char* wb_element_batch(const char* pageId, const char* opsJson);

// ---------------------------------------------------------------------------
// Toolbar / context tools《白板软件设计文档》§9.2,《可扩展工具栏设计》§3
// ---------------------------------------------------------------------------
WB_API const char* wb_toolbar_list();
WB_API const char* wb_toolbar_context(const char* elementIdsJson);
WB_API const char* wb_toolbar_invoke(const char* toolId, const char* argsJson);

// ---------------------------------------------------------------------------
// Radial menu (gear dial)《齿轮圆盘交互详细设计》
// ---------------------------------------------------------------------------
WB_API const char* wb_radial_layout(float cx, float cy, float size);
WB_API const char* wb_radial_hit_test(const char* layoutJson, float x, float y);
WB_API const char* wb_radial_state_create();
WB_API const char* wb_radial_state_get(const char* stateId);

// ---------------------------------------------------------------------------
// 3D《渲染引擎设计》§7,《白板软件设计文档》§6.2
// ---------------------------------------------------------------------------
WB_API const char* wb_3d_create(const char* pageId, const char* json);
WB_API const char* wb_3d_render(const char* elementId, int width, int height);
WB_API const char* wb_3d_pick_surface(const char* elementId, float x, float y);
WB_API const char* wb_3d_set_face_color(const char* elementId, int faceId, const char* color);
WB_API const char* wb_3d_set_material(const char* elementId, const char* matJson);
WB_API const char* wb_3d_set_light(const char* elementId, const char* lightJson);
WB_API const char* wb_3d_transform(const char* elementId, const char* transformJson);
WB_API const char* wb_3d_export(const char* elementId, const char* format);

// ---------------------------------------------------------------------------
// Function plot《渲染引擎设计》§8
// ---------------------------------------------------------------------------
WB_API const char* wb_function_create(const char* pageId, const char* json);
WB_API const char* wb_function_set_style(const char* elementId, const char* styleJson);
WB_API const char* wb_function_add(const char* elementId, const char* expr);
WB_API const char* wb_function_analyze(const char* elementId, const char* type);
WB_API const char* wb_function_export(const char* elementId, const char* format);

// ---------------------------------------------------------------------------
// Flowchart《流程图模块设计》§13
// ---------------------------------------------------------------------------
WB_API const char* wb_flowchart_create(const char* pageId, const char* json);
WB_API const char* wb_flowchart_auto_layout(const char* flowchartId, const char* optionsJson);
WB_API const char* wb_flowchart_to_swimlane(const char* flowchartId, int orientation);
WB_API const char* wb_flowchart_label_branches(const char* flowchartId);

// ---------------------------------------------------------------------------
// 2D rendering《渲染引擎设计》§9
// ---------------------------------------------------------------------------
WB_API const char* wb_render_2d_create(const char* pageId, const char* json);
WB_API const char* wb_render_2d_set_style(const char* elementId, const char* styleJson);
WB_API const char* wb_render_2d_annotate(const char* elementId, const char* json);

// ---------------------------------------------------------------------------
// Sidebar《左侧栏与页面管理设计》
// ---------------------------------------------------------------------------
WB_API const char* wb_sidebar_toggle(const char* stateId);
WB_API const char* wb_sidebar_set_width(const char* stateId, int width);

// ---------------------------------------------------------------------------
// Theme《主题与背景系统设计》§11
// ---------------------------------------------------------------------------
WB_API const char* wb_theme_load(const char* themeJson);
WB_API const char* wb_theme_current();
WB_API const char* wb_theme_list();

// ---------------------------------------------------------------------------
// Annotation (transparent overlay)《透明批注模式技术方案》
// ---------------------------------------------------------------------------
WB_API const char* wb_annotate_enter_transparent(const char* configJson);
WB_API const char* wb_annotate_exit_transparent(const char* actionJson);
WB_API const char* wb_annotate_set_penetrate(int penetrate);

// ---------------------------------------------------------------------------
// AI sessions《AI 助手与 MCP 设计》§7.5
// ---------------------------------------------------------------------------
WB_API const char* wb_ai_session_create(const char* boardId, const char* userId);
WB_API const char* wb_ai_session_close(const char* sessionId);
WB_API const char* wb_ai_session_get(const char* sessionId);
WB_API const char* wb_ai_send_message(const char* sessionId, const char* message);
WB_API const char* wb_ai_send_audio(const char* sessionId, const char* audioData);
WB_API const char* wb_ai_list_messages(const char* sessionId);
WB_API const char* wb_ai_execute_tool_call(const char* sessionId, const char* toolCallId);
WB_API const char* wb_ai_preview_tool_call(const char* sessionId, const char* toolCallId);
WB_API const char* wb_ai_cancel_tool_call(const char* sessionId, const char* toolCallId);
WB_API const char* wb_ai_set_context(const char* sessionId, const char* contextJson);

// ---------------------------------------------------------------------------
// MCP server《MCP_Server详细设计》§11.10
// ---------------------------------------------------------------------------
WB_API const char* wb_mcp_start(const char* configJson);
WB_API const char* wb_mcp_stop();
WB_API const char* wb_mcp_is_running();
WB_API const char* wb_mcp_handle_request(const char* requestJson, const char* sessionId);

WB_API const char* wb_mcp_session_create(const char* token);
WB_API const char* wb_mcp_session_get(const char* sessionId);
WB_API const char* wb_mcp_session_close(const char* sessionId);

WB_API const char* wb_mcp_list_tools(const char* sessionId);
WB_API const char* wb_mcp_call_tool(const char* toolName, const char* argsJson, const char* sessionId);

WB_API const char* wb_mcp_list_resources(const char* sessionId);
WB_API const char* wb_mcp_read_resource(const char* uri, const char* sessionId);

WB_API const char* wb_mcp_list_prompts(const char* sessionId);
WB_API const char* wb_mcp_get_prompt(const char* name, const char* argsJson, const char* sessionId);

WB_API const char* wb_mcp_audit_query(const char* filterJson);
WB_API const char* wb_mcp_audit_export(const char* path);

// ---------------------------------------------------------------------------
// Sync (placeholder, 互动白板预留接口设计 M10.1)
// ---------------------------------------------------------------------------
WB_API const char* wb_sync_connect(const char* endpoint, const char* token);
WB_API const char* wb_sync_disconnect();
WB_API const char* wb_sync_status();
WB_API const char* wb_sync_set_offline(int offline);

// M1 collaboration data plane — thin JSON-in/JSON-out forwards into the
// existing "sync"/"crdt" domains (互动白板实时协同设计文档 §8.2 erratum).
// Pure additions: the four control-plane signatures above are unchanged and
// no callback-channel symbol is added (D6 stays poll-based).
WB_API const char* wb_sync_join(const char* boardId, const char* pageId);
WB_API const char* wb_sync_send_operation(const char* opJson);
WB_API const char* wb_sync_flush();
WB_API const char* wb_sync_events();
WB_API const char* wb_sync_send_preview(const char* previewJson);

// M2 data plane — `lock` forward into the same "sync" domain
// (互动白板实时协同设计文档 §5.6/§6, decision D2-C): args {action, elementId},
// result {requested}; the async outcome surfaces via `events`
// (room.lockAcks / room.locks). Same UTF-8 JSON envelope + wb_free contract.
WB_API const char* wb_sync_lock(const char* argsJson);

// M3 interactive forward, wb_sync_interactive (互动白板实时协同设计文档
// §5.10/§6, T3.2): args {action, userId?, targetUserId?} over the closed
// action set raiseHand / lowerHand / startPresent / stopPresent /
// grantControl / revokeControl / removeUser / follow / unfollow; result
// {requested}; the async outcome surfaces via `events` (interactiveAcks).
// Same UTF-8 JSON envelope + wb_free contract.
WB_API const char* wb_sync_interactive(const char* argsJson);

// ---------------------------------------------------------------------------
// CRDT (互动白板实时协同设计文档 §8.3, domain "crdt")
// ---------------------------------------------------------------------------
WB_API const char* wb_crdt_create(const char* docId, const char* actor);
WB_API const char* wb_crdt_apply_local(const char* docId, const char* opJson);

// ---------------------------------------------------------------------------
// Permission / audit《C++ 核心引擎接口设计》§13
// ---------------------------------------------------------------------------
WB_API const char* wb_permission_check(const char* userId, const char* boardId, const char* perm);
WB_API const char* wb_audit_query(const char* filterJson);
WB_API const char* wb_audit_export(const char* path);

#ifdef __cplusplus
}  // extern "C"
#endif
