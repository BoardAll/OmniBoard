#pragma once

// model/scene_store.h — in-process scene state (task package 1.3, INTERNAL).
// Shared by the model/page/element/geometry/layout domains of this package
// only; not part of the public include/ contract surface.
//
// Locking: every mutating or reading domain handler acquires
// SceneStore::instance().mutex() for the whole handler body; SceneStore's own
// methods perform no locking. Never call invokeDomain() while holding it.

#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace wb {
namespace scene {

struct PageRec {
  std::string id;
  std::string name;
  bool locked = false;
  bool hidden = false;
  nlohmann::json background = nlohmann::json::object();
  std::vector<nlohmann::json> elements;  // array index == z-order (bottom first)
  std::int64_t createdAt = 0;
};

struct BoardRec {
  std::string id;
  std::uint64_t handle = 0;
  std::string name;
  std::int64_t createdAt = 0;
  std::vector<PageRec> pages;
};

struct ElementLocation {
  BoardRec* board = nullptr;
  PageRec* page = nullptr;
  int index = -1;  // position inside page->elements
};

class SceneStore {
 public:
  static SceneStore& instance();

  /// Callers MUST hold this for the duration of a domain handler.
  std::mutex& mutex();

  // --- Board ---------------------------------------------------------------
  /// Creates a board with one default page ("页面 1"). Returns the handle.
  std::uint64_t createBoard(const nlohmann::json& options);
  bool destroyBoard(std::uint64_t handle);
  BoardRec* findBoardByHandle(std::uint64_t handle);
  BoardRec* findBoardById(const std::string& boardId);

  // --- Page ----------------------------------------------------------------
  /// Finds a page; when `ownerOut` is given, receives the owning board.
  PageRec* findPage(const std::string& pageId, BoardRec** ownerOut = nullptr);
  std::string newPageId();

  // --- Element -------------------------------------------------------------
  ElementLocation findElement(const std::string& elementId);
  std::string newElementId();

  // --- Summaries -----------------------------------------------------------
  static nlohmann::json pageSummary(const PageRec& page);
  static nlohmann::json boardSummary(const BoardRec& board);
  static nlohmann::json elementSummary(const nlohmann::json& element);

 private:
  SceneStore() = default;

  std::mutex mutex_;
  std::map<std::uint64_t, BoardRec> boards_;
  std::uint64_t nextHandle_ = 1;
  int boardCounter_ = 0;
  int pageCounter_ = 0;
  int elementCounter_ = 0;
};

}  // namespace scene
}  // namespace wb
