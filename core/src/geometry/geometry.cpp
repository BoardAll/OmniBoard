// geometry/geometry.cpp — domain "geometry" (task package 1.3).
// Owns: core/src/geometry.
//
// Ops (《C++ 核心引擎接口设计》§9, 《白板软件设计文档》§2):
//   hitTest {pageId, x, y, tolerance?}
//     -> {"hit":true, "elementId", "type", "zIndex", "localX", "localY"}
//        connectors instead report {"segmentIndex", "distance"}
//     -> {"hit":false, "pageId"}
//   bounds {pageId, elementIds?}
//     -> {"bounds":{x,y,width,height}, "count"}  (rotation-aware AABB union)

#include <algorithm>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../model/geom_math.h"
#include "../model/scene_store.h"
#include "wb/ffi/domain.h"

namespace wb {
namespace {

using scene::PageRec;
using scene::SceneStore;

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

const nlohmann::json* FindElementIn(const PageRec& page, const std::string& id) {
  for (const auto& element : page.elements) {
    if (element.value("id", std::string()) == id) return &element;
  }
  return nullptr;
}

/// Polyline (world coords) approximating a connector: explicit waypoints when
/// present, otherwise the segment between the centres of the referenced
/// elements, falling back to the connector's own rect.
std::vector<Point> ConnectorPolyline(const PageRec& page,
                                     const nlohmann::json& connector) {
  const nlohmann::json data =
      connector.value("data", nlohmann::json::object());
  if (data.contains("waypoints") && data["waypoints"].is_array()) {
    std::vector<Point> points;
    for (const auto& waypoint : data["waypoints"]) {
      if (waypoint.is_object() && waypoint.contains("x") &&
          waypoint.contains("y") && waypoint["x"].is_number() &&
          waypoint["y"].is_number()) {
        points.push_back(Point{waypoint["x"].get<float>(),
                               waypoint["y"].get<float>()});
      }
    }
    if (points.size() >= 2) return points;
  }
  const auto centreOf = [&page](const std::string& id,
                                bool* found) -> Point {
    const nlohmann::json* element = FindElementIn(page, id);
    if (element == nullptr) {
      *found = false;
      return Point{};
    }
    *found = true;
    const Rect rect = scene::ElementRect(*element);
    return Point{rect.x + rect.width / 2.0f, rect.y + rect.height / 2.0f};
  };
  bool fromFound = false;
  bool toFound = false;
  const Point from =
      centreOf(data.value("fromElementId", std::string()), &fromFound);
  const Point to = centreOf(data.value("toElementId", std::string()), &toFound);
  if (fromFound && toFound) return {from, to};
  // Fallback: horizontal middle line of the connector's own rect.
  const Rect rect = scene::ElementRect(connector);
  return {Point{rect.x, rect.y + rect.height / 2.0f},
          Point{rect.right(), rect.y + rect.height / 2.0f}};
}

class GeometryDomain : public DomainHandler {
 public:
  std::string name() const override { return "geometry"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    SceneStore& store = SceneStore::instance();
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "hitTest") return HitTest(store, args);
    if (op == "bounds") return Bounds(store, args);
    return domainError("NotFound", "unknown geometry op: " + op);
  }

 private:
  static std::string HitTest(SceneStore& store, const nlohmann::json& args) {
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
    const float tolerance = args.value("tolerance", 0.0f);

    // Top-down: the topmost (highest zIndex) element wins.
    for (std::size_t i = page->elements.size(); i-- > 0;) {
      const nlohmann::json& element = page->elements[i];
      if (element.value("hidden", false)) continue;
      const std::string type = element.value("type", std::string());
      if (type == "connector") {
        const std::vector<Point> polyline = ConnectorPolyline(*page, element);
        if (polyline.size() < 2) continue;
        float best = 1e30f;
        int bestSegment = -1;
        for (std::size_t s = 0; s + 1 < polyline.size(); ++s) {
          const float d = scene::PointSegmentDistance(
              x, y, polyline[s].x, polyline[s].y, polyline[s + 1].x,
              polyline[s + 1].y);
          if (d < best) {
            best = d;
            bestSegment = static_cast<int>(s);
          }
        }
        const float limit = tolerance > 6.0f ? tolerance : 6.0f;
        if (best <= limit) {
          nlohmann::json result;
          result["hit"] = true;
          result["elementId"] = element.value("id", std::string());
          result["type"] = type;
          result["zIndex"] = static_cast<int>(i);
          result["segmentIndex"] = bestSegment;
          result["distance"] = best;
          return domainOk(result.dump());
        }
        continue;
      }
      // Shape: inverse-rotate the probe into the element's local frame.
      const Rect rect = scene::ElementRect(element);
      const float cx = rect.x + rect.width / 2.0f;
      const float cy = rect.y + rect.height / 2.0f;
      const Point local = scene::RotateAround(
          x, y, cx, cy, -scene::ElementRotationRadians(element));
      if (local.x >= rect.x - tolerance && local.x <= rect.right() + tolerance &&
          local.y >= rect.y - tolerance && local.y <= rect.bottom() + tolerance) {
        nlohmann::json result;
        result["hit"] = true;
        result["elementId"] = element.value("id", std::string());
        result["type"] = type;
        result["zIndex"] = static_cast<int>(i);
        result["localX"] = local.x - rect.x;
        result["localY"] = local.y - rect.y;
        return domainOk(result.dump());
      }
    }
    nlohmann::json result;
    result["hit"] = false;
    result["pageId"] = pageId;
    return domainOk(result.dump());
  }

  static std::string Bounds(SceneStore& store, const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    PageRec* page = store.findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    std::vector<const nlohmann::json*> selected;
    if (args.contains("elementIds") && args["elementIds"].is_array()) {
      for (const auto& id : args["elementIds"]) {
        if (!id.is_string()) {
          return domainError("InvalidArgument", "elementIds must be strings");
        }
        const nlohmann::json* element = FindElementIn(*page, id.get<std::string>());
        if (element == nullptr) {
          return domainError("NotFound", "unknown element: " + id.get<std::string>());
        }
        selected.push_back(element);
      }
    } else {
      for (const auto& element : page->elements) {
        selected.push_back(&element);
      }
    }

    nlohmann::json bounds;
    if (selected.empty()) {
      bounds = {{"x", 0.0f}, {"y", 0.0f}, {"width", 0.0f}, {"height", 0.0f}};
    } else {
      float unionBox[4] = {1e30f, 1e30f, -1e30f, -1e30f};
      for (const nlohmann::json* element : selected) {
        float box[4];
        scene::ElementAabb(*element, box);
        unionBox[0] = std::min(unionBox[0], box[0]);
        unionBox[1] = std::min(unionBox[1], box[1]);
        unionBox[2] = std::max(unionBox[2], box[2]);
        unionBox[3] = std::max(unionBox[3], box[3]);
      }
      bounds = {{"x", unionBox[0]},
                {"y", unionBox[1]},
                {"width", unionBox[2] - unionBox[0]},
                {"height", unionBox[3] - unionBox[1]}};
    }
    nlohmann::json result;
    result["bounds"] = std::move(bounds);
    result["count"] = selected.size();
    return domainOk(result.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(GeometryDomain)

}  // namespace wb
