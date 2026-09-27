// background/background.cpp — domain "background" (task package 1.4).
// Owns: core/src/background.
//
// Ops (《主题与背景系统设计》§6-7):
//   list {}                     -> {"presets":[...], "count":N}
//   set  {pageId, preset}       -> apply preset id to a page
//        {pageId, background}   -> apply raw background object
//        -> {"pageId", "background":{...}}
//   get  {pageId}               -> {"pageId", "background":{...}}
//
// A page's background value is stored verbatim on the SceneStore PageRec
// (same slot the page domain's setBackground writes), so the background and
// page domains stay interchangeable. Enumeration carries 11 presets: the 9
// whiteboard presets from the design doc plus the two dark pattern variants
// called for by the extensibility rule (dark dot / dark grid).

#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../model/scene_store.h"
#include "wb/ffi/domain.h"

namespace wb {
namespace {

using scene::SceneStore;

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

struct Preset {
  const char* id;
  const char* name;
  const char* pattern;  // solid | dot | grid | lined | squared
  const char* baseColor;
  const char* patternColor;
  int spacing;
  bool dark;
};

const Preset kPresets[] = {
    {"whiteboard", "白板", "solid", "#FFFFFF", "", 0, false},
    {"light-gray", "浅灰白板", "solid", "#F5F6F8", "", 0, false},
    {"dot", "点阵白板", "dot", "#FFFFFF", "#D0D5DD", 20, false},
    {"grid", "网格白板", "grid", "#FFFFFF", "#E4E7EC", 25, false},
    {"blackboard", "黑板", "solid", "#1A1D21", "", 0, true},
    {"greenboard", "绿板", "solid", "#1E3A2F", "", 0, true},
    {"cream", "米黄护眼", "solid", "#FBF3E4", "", 0, false},
    {"lined", "横线纸", "lined", "#FFFFFF", "#D9DEE8", 28, false},
    {"squared", "方格纸", "squared", "#FFFFFF", "#D9DEE8", 24, false},
    {"dark-dot", "深色点阵", "dot", "#121417", "#2A2F3A", 20, true},
    {"dark-grid", "深色网格", "grid", "#121417", "#2A2F3A", 25, true},
};

constexpr std::size_t kPresetCount = sizeof(kPresets) / sizeof(kPresets[0]);

nlohmann::json PresetToJson(const Preset& preset) {
  nlohmann::json item;
  item["id"] = preset.id;
  item["name"] = preset.name;
  item["pattern"] = preset.pattern;
  item["baseColor"] = preset.baseColor;
  item["patternColor"] = preset.patternColor;
  item["spacing"] = preset.spacing;
  item["dark"] = preset.dark;
  return item;
}

const Preset* FindPreset(const std::string& id) {
  for (const Preset& preset : kPresets) {
    if (id == preset.id) return &preset;
  }
  return nullptr;
}

class BackgroundDomain : public DomainHandler {
 public:
  std::string name() const override { return "background"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "list") return List();
    if (op == "set") return Set(args);
    if (op == "get") return Get(args);
    return domainError("NotFound", "unknown background op: " + op);
  }

 private:
  std::string List() {
    nlohmann::json presets = nlohmann::json::array();
    for (const Preset& preset : kPresets) {
      presets.push_back(PresetToJson(preset));
    }
    nlohmann::json result;
    result["presets"] = std::move(presets);
    result["count"] = static_cast<int>(kPresetCount);
    return domainOk(result.dump());
  }

  std::string Set(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    scene::PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    if (page->locked) {
      return domainError("Conflict", "page is locked: " + pageId);
    }
    nlohmann::json background;
    if (args.contains("preset") && args["preset"].is_string()) {
      const Preset* preset = FindPreset(args["preset"].get<std::string>());
      if (preset == nullptr) {
        return domainError("NotFound",
                           "unknown background preset: " +
                               args["preset"].get<std::string>());
      }
      background = PresetToJson(*preset);
      background["preset"] = preset->id;
    } else if (args.contains("background") && args["background"].is_object()) {
      background = args["background"];
    } else {
      return domainError("InvalidArgument",
                         "args.preset or args.background is required");
    }
    page->background = std::move(background);
    nlohmann::json result;
    result["pageId"] = pageId;
    result["background"] = page->background;
    return domainOk(result.dump());
  }

  std::string Get(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    scene::PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    nlohmann::json result;
    result["pageId"] = pageId;
    result["background"] = page->background;
    return domainOk(result.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(BackgroundDomain)

}  // namespace wb
