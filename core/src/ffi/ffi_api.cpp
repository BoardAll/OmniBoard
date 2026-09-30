// ffi/ffi_api.cpp — C ABI export surface (task package 1.1).
// Owns: core/src/ffi.
//
// Every wb_* function forwards to a domain handler through the JSON mediator
// (wb/ffi/domain.h). Returned strings are heap copies to be released with
// wb_free(). Domain/op mapping is documented per section below.

#include <cstdlib>
#include <cstring>
#include <string>

#include <nlohmann/json.hpp>

#include "wb/base/log.h"
#include "wb/ffi/domain.h"
#include "wb/wb.h"

namespace {

constexpr const char* kVersion = "1.0.0";

std::string J(const char* s) { return s != nullptr ? std::string(s) : std::string(); }

// Allocates a heap copy so the host releases it with wb_free().
const char* Handoff(const std::string& s) {
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (out == nullptr) {
    return nullptr;
  }
  std::memcpy(out, s.c_str(), s.size() + 1);
  return out;
}

// Replaces nlohmann "discarded" values (produced by non-throwing parse of
// malformed host input) with null so the emitted JSON stays valid.
void Sanitize(nlohmann::json& j) {
  if (j.is_discarded()) {
    j = nullptr;
    return;
  }
  if (j.is_object()) {
    for (auto it = j.begin(); it != j.end(); ++it) {
      Sanitize(it.value());
    }
  } else if (j.is_array()) {
    for (auto& item : j) {
      Sanitize(item);
    }
  }
}

std::string Call(const char* domain, const char* op, const nlohmann::json& args) {
  nlohmann::json sanitized = args;
  Sanitize(sanitized);
  return wb::invokeDomain(domain, op, sanitized.dump());
}

}  // namespace

extern "C" {

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
WB_API int wb_init(const char* configJson) {
  const std::string config = J(configJson);
  if (!config.empty()) {
    const auto parsed = nlohmann::json::parse(config, nullptr, false);
    if (parsed.is_discarded()) {
      wb::Logger::instance().error("wb_init", "config is not valid JSON");
      return 1;
    }
    if (parsed.is_object() && parsed.contains("logLevel") &&
        parsed["logLevel"].is_string()) {
      const std::string level = parsed["logLevel"].get<std::string>();
      wb::Logger& logger = wb::Logger::instance();
      if (level == "trace") logger.setLevel(wb::LogLevel::Trace);
      else if (level == "debug") logger.setLevel(wb::LogLevel::Debug);
      else if (level == "info") logger.setLevel(wb::LogLevel::Info);
      else if (level == "warn") logger.setLevel(wb::LogLevel::Warn);
      else if (level == "error") logger.setLevel(wb::LogLevel::Error);
      else if (level == "fatal") logger.setLevel(wb::LogLevel::Fatal);
    }
  }
  wb::Logger::instance().info("wb", std::string("core initialized v") + kVersion);
  return 0;
}

WB_API void wb_shutdown() {
  wb::Logger::instance().info("wb", "core shutdown");
  wb::Logger::instance().setSink(nullptr);
}

WB_API const char* wb_version() { return Handoff(kVersion); }

WB_API void wb_free(const char* ptr) { std::free(const_cast<char*>(ptr)); }

// ---------------------------------------------------------------------------
// Board — domain "board"
// ---------------------------------------------------------------------------
WB_API uint64_t wb_create_board(const char* json) {
  nlohmann::json args;
  if (json != nullptr && *json != '\0') {
    args = nlohmann::json::parse(json, nullptr, false);
    if (args.is_discarded() || !args.is_object()) {
      args = nlohmann::json::object();
    }
  }
  const std::string response = Call("board", "create", args);
  const auto parsed = nlohmann::json::parse(response, nullptr, false);
  if (parsed.is_discarded() || !parsed.value("ok", false)) {
    return 0;
  }
  const auto& result = parsed["result"];
  if (!result.is_object() || !result.contains("handle") || !result["handle"].is_number()) {
    return 0;
  }
  return result["handle"].get<uint64_t>();
}

WB_API void wb_destroy_board(uint64_t handle) {
  nlohmann::json args;
  args["handle"] = handle;
  Call("board", "destroy", args);
}

WB_API const char* wb_board_get(uint64_t handle) {
  nlohmann::json args;
  args["handle"] = handle;
  return Handoff(Call("board", "get", args));
}

// ---------------------------------------------------------------------------
// Command — domain "command" / "tool"
// ---------------------------------------------------------------------------
WB_API const char* wb_execute_command(uint64_t handle, const char* cmdJson) {
  nlohmann::json args;
  args["handle"] = handle;
  if (cmdJson != nullptr && *cmdJson != '\0') {
    args["command"] = nlohmann::json::parse(cmdJson, nullptr, false);
  }
  return Handoff(Call("command", "execute", args));
}

WB_API const char* wb_execute_tool(const char* toolId, const char* argsJson) {
  nlohmann::json args;
  args["toolId"] = J(toolId);
  if (argsJson != nullptr && *argsJson != '\0') {
    args["args"] = nlohmann::json::parse(argsJson, nullptr, false);
  }
  return Handoff(Call("tool", "execute", args));
}

// ---------------------------------------------------------------------------
// Render — domain "render" / "render3d"
// ---------------------------------------------------------------------------
WB_API const char* wb_get_display_list(uint64_t handle, int layer) {
  nlohmann::json args;
  args["handle"] = handle;
  args["layer"] = layer;
  return Handoff(Call("render", "getDisplayList", args));
}

WB_API const char* wb_render_display_list(const char* pageId, int layer) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["layer"] = layer;
  return Handoff(Call("render", "renderDisplayList", args));
}

WB_API const char* wb_render_dirty(const char* pageId, const char* dirtyJson) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["dirty"] = dirtyJson != nullptr && *dirtyJson != '\0'
                      ? nlohmann::json::parse(dirtyJson, nullptr, false)
                      : nlohmann::json::object();
  return Handoff(Call("render", "renderDirty", args));
}

WB_API const char* wb_render_3d(uint64_t handle, const char* elementId, int width,
                                int height) {
  nlohmann::json args;
  args["handle"] = handle;
  args["elementId"] = J(elementId);
  args["width"] = width;
  args["height"] = height;
  return Handoff(Call("render3d", "render", args));
}

WB_API const char* wb_render_thumbnail(const char* pageId, int width, int height) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["width"] = width;
  args["height"] = height;
  return Handoff(Call("render", "thumbnail", args));
}

WB_API const char* wb_render_cache_stats() {
  return Handoff(Call("render", "cacheStats", nlohmann::json::object()));
}

WB_API const char* wb_render_cache_clear() {
  return Handoff(Call("render", "cacheClear", nlohmann::json::object()));
}

WB_API const char* wb_render_perf_stats() {
  return Handoff(Call("render", "perfStats", nlohmann::json::object()));
}

// ---------------------------------------------------------------------------
// Tools — domain "tool"
// ---------------------------------------------------------------------------
WB_API const char* wb_tool_list() {
  return Handoff(Call("tool", "list", nlohmann::json::object()));
}

WB_API const char* wb_tool_get(const char* toolId) {
  nlohmann::json args;
  args["toolId"] = J(toolId);
  return Handoff(Call("tool", "get", args));
}

// ---------------------------------------------------------------------------
// Page — domain "page"
// ---------------------------------------------------------------------------
WB_API const char* wb_page_list(const char* boardId) {
  nlohmann::json args;
  args["boardId"] = J(boardId);
  return Handoff(Call("page", "list", args));
}

WB_API const char* wb_page_create(const char* boardId, const char* json) {
  nlohmann::json args;
  args["boardId"] = J(boardId);
  if (json != nullptr && *json != '\0') {
    args["page"] = nlohmann::json::parse(json, nullptr, false);
  }
  return Handoff(Call("page", "create", args));
}

WB_API const char* wb_page_duplicate(const char* pageId) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  return Handoff(Call("page", "duplicate", args));
}

WB_API const char* wb_page_delete(const char* pageId) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  return Handoff(Call("page", "delete", args));
}

WB_API const char* wb_page_move(const char* pageId, int newIndex) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["newIndex"] = newIndex;
  return Handoff(Call("page", "move", args));
}

WB_API const char* wb_page_rename(const char* pageId, const char* name) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["name"] = J(name);
  return Handoff(Call("page", "rename", args));
}

WB_API const char* wb_page_set_background(const char* pageId, const char* bgJson) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["background"] = bgJson != nullptr && *bgJson != '\0'
                           ? nlohmann::json::parse(bgJson, nullptr, false)
                           : nlohmann::json::object();
  return Handoff(Call("page", "setBackground", args));
}

WB_API const char* wb_page_lock(const char* pageId, int locked) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["locked"] = locked != 0;
  return Handoff(Call("page", "lock", args));
}

WB_API const char* wb_page_hide(const char* pageId, int hidden) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["hidden"] = hidden != 0;
  return Handoff(Call("page", "hide", args));
}

// ---------------------------------------------------------------------------
// Element — domain "element"
// ---------------------------------------------------------------------------
WB_API const char* wb_element_create(const char* pageId, const char* json) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  if (json != nullptr && *json != '\0') {
    args["element"] = nlohmann::json::parse(json, nullptr, false);
  }
  return Handoff(Call("element", "create", args));
}

WB_API const char* wb_element_update(const char* elementId, const char* json) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  if (json != nullptr && *json != '\0') {
    args["patch"] = nlohmann::json::parse(json, nullptr, false);
  }
  return Handoff(Call("element", "update", args));
}

WB_API const char* wb_element_delete(const char* elementId) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  return Handoff(Call("element", "delete", args));
}

WB_API const char* wb_element_list(const char* pageId) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  return Handoff(Call("element", "list", args));
}

WB_API const char* wb_element_batch(const char* pageId, const char* opsJson) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  args["ops"] = opsJson != nullptr && *opsJson != '\0'
                    ? nlohmann::json::parse(opsJson, nullptr, false)
                    : nlohmann::json::array();
  return Handoff(Call("element", "batch", args));
}

// ---------------------------------------------------------------------------
// Toolbar — domain "toolbar"
// ---------------------------------------------------------------------------
WB_API const char* wb_toolbar_list() {
  return Handoff(Call("toolbar", "list", nlohmann::json::object()));
}

WB_API const char* wb_toolbar_context(const char* elementIdsJson) {
  nlohmann::json args;
  args["elementIds"] = elementIdsJson != nullptr && *elementIdsJson != '\0'
                           ? nlohmann::json::parse(elementIdsJson, nullptr, false)
                           : nlohmann::json::array();
  return Handoff(Call("toolbar", "context", args));
}

WB_API const char* wb_toolbar_invoke(const char* toolId, const char* argsJson) {
  nlohmann::json args;
  args["toolId"] = J(toolId);
  if (argsJson != nullptr && *argsJson != '\0') {
    args["args"] = nlohmann::json::parse(argsJson, nullptr, false);
  }
  return Handoff(Call("toolbar", "invoke", args));
}

// ---------------------------------------------------------------------------
// Radial menu — domain "radial"
// ---------------------------------------------------------------------------
WB_API const char* wb_radial_layout(float cx, float cy, float size) {
  nlohmann::json args;
  args["cx"] = cx;
  args["cy"] = cy;
  args["size"] = size;
  return Handoff(Call("radial", "layout", args));
}

WB_API const char* wb_radial_hit_test(const char* layoutJson, float x, float y) {
  nlohmann::json args;
  args["layout"] = layoutJson != nullptr && *layoutJson != '\0'
                       ? nlohmann::json::parse(layoutJson, nullptr, false)
                       : nlohmann::json::object();
  args["x"] = x;
  args["y"] = y;
  return Handoff(Call("radial", "hitTest", args));
}

WB_API const char* wb_radial_state_create() {
  return Handoff(Call("radial", "stateCreate", nlohmann::json::object()));
}

WB_API const char* wb_radial_state_get(const char* stateId) {
  nlohmann::json args;
  args["stateId"] = J(stateId);
  return Handoff(Call("radial", "stateGet", args));
}

// ---------------------------------------------------------------------------
// 3D — domain "render3d"
// ---------------------------------------------------------------------------
WB_API const char* wb_3d_create(const char* pageId, const char* json) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  if (json != nullptr && *json != '\0') {
    args["element"] = nlohmann::json::parse(json, nullptr, false);
  }
  return Handoff(Call("render3d", "create", args));
}

WB_API const char* wb_3d_render(const char* elementId, int width, int height) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["width"] = width;
  args["height"] = height;
  return Handoff(Call("render3d", "render", args));
}

WB_API const char* wb_3d_pick_surface(const char* elementId, float x, float y) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["x"] = x;
  args["y"] = y;
  return Handoff(Call("render3d", "pickSurface", args));
}

WB_API const char* wb_3d_set_face_color(const char* elementId, int faceId,
                                        const char* color) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["faceId"] = faceId;
  args["color"] = J(color);
  return Handoff(Call("render3d", "setFaceColor", args));
}

WB_API const char* wb_3d_set_material(const char* elementId, const char* matJson) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["material"] = matJson != nullptr && *matJson != '\0'
                         ? nlohmann::json::parse(matJson, nullptr, false)
                         : nlohmann::json::object();
  return Handoff(Call("render3d", "setMaterial", args));
}

WB_API const char* wb_3d_set_light(const char* elementId, const char* lightJson) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["light"] = lightJson != nullptr && *lightJson != '\0'
                      ? nlohmann::json::parse(lightJson, nullptr, false)
                      : nlohmann::json::object();
  return Handoff(Call("render3d", "setLight", args));
}

WB_API const char* wb_3d_transform(const char* elementId, const char* transformJson) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["transform"] = transformJson != nullptr && *transformJson != '\0'
                          ? nlohmann::json::parse(transformJson, nullptr, false)
                          : nlohmann::json::object();
  return Handoff(Call("render3d", "transform", args));
}

WB_API const char* wb_3d_export(const char* elementId, const char* format) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["format"] = J(format);
  return Handoff(Call("render3d", "export", args));
}

// ---------------------------------------------------------------------------
// Function plot — domain "function"
// ---------------------------------------------------------------------------
WB_API const char* wb_function_create(const char* pageId, const char* json) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  if (json != nullptr && *json != '\0') {
    args["element"] = nlohmann::json::parse(json, nullptr, false);
  }
  return Handoff(Call("function", "create", args));
}

WB_API const char* wb_function_set_style(const char* elementId, const char* styleJson) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["style"] = styleJson != nullptr && *styleJson != '\0'
                      ? nlohmann::json::parse(styleJson, nullptr, false)
                      : nlohmann::json::object();
  return Handoff(Call("function", "setStyle", args));
}

WB_API const char* wb_function_add(const char* elementId, const char* expr) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["expression"] = J(expr);
  return Handoff(Call("function", "add", args));
}

WB_API const char* wb_function_analyze(const char* elementId, const char* type) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["type"] = J(type);
  return Handoff(Call("function", "analyze", args));
}

WB_API const char* wb_function_export(const char* elementId, const char* format) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["format"] = J(format);
  return Handoff(Call("function", "export", args));
}

// ---------------------------------------------------------------------------
// Flowchart — domain "flowchart"
// ---------------------------------------------------------------------------
WB_API const char* wb_flowchart_create(const char* pageId, const char* json) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  if (json != nullptr && *json != '\0') {
    args["element"] = nlohmann::json::parse(json, nullptr, false);
  }
  return Handoff(Call("flowchart", "create", args));
}

WB_API const char* wb_flowchart_auto_layout(const char* flowchartId,
                                            const char* optionsJson) {
  nlohmann::json args;
  args["flowchartId"] = J(flowchartId);
  if (optionsJson != nullptr && *optionsJson != '\0') {
    args["options"] = nlohmann::json::parse(optionsJson, nullptr, false);
  }
  return Handoff(Call("flowchart", "autoLayout", args));
}

WB_API const char* wb_flowchart_to_swimlane(const char* flowchartId, int orientation) {
  nlohmann::json args;
  args["flowchartId"] = J(flowchartId);
  args["orientation"] = orientation;
  return Handoff(Call("flowchart", "toSwimlane", args));
}

WB_API const char* wb_flowchart_label_branches(const char* flowchartId) {
  nlohmann::json args;
  args["flowchartId"] = J(flowchartId);
  return Handoff(Call("flowchart", "labelBranches", args));
}

// ---------------------------------------------------------------------------
// 2D rendering — domain "render2d"
// ---------------------------------------------------------------------------
WB_API const char* wb_render_2d_create(const char* pageId, const char* json) {
  nlohmann::json args;
  args["pageId"] = J(pageId);
  if (json != nullptr && *json != '\0') {
    args["element"] = nlohmann::json::parse(json, nullptr, false);
  }
  return Handoff(Call("render2d", "create", args));
}

WB_API const char* wb_render_2d_set_style(const char* elementId, const char* styleJson) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  args["style"] = styleJson != nullptr && *styleJson != '\0'
                      ? nlohmann::json::parse(styleJson, nullptr, false)
                      : nlohmann::json::object();
  return Handoff(Call("render2d", "setStyle", args));
}

WB_API const char* wb_render_2d_annotate(const char* elementId, const char* json) {
  nlohmann::json args;
  args["elementId"] = J(elementId);
  if (json != nullptr && *json != '\0') {
    args["annotation"] = nlohmann::json::parse(json, nullptr, false);
  }
  return Handoff(Call("render2d", "annotate", args));
}

// ---------------------------------------------------------------------------
// Sidebar — domain "sidebar"
// ---------------------------------------------------------------------------
WB_API const char* wb_sidebar_toggle(const char* stateId) {
  nlohmann::json args;
  args["stateId"] = J(stateId);
  return Handoff(Call("sidebar", "toggle", args));
}

WB_API const char* wb_sidebar_set_width(const char* stateId, int width) {
  nlohmann::json args;
  args["stateId"] = J(stateId);
  args["width"] = width;
  return Handoff(Call("sidebar", "setWidth", args));
}

// ---------------------------------------------------------------------------
// Theme — domain "theme"
// ---------------------------------------------------------------------------
WB_API const char* wb_theme_load(const char* themeJson) {
  nlohmann::json args;
  if (themeJson != nullptr && *themeJson != '\0') {
    args["theme"] = nlohmann::json::parse(themeJson, nullptr, false);
  }
  return Handoff(Call("theme", "load", args));
}

WB_API const char* wb_theme_current() {
  return Handoff(Call("theme", "current", nlohmann::json::object()));
}

WB_API const char* wb_theme_list() {
  return Handoff(Call("theme", "list", nlohmann::json::object()));
}

// ---------------------------------------------------------------------------
// Annotation — domain "annotation"
// ---------------------------------------------------------------------------
WB_API const char* wb_annotate_enter_transparent(const char* configJson) {
  nlohmann::json args;
  if (configJson != nullptr && *configJson != '\0') {
    args["config"] = nlohmann::json::parse(configJson, nullptr, false);
  }
  return Handoff(Call("annotation", "enterTransparent", args));
}

WB_API const char* wb_annotate_exit_transparent(const char* actionJson) {
  nlohmann::json args;
  if (actionJson != nullptr && *actionJson != '\0') {
    args["action"] = nlohmann::json::parse(actionJson, nullptr, false);
  }
  return Handoff(Call("annotation", "exitTransparent", args));
}

WB_API const char* wb_annotate_set_penetrate(int penetrate) {
  nlohmann::json args;
  args["penetrate"] = penetrate != 0;
  return Handoff(Call("annotation", "setPenetrate", args));
}

// ---------------------------------------------------------------------------
// AI sessions — domain "ai"
// ---------------------------------------------------------------------------
WB_API const char* wb_ai_session_create(const char* boardId, const char* userId) {
  nlohmann::json args;
  args["boardId"] = J(boardId);
  args["userId"] = J(userId);
  return Handoff(Call("ai", "sessionCreate", args));
}

WB_API const char* wb_ai_session_close(const char* sessionId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  return Handoff(Call("ai", "sessionClose", args));
}

WB_API const char* wb_ai_session_get(const char* sessionId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  return Handoff(Call("ai", "sessionGet", args));
}

WB_API const char* wb_ai_send_message(const char* sessionId, const char* message) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  args["message"] = J(message);
  return Handoff(Call("ai", "sendMessage", args));
}

WB_API const char* wb_ai_send_audio(const char* sessionId, const char* audioData) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  args["audioData"] = J(audioData);
  return Handoff(Call("ai", "sendAudio", args));
}

WB_API const char* wb_ai_list_messages(const char* sessionId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  return Handoff(Call("ai", "listMessages", args));
}

WB_API const char* wb_ai_execute_tool_call(const char* sessionId, const char* toolCallId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  args["toolCallId"] = J(toolCallId);
  return Handoff(Call("ai", "executeToolCall", args));
}

WB_API const char* wb_ai_preview_tool_call(const char* sessionId, const char* toolCallId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  args["toolCallId"] = J(toolCallId);
  return Handoff(Call("ai", "previewToolCall", args));
}

WB_API const char* wb_ai_cancel_tool_call(const char* sessionId, const char* toolCallId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  args["toolCallId"] = J(toolCallId);
  return Handoff(Call("ai", "cancelToolCall", args));
}

WB_API const char* wb_ai_set_context(const char* sessionId, const char* contextJson) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  if (contextJson != nullptr && *contextJson != '\0') {
    args["context"] = nlohmann::json::parse(contextJson, nullptr, false);
  }
  return Handoff(Call("ai", "setContext", args));
}

// ---------------------------------------------------------------------------
// MCP server — domain "mcp"
// ---------------------------------------------------------------------------
WB_API const char* wb_mcp_start(const char* configJson) {
  nlohmann::json args;
  if (configJson != nullptr && *configJson != '\0') {
    args["config"] = nlohmann::json::parse(configJson, nullptr, false);
  }
  return Handoff(Call("mcp", "start", args));
}

WB_API const char* wb_mcp_stop() {
  return Handoff(Call("mcp", "stop", nlohmann::json::object()));
}

WB_API const char* wb_mcp_is_running() {
  return Handoff(Call("mcp", "isRunning", nlohmann::json::object()));
}

WB_API const char* wb_mcp_handle_request(const char* requestJson, const char* sessionId) {
  nlohmann::json args;
  args["request"] = requestJson != nullptr && *requestJson != '\0'
                        ? nlohmann::json::parse(requestJson, nullptr, false)
                        : nlohmann::json::object();
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "handleRequest", args));
}

WB_API const char* wb_mcp_session_create(const char* token) {
  nlohmann::json args;
  args["token"] = J(token);
  return Handoff(Call("mcp", "sessionCreate", args));
}

WB_API const char* wb_mcp_session_get(const char* sessionId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "sessionGet", args));
}

WB_API const char* wb_mcp_session_close(const char* sessionId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "sessionClose", args));
}

WB_API const char* wb_mcp_list_tools(const char* sessionId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "listTools", args));
}

WB_API const char* wb_mcp_call_tool(const char* toolName, const char* argsJson,
                                    const char* sessionId) {
  nlohmann::json args;
  args["toolName"] = J(toolName);
  args["args"] = argsJson != nullptr && *argsJson != '\0'
                     ? nlohmann::json::parse(argsJson, nullptr, false)
                     : nlohmann::json::object();
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "callTool", args));
}

WB_API const char* wb_mcp_list_resources(const char* sessionId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "listResources", args));
}

WB_API const char* wb_mcp_read_resource(const char* uri, const char* sessionId) {
  nlohmann::json args;
  args["uri"] = J(uri);
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "readResource", args));
}

WB_API const char* wb_mcp_list_prompts(const char* sessionId) {
  nlohmann::json args;
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "listPrompts", args));
}

WB_API const char* wb_mcp_get_prompt(const char* name, const char* argsJson,
                                     const char* sessionId) {
  nlohmann::json args;
  args["name"] = J(name);
  args["args"] = argsJson != nullptr && *argsJson != '\0'
                     ? nlohmann::json::parse(argsJson, nullptr, false)
                     : nlohmann::json::object();
  args["sessionId"] = J(sessionId);
  return Handoff(Call("mcp", "getPrompt", args));
}

WB_API const char* wb_mcp_audit_query(const char* filterJson) {
  nlohmann::json args;
  if (filterJson != nullptr && *filterJson != '\0') {
    args["filter"] = nlohmann::json::parse(filterJson, nullptr, false);
  }
  return Handoff(Call("mcp", "auditQuery", args));
}

WB_API const char* wb_mcp_audit_export(const char* path) {
  nlohmann::json args;
  args["path"] = J(path);
  return Handoff(Call("mcp", "auditExport", args));
}

// ---------------------------------------------------------------------------
// Sync — domain "sync"
// ---------------------------------------------------------------------------
WB_API const char* wb_sync_connect(const char* endpoint, const char* token) {
  nlohmann::json args;
  args["endpoint"] = J(endpoint);
  args["token"] = J(token);
  return Handoff(Call("sync", "connect", args));
}

WB_API const char* wb_sync_disconnect() {
  return Handoff(Call("sync", "disconnect", nlohmann::json::object()));
}

WB_API const char* wb_sync_status() {
  return Handoff(Call("sync", "status", nlohmann::json::object()));
}

WB_API const char* wb_sync_set_offline(int offline) {
  nlohmann::json args;
  args["offline"] = offline != 0;
  return Handoff(Call("sync", "setOffline", args));
}

// ---------------------------------------------------------------------------
// M1 collaboration data plane — thin forwards, see wb.h (Sync / CRDT).
// ---------------------------------------------------------------------------
WB_API const char* wb_sync_join(const char* boardId, const char* pageId) {
  nlohmann::json args;
  args["boardId"] = J(boardId);
  if (pageId != nullptr && *pageId != '\0') {
    args["pageId"] = J(pageId);
  }
  return Handoff(Call("sync", "join", args));
}

WB_API const char* wb_sync_send_operation(const char* opJson) {
  nlohmann::json args;
  if (opJson != nullptr && *opJson != '\0') {
    args["op"] = nlohmann::json::parse(opJson, nullptr, false);
  }
  return Handoff(Call("sync", "sendOperation", args));
}

WB_API const char* wb_sync_flush() {
  return Handoff(Call("sync", "sync", nlohmann::json::object()));
}

WB_API const char* wb_sync_events() {
  return Handoff(Call("sync", "events", nlohmann::json::object()));
}

WB_API const char* wb_sync_send_preview(const char* previewJson) {
  nlohmann::json args;
  if (previewJson != nullptr && *previewJson != '\0') {
    args["preview"] = nlohmann::json::parse(previewJson, nullptr, false);
  }
  return Handoff(Call("sync", "sendPreview", args));
}

WB_API const char* wb_crdt_create(const char* docId, const char* actor) {
  nlohmann::json args;
  if (docId != nullptr && *docId != '\0') {
    args["docId"] = J(docId);
  }
  if (actor != nullptr && *actor != '\0') {
    args["actor"] = J(actor);
  }
  return Handoff(Call("crdt", "create", args));
}

WB_API const char* wb_crdt_apply_local(const char* docId, const char* opJson) {
  nlohmann::json args;
  args["docId"] = J(docId);
  if (opJson != nullptr && *opJson != '\0') {
    args["operation"] = nlohmann::json::parse(opJson, nullptr, false);
  }
  return Handoff(Call("crdt", "applyLocal", args));
}

// ---------------------------------------------------------------------------
// Permission / audit — domains "permission" / "audit"
// ---------------------------------------------------------------------------
WB_API const char* wb_permission_check(const char* userId, const char* boardId,
                                       const char* perm) {
  nlohmann::json args;
  args["userId"] = J(userId);
  args["boardId"] = J(boardId);
  args["permission"] = J(perm);
  return Handoff(Call("permission", "check", args));
}

WB_API const char* wb_audit_query(const char* filterJson) {
  nlohmann::json args;
  if (filterJson != nullptr && *filterJson != '\0') {
    args["filter"] = nlohmann::json::parse(filterJson, nullptr, false);
  }
  return Handoff(Call("audit", "query", args));
}

WB_API const char* wb_audit_export(const char* path) {
  nlohmann::json args;
  args["path"] = J(path);
  return Handoff(Call("audit", "export", args));
}

}  // extern "C"
