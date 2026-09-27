// radial/radial.cpp — domain "radial" (task package 1.4).
// Owns: core/src/radial.
//
// Ops (《齿轮圆盘交互详细设计》):
//   layout       {cx,cy,size?}        -> full dial geometry for rendering
//   hitTest      {layout,x,y}         -> {hit,zone,index,item,...}
//   stateCreate  {}                   -> {"state":{...}}
//   stateGet     {stateId}            -> {"state":{...}} | NotFound
//   stateUpdate  {stateId,patch}      -> shallow merge, {"state":{...}}
//   rememberTool {stateId,toolId}     -> push into recent (max 3)
//   clearRecent  {stateId}            -> restore default recents
//
// Geometry (design doc §2-4): total diameter 240, collapsed 56.
//   centre 0..28 - inner ring 28..72 (fixed 6 tools, 60 deg each, first at
//   the top / -90 deg, clockwise) - outer ring 72..120 (fixed 8 groups,
//   45 deg each) - sub ring 120..180 (children of the expanded group).
// Angles are degrees from the top, clockwise (0 = up, 90 = right).

#include <algorithm>
#include <cmath>
#include <map>
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

constexpr float kBaseSize = 240.0f;
constexpr float kCollapsedSize = 56.0f;
constexpr float kCenterRadius = 28.0f;
constexpr float kInnerTo = 72.0f;
constexpr float kOuterTo = 120.0f;
constexpr float kSubTo = 180.0f;
constexpr float kInnerStep = 60.0f;
constexpr float kOuterStep = 45.0f;
constexpr int kInnerCount = 6;
constexpr int kOuterCount = 8;
constexpr int kRecentMax = 3;

struct InnerTool {
  const char* id;
  const char* label;
  const char* shortcut;
  const char* icon;
};

const InnerTool kInnerTools[kInnerCount] = {
    {"select", "选择", "V", "mouse"}, {"sticky", "便签", "N", "note"},
    {"shape", "形状", "R", "shape"},  {"pen", "画笔", "P", "pen"},
    {"image", "图片", "I", "image"},  {"more", "更多", "", "more"},
};

struct OuterGroup {
  const char* id;
  const char* label;
  const char* icon;
  std::vector<const char*> children;
};

const OuterGroup kOuterGroups[kOuterCount] = {
    {"select-hand", "选择/手", "mouse", {"选择", "手", "框选", "套索"}},
    {"sticky-text", "便签/文本", "note", {"便签", "文本", "标题", "列表", "引用"}},
    {"shape-connector", "形状/连线", "shape",
     {"矩形", "圆", "菱形", "平行四边形", "箭头", "连线"}},
    {"pen-eraser", "画笔/橡皮", "pen", {"画笔", "荧光笔", "橡皮", "激光笔"}},
    {"image-document", "图片/文档", "image",
     {"图片", "PDF", "文档", "截图", "贴图"}},
    {"mindmap-table", "导图/表格", "mindmap",
     {"思维导图", "表格", "看板", "时间线"}},
    {"function-3d-2d", "函数/3D/2D", "function",
     {"函数渲染", "3D 渲染", "2D 渲染", "坐标系"}},
    {"flowchart-ai", "流程图/AI", "flowchart",
     {"流程图", "泳道图", "状态机", "AI 助手", "设置"}},
};

/// Degrees from the top (0 = up), clockwise, in [0, 360).
float AngleDeg(float dx, float dy) {
  if (std::fabs(dx) < 1e-6f && std::fabs(dy) < 1e-6f) return 0.0f;
  float deg = std::atan2(dx, -dy) * 180.0f / 3.14159265358979323846f;
  if (deg < 0.0f) deg += 360.0f;
  return deg;
}

float ReadNumber(const nlohmann::json& object, const char* key, float fallback) {
  return object.contains(key) && object[key].is_number() ? object[key].get<float>()
                                                         : fallback;
}

nlohmann::json InnerItemJson(int index) {
  const InnerTool& tool = kInnerTools[index];
  const float angle = -90.0f + kInnerStep * static_cast<float>(index);
  nlohmann::json item;
  item["id"] = tool.id;
  item["label"] = tool.label;
  item["shortcut"] = tool.shortcut;
  item["icon"] = tool.icon;
  item["angle"] = angle;
  item["startAngle"] = angle - kInnerStep / 2.0f;
  item["endAngle"] = angle + kInnerStep / 2.0f;
  return item;
}

nlohmann::json OuterItemJson(int index) {
  const OuterGroup& group = kOuterGroups[index];
  const float angle = -90.0f + kOuterStep * static_cast<float>(index);
  nlohmann::json item;
  item["id"] = group.id;
  item["label"] = group.label;
  item["icon"] = group.icon;
  item["angle"] = angle;
  item["startAngle"] = angle - kOuterStep / 2.0f;
  item["endAngle"] = angle + kOuterStep / 2.0f;
  nlohmann::json children = nlohmann::json::array();
  for (const char* child : group.children) children.push_back(child);
  item["children"] = std::move(children);
  return item;
}

struct RadialState {
  std::string id;
  bool collapsed = true;
  bool locked = false;
  std::string corner = "bottom-right";
  std::string activeTool = "select";
  nlohmann::json expandedGroup;         // group id or null
  std::vector<std::string> recent;      // most recent first, max 3
  nlohmann::json position;              // {x, y}
};

nlohmann::json StateToJson(const RadialState& state) {
  nlohmann::json json;
  json["id"] = state.id;
  json["collapsed"] = state.collapsed;
  json["locked"] = state.locked;
  json["corner"] = state.corner;
  json["activeTool"] = state.activeTool;
  json["expandedGroup"] = state.expandedGroup;
  nlohmann::json recent = nlohmann::json::array();
  for (const std::string& tool : state.recent) recent.push_back(tool);
  json["recent"] = std::move(recent);
  json["position"] = state.position;
  json["opacity"] = 0.9;
  return json;
}

class RadialDomain : public DomainHandler {
 public:
  std::string name() const override { return "radial"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "layout") return Layout(args);
    if (op == "hitTest") return HitTest(args);
    if (op == "stateCreate") return StateCreate();
    if (op == "stateGet") return StateGet(args);
    if (op == "stateUpdate") return StateUpdate(args);
    if (op == "rememberTool") return RememberTool(args);
    if (op == "clearRecent") return ClearRecent(args);
    return domainError("NotFound", "unknown radial op: " + op);
  }

 private:
  // --- layout ---------------------------------------------------------------
  std::string Layout(const nlohmann::json& args) {
    const float cx = ReadNumber(args, "cx", 0.0f);
    const float cy = ReadNumber(args, "cy", 0.0f);
    float size = ReadNumber(args, "size", kBaseSize);
    size = std::max(120.0f, std::min(size, 480.0f));
    const float scale = size / kBaseSize;

    nlohmann::json innerItems = nlohmann::json::array();
    for (int i = 0; i < kInnerCount; ++i) innerItems.push_back(InnerItemJson(i));
    nlohmann::json outerItems = nlohmann::json::array();
    for (int i = 0; i < kOuterCount; ++i) outerItems.push_back(OuterItemJson(i));

    nlohmann::json layout;
    layout["cx"] = cx;
    layout["cy"] = cy;
    layout["size"] = size;
    layout["scale"] = scale;
    layout["collapsedSize"] = kCollapsedSize;
    layout["centerRadius"] = kCenterRadius * scale;
    layout["tolerance"] = 8.0f;

    nlohmann::json inner;
    inner["from"] = kCenterRadius * scale;
    inner["to"] = kInnerTo * scale;
    inner["count"] = kInnerCount;
    inner["stepDeg"] = kInnerStep;
    inner["items"] = std::move(innerItems);
    nlohmann::json outer;
    outer["from"] = kInnerTo * scale;
    outer["to"] = kOuterTo * scale;
    outer["count"] = kOuterCount;
    outer["stepDeg"] = kOuterStep;
    outer["items"] = std::move(outerItems);
    nlohmann::json rings;
    rings["inner"] = std::move(inner);
    rings["outer"] = std::move(outer);
    layout["rings"] = std::move(rings);

    nlohmann::json subRing;
    subRing["from"] = kOuterTo * scale;
    subRing["to"] = kSubTo * scale;
    subRing["visible"] = false;
    subRing["group"] = nullptr;
    subRing["groupAngle"] = 0.0f;
    subRing["items"] = nlohmann::json::array();
    layout["subRing"] = std::move(subRing);

    nlohmann::json recent = nlohmann::json::array();
    recent.push_back("select");
    recent.push_back("sticky");
    recent.push_back("shape");
    layout["recent"] = std::move(recent);
    layout["edges"] = nlohmann::json::array({"top", "right", "bottom", "left"});

    return domainOk(nlohmann::json{{"layout", std::move(layout)}}.dump());
  }

  // --- hitTest --------------------------------------------------------------
  std::string HitTest(const nlohmann::json& args) {
    const nlohmann::json layout =
        args.value("layout", nlohmann::json::object());
    const float x = ReadNumber(args, "x", 0.0f);
    const float y = ReadNumber(args, "y", 0.0f);

    const float cx = ReadNumber(layout, "cx", 0.0f);
    const float cy = ReadNumber(layout, "cy", 0.0f);
    float size = ReadNumber(layout, "size", kBaseSize);
    size = std::max(120.0f, std::min(size, 480.0f));
    const float scale = ReadNumber(layout, "scale", size / kBaseSize);
    const float centerRadius =
        ReadNumber(layout, "centerRadius", kCenterRadius * scale);
    const float tolerance = ReadNumber(layout, "tolerance", 8.0f);

    float innerTo = kInnerTo * scale;
    float outerTo = kOuterTo * scale;
    float subTo = kSubTo * scale;
    if (layout.contains("rings") && layout["rings"].is_object()) {
      const nlohmann::json& rings = layout["rings"];
      if (rings.contains("inner") && rings["inner"].is_object()) {
        innerTo = ReadNumber(rings["inner"], "to", innerTo);
      }
      if (rings.contains("outer") && rings["outer"].is_object()) {
        outerTo = ReadNumber(rings["outer"], "to", outerTo);
      }
    }
    bool subVisible = false;
    float groupAngle = 0.0f;
    nlohmann::json subItems = nlohmann::json::array();
    if (layout.contains("subRing") && layout["subRing"].is_object()) {
      const nlohmann::json& sub = layout["subRing"];
      subTo = ReadNumber(sub, "to", subTo);
      subVisible = sub.value("visible", false);
      groupAngle = ReadNumber(sub, "groupAngle", 0.0f);
      if (sub.contains("items") && sub["items"].is_array()) {
        subItems = sub["items"];
      }
    }

    const float dx = x - cx;
    const float dy = y - cy;
    const float dist = std::sqrt(dx * dx + dy * dy);

    nlohmann::json result;
    result["distance"] = dist;

    if (dist <= centerRadius) {
      result["hit"] = true;
      result["zone"] = "center";
      result["action"] = "toggle";
      return domainOk(result.dump());
    }
    const float deg = AngleDeg(dx, dy);
    result["angleDeg"] = deg;

    if (dist <= innerTo) {
      const int index =
          static_cast<int>(std::lround(deg / kInnerStep)) % kInnerCount;
      result["hit"] = true;
      result["zone"] = "inner";
      result["index"] = index;
      result["toolId"] = kInnerTools[index].id;
      result["item"] = InnerItemJson(index);
      return domainOk(result.dump());
    }
    if (dist <= outerTo + tolerance) {
      const int index =
          static_cast<int>(std::lround(deg / kOuterStep)) % kOuterCount;
      result["hit"] = true;
      result["zone"] = "outer";
      result["index"] = index;
      result["groupId"] = kOuterGroups[index].id;
      result["item"] = OuterItemJson(index);
      return domainOk(result.dump());
    }
    if (subVisible && subItems.is_array() && !subItems.empty() &&
        dist <= subTo + tolerance) {
      float local = deg - (groupAngle - kOuterStep);
      if (local < 0.0f) local += 360.0f;
      if (local <= 90.0f) {
        const int count = static_cast<int>(subItems.size());
        const float span = 90.0f / static_cast<float>(count);
        int index = static_cast<int>(std::floor(local / span));
        index = std::max(0, std::min(index, count - 1));
        result["hit"] = true;
        result["zone"] = "sub";
        result["index"] = index;
        result["item"] = subItems[static_cast<std::size_t>(index)];
        return domainOk(result.dump());
      }
    }
    result["hit"] = false;
    return domainOk(result.dump());
  }

  // --- state ----------------------------------------------------------------
  std::string StateCreate() {
    std::lock_guard<std::mutex> lock(mutex_);
    RadialState state;
    state.id = "radial-" + std::to_string(++counter_);
    state.expandedGroup = nullptr;
    state.recent = {"select", "sticky", "shape"};
    state.position = nlohmann::json{{"x", 0}, {"y", 0}};
    states_[state.id] = state;
    return domainOk(nlohmann::json{{"state", StateToJson(state)}}.dump());
  }

  std::string StateGet(const nlohmann::json& args) {
    const std::string stateId = args.value("stateId", std::string());
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = states_.find(stateId);
    if (it == states_.end()) {
      return domainError("NotFound", "unknown radial state: " + stateId);
    }
    return domainOk(nlohmann::json{{"state", StateToJson(it->second)}}.dump());
  }

  std::string StateUpdate(const nlohmann::json& args) {
    const std::string stateId = args.value("stateId", std::string());
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = states_.find(stateId);
    if (it == states_.end()) {
      return domainError("NotFound", "unknown radial state: " + stateId);
    }
    RadialState& state = it->second;
    const nlohmann::json patch = args.value("patch", nlohmann::json::object());
    if (patch.contains("collapsed") && patch["collapsed"].is_boolean()) {
      state.collapsed = patch["collapsed"].get<bool>();
    }
    if (patch.contains("locked") && patch["locked"].is_boolean()) {
      state.locked = patch["locked"].get<bool>();
    }
    if (patch.contains("corner") && patch["corner"].is_string()) {
      state.corner = patch["corner"].get<std::string>();
    }
    if (patch.contains("activeTool") && patch["activeTool"].is_string()) {
      state.activeTool = patch["activeTool"].get<std::string>();
    }
    if (patch.contains("expandedGroup")) {
      state.expandedGroup = patch["expandedGroup"];
    }
    if (patch.contains("position") && patch["position"].is_object()) {
      state.position = patch["position"];
    }
    if (patch.contains("recent") && patch["recent"].is_array()) {
      state.recent.clear();
      for (const auto& tool : patch["recent"]) {
        if (tool.is_string() &&
            static_cast<int>(state.recent.size()) < kRecentMax) {
          state.recent.push_back(tool.get<std::string>());
        }
      }
    }
    return domainOk(nlohmann::json{{"state", StateToJson(state)}}.dump());
  }

  std::string RememberTool(const nlohmann::json& args) {
    const std::string stateId = args.value("stateId", std::string());
    const std::string toolId = args.value("toolId", std::string());
    if (toolId.empty()) {
      return domainError("InvalidArgument", "args.toolId is required");
    }
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = states_.find(stateId);
    if (it == states_.end()) {
      return domainError("NotFound", "unknown radial state: " + stateId);
    }
    RadialState& state = it->second;
    state.recent.erase(
        std::remove(state.recent.begin(), state.recent.end(), toolId),
        state.recent.end());
    state.recent.insert(state.recent.begin(), toolId);
    if (static_cast<int>(state.recent.size()) > kRecentMax) {
      state.recent.resize(kRecentMax);
    }
    nlohmann::json result;
    result["state"] = StateToJson(state);
    result["recent"] = result["state"]["recent"];
    return domainOk(result.dump());
  }

  std::string ClearRecent(const nlohmann::json& args) {
    const std::string stateId = args.value("stateId", std::string());
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = states_.find(stateId);
    if (it == states_.end()) {
      return domainError("NotFound", "unknown radial state: " + stateId);
    }
    it->second.recent = {"select", "sticky", "shape"};
    return domainOk(nlohmann::json{{"state", StateToJson(it->second)}}.dump());
  }

  std::mutex mutex_;
  int counter_ = 0;
  std::map<std::string, RadialState> states_;
};

}  // namespace

WB_REGISTER_DOMAIN(RadialDomain)

}  // namespace wb
