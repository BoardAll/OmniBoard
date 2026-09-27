// layout/layout.cpp — domain "layout" (task package 1.3).
// Owns: core/src/layout.
//
// Ops (《C++ 核心引擎接口设计》§10.2, 《白板软件设计文档》§2.5):
//   align      {pageId, elementIds[], mode}
//     mode: left|right|top|bottom (union edge) | hcenter|vcenter (union centre)
//     -> {"moved", "mode", "bounds":{x,y,width,height}}
//   distribute {pageId, elementIds[], orientation}
//     orientation: horizontal|vertical  (needs >= 3 elements; ends stay fixed)
//     -> {"moved", "orientation"}
//   snap       {pageId, x, y, threshold?, excludeIds?}
//     -> {"snappedX","snappedY","deltaX","deltaY",
//         "guides":[{"axis":"x"|"y","position":N,"elementIds":[...]}]}

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../model/geom_math.h"
#include "../model/scene_store.h"
#include "wb/ffi/domain.h"
#include "wb/platform/platform.h"

namespace wb {
namespace {

using scene::PageRec;
using scene::SceneStore;

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

/// Resolves args.elementIds (non-empty array of known ids) against the page.
/// On failure returns false and fills `error` with a ready error response.
bool CollectElements(SceneStore& store, const nlohmann::json& args,
                     PageRec** pageOut, std::vector<nlohmann::json*>* out,
                     std::string* error) {
  const std::string pageId = args.value("pageId", std::string());
  PageRec* page = store.findPage(pageId, nullptr);
  if (page == nullptr) {
    *error = domainError("NotFound", "unknown page: " + pageId);
    return false;
  }
  if (!args.contains("elementIds") || !args["elementIds"].is_array() ||
      args["elementIds"].empty()) {
    *error = domainError("InvalidArgument",
                         "args.elementIds must be a non-empty array");
    return false;
  }
  for (const auto& id : args["elementIds"]) {
    if (!id.is_string()) {
      *error = domainError("InvalidArgument", "elementIds must be strings");
      return false;
    }
    nlohmann::json* found = nullptr;
    for (auto& element : page->elements) {
      if (element.value("id", std::string()) == id.get<std::string>()) {
        found = &element;
        break;
      }
    }
    if (found == nullptr) {
      *error = domainError("NotFound", "unknown element: " + id.get<std::string>());
      return false;
    }
    out->push_back(found);
  }
  *pageOut = page;
  return true;
}

void MoveElement(nlohmann::json& element, float dx, float dy, std::int64_t now) {
  if (dx == 0.0f && dy == 0.0f) return;
  if (!element.contains("position") || !element["position"].is_object()) {
    element["position"] = nlohmann::json::object();
  }
  element["position"]["x"] =
      scene::NumberOr(element["position"], "x", 0.0f) + dx;
  element["position"]["y"] =
      scene::NumberOr(element["position"], "y", 0.0f) + dy;
  element["updatedAt"] = now;
}

float CentreX(const nlohmann::json& element) {
  float box[4];
  scene::ElementAabb(element, box);
  return (box[0] + box[2]) / 2.0f;
}

float CentreY(const nlohmann::json& element) {
  float box[4];
  scene::ElementAabb(element, box);
  return (box[1] + box[3]) / 2.0f;
}

class LayoutDomain : public DomainHandler {
 public:
  std::string name() const override { return "layout"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    SceneStore& store = SceneStore::instance();
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "align") return Align(store, args);
    if (op == "distribute") return Distribute(store, args);
    if (op == "snap") return Snap(store, args);
    return domainError("NotFound", "unknown layout op: " + op);
  }

 private:
  static std::string Align(SceneStore& store, const nlohmann::json& args) {
    PageRec* page = nullptr;
    std::vector<nlohmann::json*> elements;
    std::string error;
    if (!CollectElements(store, args, &page, &elements, &error)) return error;
    if (page->locked) {
      return domainError("Conflict", "page is locked: " + page->id);
    }
    const std::string mode = args.value("mode", std::string());
    static const char* kModes[] = {"left", "right", "top",
                                   "bottom", "hcenter", "vcenter"};
    bool validMode = false;
    for (const char* candidate : kModes) {
      if (mode == candidate) validMode = true;
    }
    if (!validMode) {
      return domainError(
          "InvalidArgument",
          "args.mode must be one of left|right|top|bottom|hcenter|vcenter");
    }
    if (elements.size() < 2) {
      return domainError("InvalidArgument", "align needs at least 2 elements");
    }

    float unionBox[4] = {1e30f, 1e30f, -1e30f, -1e30f};
    for (nlohmann::json* element : elements) {
      float box[4];
      scene::ElementAabb(*element, box);
      unionBox[0] = std::min(unionBox[0], box[0]);
      unionBox[1] = std::min(unionBox[1], box[1]);
      unionBox[2] = std::max(unionBox[2], box[2]);
      unionBox[3] = std::max(unionBox[3], box[3]);
    }
    const std::int64_t now = timeMillis();
    for (nlohmann::json* element : elements) {
      float box[4];
      scene::ElementAabb(*element, box);
      float dx = 0.0f;
      float dy = 0.0f;
      if (mode == "left") {
        dx = unionBox[0] - box[0];
      } else if (mode == "right") {
        dx = unionBox[2] - box[2];
      } else if (mode == "top") {
        dy = unionBox[1] - box[1];
      } else if (mode == "bottom") {
        dy = unionBox[3] - box[3];
      } else if (mode == "hcenter") {
        dx = (unionBox[0] + unionBox[2]) / 2.0f - (box[0] + box[2]) / 2.0f;
      } else {
        dy = (unionBox[1] + unionBox[3]) / 2.0f - (box[1] + box[3]) / 2.0f;
      }
      MoveElement(*element, dx, dy, now);
    }
    nlohmann::json result;
    result["moved"] = elements.size();
    result["mode"] = mode;
    result["bounds"] = {{"x", unionBox[0]},
                        {"y", unionBox[1]},
                        {"width", unionBox[2] - unionBox[0]},
                        {"height", unionBox[3] - unionBox[1]}};
    return domainOk(result.dump());
  }

  static std::string Distribute(SceneStore& store, const nlohmann::json& args) {
    PageRec* page = nullptr;
    std::vector<nlohmann::json*> elements;
    std::string error;
    if (!CollectElements(store, args, &page, &elements, &error)) return error;
    if (page->locked) {
      return domainError("Conflict", "page is locked: " + page->id);
    }
    const std::string orientation = args.value("orientation", std::string());
    if (orientation != "horizontal" && orientation != "vertical") {
      return domainError(
          "InvalidArgument",
          "args.orientation must be horizontal or vertical");
    }
    if (elements.size() < 3) {
      return domainError("InvalidArgument",
                         "distribute needs at least 3 elements");
    }
    const bool horizontal = orientation == "horizontal";

    // Order along the axis, keeping the outermost two fixed.
    std::sort(elements.begin(), elements.end(),
              [horizontal](nlohmann::json* a, nlohmann::json* b) {
                return horizontal ? CentreX(*a) < CentreX(*b)
                                  : CentreY(*a) < CentreY(*b);
              });
    const float first = horizontal ? CentreX(*elements.front())
                                   : CentreY(*elements.front());
    const float last = horizontal ? CentreX(*elements.back())
                                  : CentreY(*elements.back());
    const float step =
        (last - first) / static_cast<float>(elements.size() - 1);
    const std::int64_t now = timeMillis();
    for (std::size_t i = 1; i + 1 < elements.size(); ++i) {
      const float target = first + step * static_cast<float>(i);
      const float current =
          horizontal ? CentreX(*elements[i]) : CentreY(*elements[i]);
      const float delta = target - current;
      MoveElement(*elements[i], horizontal ? delta : 0.0f,
                  horizontal ? 0.0f : delta, now);
    }
    nlohmann::json result;
    result["moved"] = elements.size();
    result["orientation"] = orientation;
    return domainOk(result.dump());
  }

  static std::string Snap(SceneStore& store, const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    PageRec* page = store.findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    if (!args.contains("x") || !args.contains("y") || !args["x"].is_number() ||
        !args["y"].is_number()) {
      return domainError("InvalidArgument", "args.x and args.y are required");
    }
    const float x = args["x"].get<float>();
    const float y = args["y"].get<float>();
    const float threshold = args.value("threshold", 8.0f);

    std::vector<std::string> excluded;
    if (args.contains("excludeIds") && args["excludeIds"].is_array()) {
      for (const auto& id : args["excludeIds"]) {
        if (id.is_string()) excluded.push_back(id.get<std::string>());
      }
    }
    const auto isExcluded = [&excluded](const std::string& id) {
      return std::find(excluded.begin(), excluded.end(), id) != excluded.end();
    };

    // Candidate guide lines: both edges and the centre of every other element.
    struct Candidate {
      float position;
      std::string elementId;
    };
    std::vector<Candidate> xLines;
    std::vector<Candidate> yLines;
    for (const auto& element : page->elements) {
      if (element.value("hidden", false)) continue;
      const std::string id = element.value("id", std::string());
      if (isExcluded(id)) continue;
      float box[4];
      scene::ElementAabb(element, box);
      xLines.push_back({box[0], id});
      xLines.push_back({(box[0] + box[2]) / 2.0f, id});
      xLines.push_back({box[2], id});
      yLines.push_back({box[1], id});
      yLines.push_back({(box[1] + box[3]) / 2.0f, id});
      yLines.push_back({box[3], id});
    }
    const auto nearest = [threshold](const std::vector<Candidate>& lines,
                                     float value, float* out) {
      bool found = false;
      float bestDistance = threshold;
      for (const Candidate& line : lines) {
        const float distance = std::fabs(line.position - value);
        if (distance <= bestDistance) {
          bestDistance = distance;
          *out = line.position;
          found = true;
        }
      }
      return found;
    };

    float snappedX = x;
    float snappedY = y;
    const bool snapX = nearest(xLines, x, &snappedX);
    const bool snapY = nearest(yLines, y, &snappedY);
    if (!snapX) snappedX = x;
    if (!snapY) snappedY = y;

    const auto collectGuides = [](const std::vector<Candidate>& lines,
                                  float position, const char* axis,
                                  nlohmann::json* guides) {
      nlohmann::json ids = nlohmann::json::array();
      for (const Candidate& line : lines) {
        if (std::fabs(line.position - position) < 0.01f &&
            std::find(ids.begin(), ids.end(), line.elementId) == ids.end()) {
          ids.push_back(line.elementId);
        }
      }
      if (!ids.empty()) {
        guides->push_back(
            {{"axis", axis}, {"position", position}, {"elementIds", ids}});
      }
    };
    nlohmann::json guides = nlohmann::json::array();
    if (snapX) collectGuides(xLines, snappedX, "x", &guides);
    if (snapY) collectGuides(yLines, snappedY, "y", &guides);

    nlohmann::json result;
    result["snappedX"] = snappedX;
    result["snappedY"] = snappedY;
    result["deltaX"] = snappedX - x;
    result["deltaY"] = snappedY - y;
    result["guides"] = std::move(guides);
    return domainOk(result.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(LayoutDomain)

}  // namespace wb
