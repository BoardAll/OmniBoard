// render2d/render2d.cpp — domain "render2d" (task package 1.4).
// Owns: core/src/render2d.
//
// Ops (《渲染引擎设计》§9):
//   create   {pageId, element?}      -> creates a 2D drawing element
//                                       (type forced to "render2d")
//                                       -> {"element":{full},"elementId","pageId"}
//   setStyle {elementId, style}      -> deep-merges the style block
//                                       (InvalidArgument on non-2D elements)
//   annotate {elementId, annotation} -> appends to data.annotations
//                                       -> {"elementId","annotationCount"}
//   list     {pageId}                -> 2D elements of a page, z-order
//
// The element records live in the shared SceneStore page element list, so 2D
// elements take part in z-order, hit testing and layout like any other
// element; only their type ("render2d") and data block are special.

#include <algorithm>
#include <string>

#include <nlohmann/json.hpp>

#include "../model/scene_store.h"
#include "wb/ffi/domain.h"
#include "wb/platform/platform.h"

namespace wb {
namespace {

using scene::SceneStore;
using scene::PageRec;

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

void Renumber(std::vector<nlohmann::json>& elements) {
  for (std::size_t i = 0; i < elements.size(); ++i) {
    elements[i]["zIndex"] = static_cast<int>(i);
  }
}

/// Finds a render2d element; fills `errorCode`/`errorMessage` (code empty on
/// success).
nlohmann::json* FindRender2d(SceneStore& store, const std::string& elementId,
                             scene::ElementLocation* locationOut,
                             std::string* errorCode,
                             std::string* errorMessage) {
  scene::ElementLocation location = store.findElement(elementId);
  if (location.index < 0) {
    *errorCode = "NotFound";
    *errorMessage = "unknown element: " + elementId;
    return nullptr;
  }
  if (location.page->locked) {
    *errorCode = "Conflict";
    *errorMessage = "page is locked: " + location.page->id;
    return nullptr;
  }
  nlohmann::json& element =
      location.page->elements[static_cast<std::size_t>(location.index)];
  if (element.value("type", std::string()) != "render2d") {
    *errorCode = "InvalidArgument";
    *errorMessage = "element is not a 2D element: " + elementId;
    return nullptr;
  }
  *locationOut = location;
  return &element;
}

class Render2dDomain : public DomainHandler {
 public:
  std::string name() const override { return "render2d"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "create") return Create(args);
    if (op == "setStyle") return SetStyle(args);
    if (op == "annotate") return Annotate(args);
    if (op == "list") return List(args);
    return domainError("NotFound", "unknown render2d op: " + op);
  }

 private:
  std::string Create(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    if (page->locked) {
      return domainError("Conflict", "page is locked: " + pageId);
    }
    nlohmann::json element =
        args.value("element", nlohmann::json::object());
    if (!element.is_object()) element = nlohmann::json::object();
    element["type"] = "render2d";

    std::string elementId = element.value("id", std::string());
    if (elementId.empty()) elementId = SceneStore::instance().newElementId();
    const std::int64_t now = timeMillis();
    element["id"] = elementId;
    element["pageId"] = pageId;
    element["createdAt"] = element.value("createdAt", now);
    element["updatedAt"] = now;
    element["rotation"] = element.value("rotation", 0.0f);
    element["opacity"] = element.value("opacity", 1.0f);
    element["locked"] = element.value("locked", false);
    if (!element.contains("data") || !element["data"].is_object()) {
      element["data"] = nlohmann::json::object();
    }

    int index = static_cast<int>(page->elements.size());
    if (element.contains("zIndex") && element["zIndex"].is_number_integer()) {
      index = std::max(0, std::min(element["zIndex"].get<int>(), index));
    }
    element["zIndex"] = index;
    page->elements.insert(page->elements.begin() + index, std::move(element));
    Renumber(page->elements);

    nlohmann::json result;
    result["element"] =
        page->elements[static_cast<std::size_t>(index)];
    result["elementId"] = elementId;
    result["pageId"] = pageId;
    result["type"] = "render2d";
    return domainOk(result.dump());
  }

  std::string SetStyle(const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    if (!args.contains("style") || !args["style"].is_object()) {
      return domainError("InvalidArgument", "args.style is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    scene::ElementLocation location;
    std::string errorCode;
    std::string errorMessage;
    nlohmann::json* element = FindRender2d(
        SceneStore::instance(), elementId, &location, &errorCode, &errorMessage);
    if (element == nullptr) {
      return domainError(errorCode, errorMessage);
    }
    nlohmann::json merged = element->value("style", nlohmann::json::object());
    if (!merged.is_object()) merged = nlohmann::json::object();
    for (auto it = args["style"].begin(); it != args["style"].end(); ++it) {
      merged[it.key()] = it.value();
    }
    (*element)["style"] = std::move(merged);
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["element"] = *element;
    result["elementId"] = elementId;
    return domainOk(result.dump());
  }

  std::string Annotate(const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    if (!args.contains("annotation") || !args["annotation"].is_object()) {
      return domainError("InvalidArgument", "args.annotation is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    scene::ElementLocation location;
    std::string errorCode;
    std::string errorMessage;
    nlohmann::json* element = FindRender2d(
        SceneStore::instance(), elementId, &location, &errorCode, &errorMessage);
    if (element == nullptr) {
      return domainError(errorCode, errorMessage);
    }
    if (!element->contains("data") || !(*element)["data"].is_object()) {
      (*element)["data"] = nlohmann::json::object();
    }
    nlohmann::json& data = (*element)["data"];
    if (!data.contains("annotations") || !data["annotations"].is_array()) {
      data["annotations"] = nlohmann::json::array();
    }
    data["annotations"].push_back(args["annotation"]);
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["elementId"] = elementId;
    result["annotationCount"] =
        static_cast<int>(data["annotations"].size());
    result["element"] = *element;
    return domainOk(result.dump());
  }

  std::string List(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    nlohmann::json elements = nlohmann::json::array();
    for (std::size_t i = 0; i < page->elements.size(); ++i) {
      const nlohmann::json& element = page->elements[i];
      if (element.value("type", std::string()) != "render2d") continue;
      nlohmann::json summary = SceneStore::elementSummary(element);
      int annotationCount = 0;
      if (element.contains("data") && element["data"].is_object() &&
          element["data"].contains("annotations") &&
          element["data"]["annotations"].is_array()) {
        annotationCount =
            static_cast<int>(element["data"]["annotations"].size());
      }
      summary["annotationCount"] = annotationCount;
      summary["hasStyle"] = element.contains("style");
      elements.push_back(std::move(summary));
    }
    nlohmann::json result;
    result["elements"] = std::move(elements);
    result["count"] = static_cast<int>(result["elements"].size());
    return domainOk(result.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(Render2dDomain)

}  // namespace wb
