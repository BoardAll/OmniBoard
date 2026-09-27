// model/board_registry.cpp — domain "board" (task package 1.3).
// Owns: core/src/model.
//
// Ops:
//   create  {name?, page?} -> {"handle":N, "board":{...}}  (auto page "页面 1")
//   destroy {handle}       -> {"handle":N}
//   get     {handle}       -> {"board":{...}}

#include <string>

#include <nlohmann/json.hpp>

#include "scene_store.h"
#include "wb/ffi/domain.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

class BoardDomain : public DomainHandler {
 public:
  std::string name() const override { return "board"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    std::lock_guard<std::mutex> lock(scene::SceneStore::instance().mutex());
    scene::SceneStore& store = scene::SceneStore::instance();
    const nlohmann::json args = ParseArgs(argsJson);

    if (op == "create") {
      const std::uint64_t boardHandle = store.createBoard(args);
      scene::BoardRec* board = store.findBoardByHandle(boardHandle);
      nlohmann::json result;
      result["handle"] = boardHandle;
      result["board"] = scene::SceneStore::boardSummary(*board);
      return domainOk(result.dump());
    }
    if (op == "destroy") {
      if (!args.contains("handle") || !args["handle"].is_number()) {
        return domainError("InvalidArgument", "args.handle is required");
      }
      const std::uint64_t boardHandle = args["handle"].get<std::uint64_t>();
      if (!store.destroyBoard(boardHandle)) {
        return domainError("NotFound", "unknown board handle");
      }
      nlohmann::json result;
      result["handle"] = boardHandle;
      return domainOk(result.dump());
    }
    if (op == "get") {
      if (!args.contains("handle") || !args["handle"].is_number()) {
        return domainError("InvalidArgument", "args.handle is required");
      }
      scene::BoardRec* board =
          store.findBoardByHandle(args["handle"].get<std::uint64_t>());
      if (board == nullptr) {
        return domainError("NotFound", "unknown board handle");
      }
      return domainOk(nlohmann::json{{"board", scene::SceneStore::boardSummary(*board)}}.dump());
    }
    return domainError("NotFound", "unknown board op: " + op);
  }
};

}  // namespace

WB_REGISTER_DOMAIN(BoardDomain)

}  // namespace wb
