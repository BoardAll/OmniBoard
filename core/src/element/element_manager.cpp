// element/element_manager.cpp — domain "element" (task package 1.3).
// Owns: core/src/element.
//
// Ops (《C++ 核心引擎接口设计》§8):
//   create {pageId, element}        -> {"element":{full}, "elementId", "pageId"}
//   update {elementId, patch}       -> {"element":{full}, "previous":{full}, "elementId"}
//   delete {elementId}              -> {"deleted":{full}, "pageId", "deletedConnectorIds"}
//   list   {pageId}                 -> {"elements":[...z-order...], "count"}
//   batch  {pageId, ops[]}          -> atomic bulk apply, rollback on failure

#include <algorithm>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../model/scene_store.h"
#include "wb/ffi/domain.h"
#include "wb/platform/platform.h"

namespace wb {
namespace scene {
namespace {

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

/// Shallow merge; "style"/"data" merge one level deep per design §8.3.
/// Immutable fields (id/pageId/createdAt) are never overwritten by a patch.
void MergePatch(nlohmann::json& target, const nlohmann::json& patch) {
  for (auto it = patch.begin(); it != patch.end(); ++it) {
    const std::string key = it.key();
    if (key == "id" || key == "pageId" || key == "createdAt") continue;
    const bool deep = (key == "style" || key == "data");
    if (deep && it.value().is_object() && target.contains(key) &&
        target[key].is_object()) {
      for (auto sub = it.value().begin(); sub != it.value().end(); ++sub) {
        target[key][sub.key()] = sub.value();
      }
    } else {
      target[key] = it.value();
    }
  }
}

int IndexOf(const std::vector<nlohmann::json>& elements, const std::string& id) {
  for (std::size_t i = 0; i < elements.size(); ++i) {
    if (elements[i].value("id", std::string()) == id) return static_cast<int>(i);
  }
  return -1;
}

bool IsConnectorTo(const nlohmann::json& element, const std::string& elementId) {
  if (element.value("type", std::string()) != "connector") return false;
  if (!element.contains("data") || !element["data"].is_object()) return false;
  const nlohmann::json& data = element["data"];
  return data.value("fromElementId", std::string()) == elementId ||
         data.value("toElementId", std::string()) == elementId;
}

class ElementDomain : public DomainHandler {
 public:
  std::string name() const override { return "element"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    std::lock_guard<std::mutex> lock(scene::SceneStore::instance().mutex());
    scene::SceneStore& store = scene::SceneStore::instance();
    const nlohmann::json args = ParseArgs(argsJson);

    if (op == "create") return Create(store, args);
    if (op == "update") return Update(store, args);
    if (op == "delete") return Delete(store, args);
    if (op == "list") return List(store, args);
    if (op == "batch") return Batch(store, args);
    return domainError("NotFound", "unknown element op: " + op);
  }

 private:
  static std::string Create(SceneStore& store, const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    PageRec* page = store.findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    if (!args.contains("element") || !args["element"].is_object()) {
      return domainError("InvalidArgument", "args.element is required");
    }
    if (page->locked) {
      return domainError("Conflict", "page is locked: " + pageId);
    }
    nlohmann::json element = args["element"];
    if (!element.contains("type") || !element["type"].is_string() ||
        element["type"].get<std::string>().empty()) {
      return domainError("InvalidArgument", "element.type is required");
    }
    std::string elementId = element.value("id", std::string());
    if (!elementId.empty() && IndexOf(page->elements, elementId) >= 0) {
      return domainError("Conflict", "element already exists: " + elementId);
    }
    if (elementId.empty()) {
      elementId = store.newElementId();
    }
    const std::int64_t now = timeMillis();
    element["id"] = elementId;
    element["pageId"] = pageId;
    element["createdAt"] = element.value("createdAt", now);
    element["updatedAt"] = now;
    element["rotation"] = element.value("rotation", 0.0f);
    element["opacity"] = element.value("opacity", 1.0f);
    element["locked"] = element.value("locked", false);
    element["hidden"] = element.value("hidden", false);
    if (!element.contains("style") || !element["style"].is_object()) {
      element["style"] = nlohmann::json::object();
    }
    if (!element.contains("data") || !element["data"].is_object()) {
      element["data"] = nlohmann::json::object();
    }
    int index = static_cast<int>(page->elements.size());
    if (element.contains("zIndex") && element["zIndex"].is_number_integer()) {
      index = std::max(0, std::min(element["zIndex"].get<int>(), index));
    }
    page->elements.insert(page->elements.begin() + index, std::move(element));
    Renumber(page->elements);
    nlohmann::json result;
    result["element"] = page->elements[static_cast<std::size_t>(index)];
    result["elementId"] = elementId;
    result["pageId"] = pageId;
    return domainOk(result.dump());
  }

  static std::string Update(SceneStore& store, const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    ElementLocation location = store.findElement(elementId);
    if (location.page == nullptr) {
      return domainError("NotFound", "unknown element: " + elementId);
    }
    if (location.page->locked) {
      return domainError("Conflict", "page is locked: " + location.page->id);
    }
    if (!args.contains("patch") || !args["patch"].is_object()) {
      return domainError("InvalidArgument", "args.patch is required");
    }
    nlohmann::json& element = location.page->elements[static_cast<std::size_t>(location.index)];
    const nlohmann::json previous = element;
    MergePatch(element, args["patch"]);
    element["id"] = elementId;
    element["updatedAt"] = timeMillis();
    if (args["patch"].contains("zIndex") && args["patch"]["zIndex"].is_number_integer()) {
      const int count = static_cast<int>(location.page->elements.size());
      const int newIndex =
          std::max(0, std::min(args["patch"]["zIndex"].get<int>(), count - 1));
      if (newIndex != location.index) {
        nlohmann::json moving = std::move(location.page->elements[static_cast<std::size_t>(location.index)]);
        location.page->elements.erase(location.page->elements.begin() + location.index);
        location.page->elements.insert(location.page->elements.begin() + newIndex,
                                       std::move(moving));
        location.index = newIndex;
      }
    }
    Renumber(location.page->elements);
    nlohmann::json result;
    result["element"] = location.page->elements[static_cast<std::size_t>(location.index)];
    result["previous"] = previous;
    result["elementId"] = elementId;
    return domainOk(result.dump());
  }

  static std::string Delete(SceneStore& store, const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    ElementLocation location = store.findElement(elementId);
    if (location.page == nullptr) {
      return domainError("NotFound", "unknown element: " + elementId);
    }
    if (location.page->locked) {
      return domainError("Conflict", "page is locked: " + location.page->id);
    }
    nlohmann::json deleted = location.page->elements[static_cast<std::size_t>(location.index)];
    // Cascade: connectors pointing at the deleted element go too.
    nlohmann::json deletedConnectors = nlohmann::json::array();
    auto& elements = location.page->elements;
    for (auto it = elements.begin(); it != elements.end();) {
      if (it->value("id", std::string()) == elementId ||
          IsConnectorTo(*it, elementId)) {
        if (it->value("id", std::string()) != elementId) {
          deletedConnectors.push_back(it->value("id", std::string()));
        }
        it = elements.erase(it);
      } else {
        ++it;
      }
    }
    Renumber(elements);
    nlohmann::json result;
    result["deleted"] = std::move(deleted);
    result["elementId"] = elementId;
    result["pageId"] = location.page->id;
    result["deletedConnectorIds"] = std::move(deletedConnectors);
    return domainOk(result.dump());
  }

  static std::string List(SceneStore& store, const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    PageRec* page = store.findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    nlohmann::json result;
    result["elements"] = page->elements;
    result["count"] = page->elements.size();
    return domainOk(result.dump());
  }

  static std::string Batch(SceneStore& store, const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    PageRec* page = store.findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    if (!args.contains("ops") || !args["ops"].is_array()) {
      return domainError("InvalidArgument", "args.ops must be an array");
    }
    // Snapshot for atomic rollback.
    const std::vector<nlohmann::json> snapshot = page->elements;
    const std::vector<nlohmann::json>& ops = args["ops"];
    for (std::size_t i = 0; i < ops.size(); ++i) {
      const nlohmann::json& opItem = ops[i];
      const std::string kind = opItem.value("op", std::string());
      std::string response;
      if (kind == "create") {
        nlohmann::json createArgs;
        createArgs["pageId"] = pageId;
        createArgs["element"] = opItem.value("element", nlohmann::json::object());
        response = Create(store, createArgs);
      } else if (kind == "update") {
        nlohmann::json updateArgs;
        updateArgs["elementId"] = opItem.value("elementId", std::string());
        updateArgs["patch"] = opItem.value("patch", nlohmann::json::object());
        response = Update(store, updateArgs);
      } else if (kind == "delete") {
        nlohmann::json deleteArgs;
        deleteArgs["elementId"] = opItem.value("elementId", std::string());
        response = Delete(store, deleteArgs);
      } else {
        response = domainError("InvalidArgument", "unknown batch op: " + kind);
      }
      const auto parsed = nlohmann::json::parse(response, nullptr, false);
      if (parsed.is_discarded() || !parsed.value("ok", false)) {
        page->elements = snapshot;  // atomic rollback
        nlohmann::json detail;
        detail["failedIndex"] = i;
        detail["failedOp"] = kind;
        if (!parsed.is_discarded() && parsed.contains("error")) {
          detail["cause"] = parsed["error"];
        }
        nlohmann::json error;
        error["ok"] = false;
        error["error"] = {{"code", "Conflict"},
                          {"message", "element batch failed; page rolled back"},
                          {"detail", detail}};
        return error.dump();
      }
    }
    nlohmann::json result;
    result["executed"] = ops.size();
    result["count"] = page->elements.size();
    return domainOk(result.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(ElementDomain)

}  // namespace scene
}  // namespace wb
