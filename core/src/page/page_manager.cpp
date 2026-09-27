// page/page_manager.cpp — domain "page" (task package 1.3).
// Owns: core/src/page.
//
// Ops (《左侧栏与页面管理设计》M2.6):
//   list          {boardId}                 -> {"pages":[...], "count"}
//   create        {boardId, page?}          -> {"page":{...}} (inverse delete)
//   duplicate     {pageId}                  -> {"page":{...}} (deep copy, new ids)
//   delete        {pageId}                  -> {"deleted":{...}, "boardId"} (last page -> Conflict)
//   move          {pageId, newIndex}        -> {"previousIndex":N}
//   rename        {pageId, name}            -> explicit inverse with old name
//   setBackground {pageId, background}      -> explicit inverse with old background
//   lock/hide     {pageId, locked|hidden}   -> explicit inverse with old value

#include <algorithm>
#include <string>

#include <nlohmann/json.hpp>

#include "wb/ffi/domain.h"
#include "wb/platform/platform.h"
#include "../model/scene_store.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

nlohmann::json MakeInverse(const char* op, nlohmann::json args) {
  nlohmann::json inverse;
  inverse["domain"] = "page";
  inverse["op"] = op;
  inverse["args"] = std::move(args);
  return inverse;
}

class PageDomain : public DomainHandler {
 public:
  std::string name() const override { return "page"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    std::lock_guard<std::mutex> lock(scene::SceneStore::instance().mutex());
    scene::SceneStore& store = scene::SceneStore::instance();
    const nlohmann::json args = ParseArgs(argsJson);

    if (op == "list") {
      const std::string boardId = args.value("boardId", std::string());
      scene::BoardRec* board = store.findBoardById(boardId);
      if (board == nullptr) {
        return domainError("NotFound", "unknown board: " + boardId);
      }
      nlohmann::json pages = nlohmann::json::array();
      for (const scene::PageRec& page : board->pages) {
        pages.push_back(scene::SceneStore::pageSummary(page));
      }
      nlohmann::json result;
      result["pages"] = std::move(pages);
      result["count"] = board->pages.size();
      return domainOk(result.dump());
    }
    if (op == "create") {
      const std::string boardId = args.value("boardId", std::string());
      scene::BoardRec* board = store.findBoardById(boardId);
      if (board == nullptr) {
        return domainError("NotFound", "unknown board: " + boardId);
      }
      scene::PageRec page;
      page.id = store.newPageId();
      page.createdAt = timeMillis();
      page.name = "页面 " + std::to_string(board->pages.size() + 1);
      if (args.contains("page") && args["page"].is_object()) {
        const nlohmann::json& spec = args["page"];
        page.name = spec.value("name", page.name);
        page.background = spec.value("background", nlohmann::json::object());
        // Restoring a previously deleted page: keep its elements as-is.
        if (spec.contains("elements") && spec["elements"].is_array()) {
          for (const auto& element : spec["elements"]) {
            if (element.is_object()) {
              nlohmann::json copy = element;
              copy["pageId"] = page.id;
              page.elements.push_back(std::move(copy));
            }
          }
        }
      }
      const std::string pageId = page.id;
      board->pages.push_back(std::move(page));
      scene::PageRec* created = store.findPage(pageId, nullptr);
      nlohmann::json result;
      result["page"] = scene::SceneStore::pageSummary(*created);
      result["pageId"] = pageId;
      return domainOk(result.dump());
    }
    if (op == "duplicate") {
      const std::string pageId = args.value("pageId", std::string());
      scene::BoardRec* owner = nullptr;
      scene::PageRec* source = store.findPage(pageId, &owner);
      if (source == nullptr) {
        return domainError("NotFound", "unknown page: " + pageId);
      }
      scene::PageRec copy = *source;
      copy.id = store.newPageId();
      copy.name = source->name + " 副本";
      copy.createdAt = timeMillis();
      for (auto& element : copy.elements) {
        element["id"] = store.newElementId();
        element["pageId"] = copy.id;
        element["createdAt"] = timeMillis();
      }
      const std::string newPageId = copy.id;
      auto position = std::find_if(
          owner->pages.begin(), owner->pages.end(),
          [&pageId](const scene::PageRec& p) { return p.id == pageId; });
      owner->pages.insert(position + 1, std::move(copy));
      scene::PageRec* created = store.findPage(newPageId, nullptr);
      nlohmann::json result;
      result["page"] = scene::SceneStore::pageSummary(*created);
      result["pageId"] = newPageId;
      return domainOk(result.dump());
    }
    if (op == "delete") {
      const std::string pageId = args.value("pageId", std::string());
      scene::BoardRec* owner = nullptr;
      scene::PageRec* page = store.findPage(pageId, &owner);
      if (page == nullptr) {
        return domainError("NotFound", "unknown page: " + pageId);
      }
      if (owner->pages.size() <= 1) {
        return domainError("Conflict", "cannot delete the last page of a board");
      }
      nlohmann::json deleted;
      deleted["id"] = page->id;
      deleted["name"] = page->name;
      deleted["background"] = page->background;
      deleted["elements"] = page->elements;
      owner->pages.erase(std::remove_if(owner->pages.begin(), owner->pages.end(),
                                        [&pageId](const scene::PageRec& p) {
                                          return p.id == pageId;
                                        }),
                         owner->pages.end());
      nlohmann::json result;
      result["deleted"] = std::move(deleted);
      result["pageId"] = pageId;
      result["boardId"] = owner->id;
      return domainOk(result.dump());
    }
    if (op == "move") {
      const std::string pageId = args.value("pageId", std::string());
      if (!args.contains("newIndex") || !args["newIndex"].is_number_integer()) {
        return domainError("InvalidArgument", "args.newIndex (integer) is required");
      }
      scene::BoardRec* owner = nullptr;
      scene::PageRec* page = store.findPage(pageId, &owner);
      if (page == nullptr) {
        return domainError("NotFound", "unknown page: " + pageId);
      }
      const int count = static_cast<int>(owner->pages.size());
      int newIndex = args["newIndex"].get<int>();
      newIndex = std::max(0, std::min(newIndex, count - 1));
      auto it = std::find_if(owner->pages.begin(), owner->pages.end(),
                             [&pageId](const scene::PageRec& p) {
                               return p.id == pageId;
                             });
      const int previousIndex = static_cast<int>(it - owner->pages.begin());
      if (previousIndex == newIndex) {
        return domainOk(nlohmann::json{{"pageId", pageId},
                                       {"newIndex", newIndex},
                                       {"previousIndex", previousIndex}}
                            .dump());
      }
      scene::PageRec moving = std::move(*it);
      owner->pages.erase(it);
      owner->pages.insert(owner->pages.begin() + newIndex, std::move(moving));
      nlohmann::json result;
      result["pageId"] = pageId;
      result["newIndex"] = newIndex;
      result["previousIndex"] = previousIndex;
      return domainOk(result.dump());
    }
    if (op == "rename") {
      const std::string pageId = args.value("pageId", std::string());
      const std::string name = args.value("name", std::string());
      if (name.empty()) {
        return domainError("InvalidArgument", "args.name is required");
      }
      scene::PageRec* page = store.findPage(pageId, nullptr);
      if (page == nullptr) {
        return domainError("NotFound", "unknown page: " + pageId);
      }
      const std::string previousName = page->name;
      page->name = name;
      nlohmann::json result;
      result["page"] = scene::SceneStore::pageSummary(*page);
      result["inverse"] = MakeInverse("rename", {{"pageId", pageId},
                                                 {"name", previousName}});
      return domainOk(result.dump());
    }
    if (op == "setBackground") {
      const std::string pageId = args.value("pageId", std::string());
      scene::PageRec* page = store.findPage(pageId, nullptr);
      if (page == nullptr) {
        return domainError("NotFound", "unknown page: " + pageId);
      }
      const nlohmann::json previous = page->background;
      page->background = args.value("background", nlohmann::json::object());
      nlohmann::json result;
      result["page"] = scene::SceneStore::pageSummary(*page);
      result["inverse"] = MakeInverse("setBackground",
                                      {{"pageId", pageId}, {"background", previous}});
      return domainOk(result.dump());
    }
    if (op == "lock" || op == "hide") {
      const std::string pageId = args.value("pageId", std::string());
      scene::PageRec* page = store.findPage(pageId, nullptr);
      if (page == nullptr) {
        return domainError("NotFound", "unknown page: " + pageId);
      }
      const bool value =
          op == "lock" ? args.value("locked", false) : args.value("hidden", false);
      const bool previous = op == "lock" ? page->locked : page->hidden;
      if (op == "lock") {
        page->locked = value;
      } else {
        page->hidden = value;
      }
      nlohmann::json inverseArgs;
      inverseArgs["pageId"] = pageId;
      inverseArgs[op == "lock" ? "locked" : "hidden"] = previous;
      nlohmann::json result;
      result["page"] = scene::SceneStore::pageSummary(*page);
      result["inverse"] = MakeInverse(op.c_str(), std::move(inverseArgs));
      return domainOk(result.dump());
    }
    return domainError("NotFound", "unknown page op: " + op);
  }
};

}  // namespace

WB_REGISTER_DOMAIN(PageDomain)

}  // namespace wb
