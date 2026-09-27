// annotation/annotation.cpp — domain "annotation" (task package 1.6).
// Owns: core/src/annotation.
//
// Ops (《透明批注模式技术方案》§4-6): enterTransparent, exitTransparent,
// setPenetrate, addStroke, undo, redo, clear, saveToBoard, state.
//
// Two-state machine (穿透态 / 批注态):
//   inactive --enterTransparent{config}--> active(mode=annotate|penetrate)
//   active   --setPenetrate{penetrate}--> active (mode switches)
//   active   --exitTransparent{action}--> inactive
// Exit actions follow the §5.4 dialog: "save" merges the annotation layer
// into the board (as a frame or layer), "discard" drops it, "keep" retains
// it so the next enterTransparent restores the strokes.
//
// The layer is an independent stroke list (pen / highlighter / shape /
// arrow / text); the laser pointer is transient and never stored (§6.1).
// Window transparency / click-through themselves are platform-plugin
// concerns; this domain only owns the core-side state.

#include <algorithm>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "wb/ffi/domain.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

bool IsColorString(const std::string& color) {
  if (color.size() != 7 && color.size() != 9) return false;
  if (color[0] != '#') return false;
  for (std::size_t i = 1; i < color.size(); ++i) {
    const char ch = color[i];
    const bool hex = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') ||
                     (ch >= 'A' && ch <= 'F');
    if (!hex) return false;
  }
  return true;
}

bool IsTool(const std::string& tool) {
  static const char* kTools[] = {"pen",      "highlighter", "eraser",
                                 "shape",    "arrow",       "text",
                                 "laser"};
  for (const char* candidate : kTools) {
    if (tool == candidate) return true;
  }
  return false;
}

nlohmann::json DefaultConfig() {
  return nlohmann::json::parse(
      R"({"opacity":0.3,"alwaysOnTop":true,"saveTarget":"frame",)"
      R"("autoSave":false,"penetrate":false})");
}

/// Shared core-side annotation state; the domain spans UI sessions so a
/// single process-wide state is intentional (protected by mutex).
struct AnnotationState {
  std::mutex mutex;
  bool active = false;
  std::string mode = "none";  // none | annotate | penetrate
  nlohmann::json config = DefaultConfig();
  nlohmann::json strokes = nlohmann::json::array();
  nlohmann::json redoStack = nlohmann::json::array();
};

AnnotationState& State() {
  static AnnotationState state;
  return state;
}

nlohmann::json StateJson(const AnnotationState& state) {
  nlohmann::json result;
  result["active"] = state.active;
  result["mode"] = state.active ? state.mode : "none";
  result["penetrate"] = state.active && state.mode == "penetrate";
  result["strokeCount"] = static_cast<int>(state.strokes.size());
  result["config"] = state.config;
  return result;
}

}  // namespace

class AnnotationDomain : public DomainHandler {
 public:
  std::string name() const override { return "annotation"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "enterTransparent" || op == "enter_transparent" ||
        op == "enter") {
      return EnterTransparent(args);
    }
    if (op == "exitTransparent" || op == "exit_transparent" ||
        op == "exit") {
      return ExitTransparent(args);
    }
    if (op == "setPenetrate" || op == "set_penetrate") {
      return SetPenetrate(args);
    }
    if (op == "addStroke" || op == "add_stroke") return AddStroke(args);
    if (op == "undo") return Undo(args);
    if (op == "redo") return Redo(args);
    if (op == "clear") return Clear(args);
    if (op == "saveToBoard" || op == "save_to_board" || op == "save") {
      return SaveToBoard(args);
    }
    if (op == "state" || op == "status") return StateOp(args);
    return domainError("NotFound", "unknown annotation op: " + op);
  }

 private:
  // --- ops ------------------------------------------------------------------
  std::string EnterTransparent(const nlohmann::json& args) {
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.active) {
      return domainError("Conflict", "transparent mode is already active");
    }
    nlohmann::json config = DefaultConfig();
    if (args.contains("config")) {
      if (!args["config"].is_object()) {
        return domainError("InvalidArgument", "args.config must be an object");
      }
      for (auto it = args["config"].begin(); it != args["config"].end();
           ++it) {
        config[it.key()] = it.value();
      }
    }
    if (!config["opacity"].is_number()) {
      return domainError("InvalidArgument", "config.opacity must be a number");
    }
    const double opacity = config["opacity"].get<double>();
    if (opacity < 0.0 || opacity > 1.0) {
      return domainError("InvalidArgument",
                         "config.opacity must be within [0, 1]");
    }
    const std::string saveTarget = config.value("saveTarget", std::string());
    if (saveTarget != "frame" && saveTarget != "layer") {
      return domainError("InvalidArgument",
                         "config.saveTarget must be frame or layer");
    }
    bool penetrate = false;
    if (config.contains("penetrate")) {
      if (config["penetrate"].is_boolean()) {
        penetrate = config["penetrate"].get<bool>();
      } else if (config["penetrate"].is_number()) {
        penetrate = config["penetrate"].get<double>() != 0.0;
      } else {
        return domainError("InvalidArgument",
                           "config.penetrate must be a boolean");
      }
    }
    state.config = std::move(config);
    state.active = true;
    state.mode = penetrate ? "penetrate" : "annotate";  // default: 批注态
    // "keep" exit retained the previous strokes; they are restored here.
    nlohmann::json result = StateJson(state);
    result["restoredStrokes"] = static_cast<int>(state.strokes.size());
    return domainOk(result.dump());
  }

  std::string ExitTransparent(const nlohmann::json& args) {
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.active) {
      return domainError("Conflict", "transparent mode is not active");
    }
    std::string action = "keep";
    if (args.contains("action")) {
      if (args["action"].is_string()) {
        action = args["action"].get<std::string>();
      } else if (args["action"].is_object()) {
        action = args["action"].value("action", std::string("keep"));
      } else {
        return domainError("InvalidArgument",
                           "args.action must be a string or object");
      }
    }
    if (action != "save" && action != "discard" && action != "keep") {
      return domainError("InvalidArgument",
                         "unknown exit action: " + action +
                             " (save, discard or keep)");
    }
    nlohmann::json result;
    result["action"] = action;
    if (action == "save") {
      result["savedStrokes"] = static_cast<int>(state.strokes.size());
      result["savedAs"] = state.config.value("saveTarget", std::string("frame"));
      state.strokes = nlohmann::json::array();
      state.redoStack = nlohmann::json::array();
    } else if (action == "discard") {
      result["savedStrokes"] = 0;
      result["discardedStrokes"] = static_cast<int>(state.strokes.size());
      state.strokes = nlohmann::json::array();
      state.redoStack = nlohmann::json::array();
    } else {
      result["savedStrokes"] = 0;
      result["keptStrokes"] = static_cast<int>(state.strokes.size());
    }
    state.active = false;
    state.mode = "none";
    result["active"] = false;
    result["strokeCount"] = static_cast<int>(state.strokes.size());
    return domainOk(result.dump());
  }

  std::string SetPenetrate(const nlohmann::json& args) {
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.active) {
      return domainError("Conflict", "transparent mode is not active");
    }
    if (!args.contains("penetrate")) {
      return domainError("InvalidArgument", "args.penetrate is required");
    }
    bool penetrate = false;
    if (args["penetrate"].is_boolean()) {
      penetrate = args["penetrate"].get<bool>();
    } else if (args["penetrate"].is_number()) {
      penetrate = args["penetrate"].get<double>() != 0.0;
    } else {
      return domainError("InvalidArgument",
                         "args.penetrate must be a boolean");
    }
    state.mode = penetrate ? "penetrate" : "annotate";
    return domainOk(StateJson(state).dump());
  }

  std::string AddStroke(const nlohmann::json& args) {
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.active) {
      return domainError("Conflict", "transparent mode is not active");
    }
    if (state.mode != "annotate") {
      return domainError("Conflict",
                         "penetrate mode does not capture annotation input");
    }
    nlohmann::json stroke = args.value("stroke", nlohmann::json::object());
    if (!stroke.is_object() || stroke.empty()) {
      // Allow a shorthand where the stroke fields sit at the top level.
      nlohmann::json shorthand = nlohmann::json::object();
      for (const char* key : {"tool", "color", "width", "opacity", "points"}) {
        if (args.contains(key)) shorthand[key] = args[key];
      }
      if (!shorthand.empty()) stroke = std::move(shorthand);
    }
    if (!stroke.is_object() || stroke.empty()) {
      return domainError("InvalidArgument", "args.stroke is required");
    }
    const std::string tool = stroke.value("tool", std::string());
    if (!IsTool(tool)) {
      return domainError("InvalidArgument",
                         "unknown stroke tool: " +
                             (tool.empty() ? std::string("(missing)") : tool));
    }

    if (tool == "laser") {
      // Transient highlight, never saved (§6.1).
      nlohmann::json result;
      result["saved"] = false;
      result["tool"] = "laser";
      result["strokeCount"] = static_cast<int>(state.strokes.size());
      return domainOk(result.dump());
    }

    const std::string color = stroke.value("color", std::string());
    if (!IsColorString(color)) {
      return domainError("InvalidArgument",
                         "stroke.color must be #RRGGBB or #AARRGGBB");
    }
    const double width = stroke.value("width", 2.0);
    if (width <= 0.0) {
      return domainError("InvalidArgument", "stroke.width must be positive");
    }
    const double opacity = stroke.value("opacity", 1.0);
    if (opacity < 0.0 || opacity > 1.0) {
      return domainError("InvalidArgument",
                         "stroke.opacity must be within [0, 1]");
    }
    if (!stroke.contains("points") || !stroke["points"].is_array() ||
        stroke["points"].empty()) {
      return domainError("InvalidArgument", "stroke.points is required");
    }
    for (const nlohmann::json& point : stroke["points"]) {
      if (!point.is_object() || !point.contains("x") || !point.contains("y") ||
          !point["x"].is_number() || !point["y"].is_number()) {
        return domainError("InvalidArgument",
                           "each point needs numeric x and y");
      }
    }

    if (tool == "eraser") {
      // The eraser removes the last stroke instead of storing itself.
      if (state.strokes.empty()) {
        return domainError("InvalidArgument", "nothing to erase");
      }
      state.strokes.erase(state.strokes.size() - 1);
      state.redoStack = nlohmann::json::array();
      nlohmann::json result;
      result["erased"] = true;
      result["saved"] = false;
      result["strokeCount"] = static_cast<int>(state.strokes.size());
      return domainOk(result.dump());
    }

    nlohmann::json stored;
    stored["tool"] = tool;
    stored["color"] = color;
    stored["width"] = width;
    stored["opacity"] = opacity;
    stored["points"] = stroke["points"];
    state.strokes.push_back(std::move(stored));
    state.redoStack = nlohmann::json::array();

    nlohmann::json result;
    result["saved"] = true;
    result["tool"] = tool;
    result["strokeCount"] = static_cast<int>(state.strokes.size());
    return domainOk(result.dump());
  }

  std::string Undo(const nlohmann::json& args) {
    (void)args;
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.strokes.empty()) {
      return domainError("InvalidArgument", "nothing to undo");
    }
    state.redoStack.push_back(state.strokes.back());
    state.strokes.erase(state.strokes.size() - 1);
    nlohmann::json result;
    result["undone"] = true;
    result["strokeCount"] = static_cast<int>(state.strokes.size());
    return domainOk(result.dump());
  }

  std::string Redo(const nlohmann::json& args) {
    (void)args;
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.redoStack.empty()) {
      return domainError("InvalidArgument", "nothing to redo");
    }
    state.strokes.push_back(state.redoStack.back());
    state.redoStack.erase(state.redoStack.size() - 1);
    nlohmann::json result;
    result["redone"] = true;
    result["strokeCount"] = static_cast<int>(state.strokes.size());
    return domainOk(result.dump());
  }

  std::string Clear(const nlohmann::json& args) {
    (void)args;
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const int removed = static_cast<int>(state.strokes.size());
    state.strokes = nlohmann::json::array();
    state.redoStack = nlohmann::json::array();
    nlohmann::json result;
    result["clearedStrokes"] = removed;
    result["strokeCount"] = 0;
    return domainOk(result.dump());
  }

  std::string SaveToBoard(const nlohmann::json& args) {
    (void)args;
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const int saved = static_cast<int>(state.strokes.size());
    state.strokes = nlohmann::json::array();
    state.redoStack = nlohmann::json::array();
    nlohmann::json result;
    result["savedStrokes"] = saved;
    result["savedAs"] = state.config.value("saveTarget", std::string("frame"));
    result["strokeCount"] = 0;
    return domainOk(result.dump());
  }

  std::string StateOp(const nlohmann::json& args) {
    (void)args;
    AnnotationState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    return domainOk(StateJson(state).dump());
  }
};

WB_REGISTER_DOMAIN(AnnotationDomain)

}  // namespace wb
