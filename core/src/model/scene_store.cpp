// model/scene_store.cpp — scene state implementation (task package 1.3).
// Owns: core/src/model. See scene_store.h for the locking contract.

#include "scene_store.h"

#include "wb/platform/platform.h"

namespace wb {
namespace scene {

SceneStore& SceneStore::instance() {
  static SceneStore store;
  return store;
}

std::mutex& SceneStore::mutex() { return mutex_; }

std::uint64_t SceneStore::createBoard(const nlohmann::json& options) {
  BoardRec board;
  board.handle = nextHandle_++;
  board.id = "board-" + std::to_string(++boardCounter_);
  board.name = options.is_object() ? options.value("name", "未命名白板") : "未命名白板";
  board.createdAt = timeMillis();
  if (options.is_object() && options.contains("page") && options["page"].is_object()) {
    const nlohmann::json& first = options["page"];
    PageRec page;
    page.id = newPageId();
    page.name = first.value("name", "页面 1");
    page.background = first.value("background", nlohmann::json::object());
    page.createdAt = board.createdAt;
    board.pages.push_back(std::move(page));
  } else {
    PageRec page;
    page.id = newPageId();
    page.name = "页面 1";
    page.createdAt = board.createdAt;
    board.pages.push_back(std::move(page));
  }
  const std::uint64_t handle = board.handle;
  boards_[handle] = std::move(board);
  return handle;
}

bool SceneStore::destroyBoard(std::uint64_t handle) {
  return boards_.erase(handle) > 0;
}

BoardRec* SceneStore::findBoardByHandle(std::uint64_t handle) {
  const auto it = boards_.find(handle);
  return it != boards_.end() ? &it->second : nullptr;
}

BoardRec* SceneStore::findBoardById(const std::string& boardId) {
  for (auto& entry : boards_) {
    if (entry.second.id == boardId) return &entry.second;
  }
  return nullptr;
}

PageRec* SceneStore::findPage(const std::string& pageId, BoardRec** ownerOut) {
  for (auto& entry : boards_) {
    for (auto& page : entry.second.pages) {
      if (page.id == pageId) {
        if (ownerOut != nullptr) *ownerOut = &entry.second;
        return &page;
      }
    }
  }
  if (ownerOut != nullptr) *ownerOut = nullptr;
  return nullptr;
}

std::string SceneStore::newPageId() {
  return "page-" + std::to_string(++pageCounter_);
}

ElementLocation SceneStore::findElement(const std::string& elementId) {
  ElementLocation location;
  if (elementId.empty()) return location;
  for (auto& boardEntry : boards_) {
    for (auto& page : boardEntry.second.pages) {
      for (std::size_t i = 0; i < page.elements.size(); ++i) {
        if (page.elements[i].value("id", std::string()) == elementId) {
          location.board = &boardEntry.second;
          location.page = &page;
          location.index = static_cast<int>(i);
          return location;
        }
      }
    }
  }
  return location;
}

std::string SceneStore::newElementId() {
  return "element-" + std::to_string(++elementCounter_);
}

nlohmann::json SceneStore::pageSummary(const PageRec& page) {
  nlohmann::json summary;
  summary["id"] = page.id;
  summary["name"] = page.name;
  summary["locked"] = page.locked;
  summary["hidden"] = page.hidden;
  summary["background"] = page.background;
  summary["elementCount"] = page.elements.size();
  summary["createdAt"] = page.createdAt;
  return summary;
}

nlohmann::json SceneStore::boardSummary(const BoardRec& board) {
  nlohmann::json summary;
  summary["id"] = board.id;
  summary["handle"] = board.handle;
  summary["name"] = board.name;
  summary["createdAt"] = board.createdAt;
  summary["pageCount"] = board.pages.size();
  nlohmann::json pages = nlohmann::json::array();
  for (const PageRec& page : board.pages) {
    pages.push_back(pageSummary(page));
  }
  summary["pages"] = std::move(pages);
  return summary;
}

nlohmann::json SceneStore::elementSummary(const nlohmann::json& element) {
  nlohmann::json summary;
  summary["id"] = element.value("id", std::string());
  summary["type"] = element.value("type", std::string());
  summary["position"] = element.value("position", nlohmann::json::object());
  summary["size"] = element.value("size", nlohmann::json::object());
  summary["zIndex"] = element.value("zIndex", 0);
  summary["rotation"] = element.value("rotation", 0.0f);
  return summary;
}

}  // namespace scene
}  // namespace wb
