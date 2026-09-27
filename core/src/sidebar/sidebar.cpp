// sidebar/sidebar.cpp — domain "sidebar" (task package 1.4).
// Owns: core/src/sidebar.
//
// Ops (《左侧栏与页面管理设计》):
//   toggle   {stateId}         -> flip collapsed
//   setWidth {stateId, width}  -> clamp to [200, 320]
//   get      {stateId}         -> read (state auto-created on first access)
//   reset    {stateId}         -> restore defaults
// All ops respond {"sidebar":{"stateId","collapsed","width","effectiveWidth"}}.
//
// The design fixes the expanded default width at 240 px, the collapsed strip
// at 56 px and the drag range at 200..320 px. The FFI surface has no explicit
// "create" call, so a state is opaque and created lazily per stateId
// ("" resolves to the default state "sidebar-1").

#include <map>
#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

#include "wb/ffi/domain.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

constexpr int kDefaultWidth = 240;
constexpr int kCollapsedWidth = 56;
constexpr int kMinWidth = 200;
constexpr int kMaxWidth = 320;

struct SidebarState {
  bool collapsed = false;
  int width = kDefaultWidth;
};

class SidebarDomain : public DomainHandler {
 public:
  std::string name() const override { return "sidebar"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "toggle") return Toggle(args);
    if (op == "setWidth") return SetWidth(args);
    if (op == "get") return Get(args);
    if (op == "reset") return Reset(args);
    return domainError("NotFound", "unknown sidebar op: " + op);
  }

 private:
  static std::string ResolveId(const nlohmann::json& args) {
    const std::string stateId = args.value("stateId", std::string());
    return stateId.empty() ? std::string("sidebar-1") : stateId;
  }

  nlohmann::json ToJson(const std::string& stateId, const SidebarState& state) {
    nlohmann::json sidebar;
    sidebar["stateId"] = stateId;
    sidebar["collapsed"] = state.collapsed;
    sidebar["width"] = state.width;
    sidebar["effectiveWidth"] = state.collapsed ? kCollapsedWidth : state.width;
    return sidebar;
  }

  SidebarState& Ensure(const std::string& stateId) {
    std::lock_guard<std::mutex> lock(mutex_);
    return states_[stateId];
  }

  std::string Toggle(const nlohmann::json& args) {
    const std::string stateId = ResolveId(args);
    SidebarState& state = Ensure(stateId);
    state.collapsed = !state.collapsed;
    return domainOk(nlohmann::json{{"sidebar", ToJson(stateId, state)}}.dump());
  }

  std::string SetWidth(const nlohmann::json& args) {
    const std::string stateId = ResolveId(args);
    SidebarState& state = Ensure(stateId);
    if (args.contains("width") && args["width"].is_number_integer()) {
      int width = args["width"].get<int>();
      width = width < kMinWidth ? kMinWidth : width;
      width = width > kMaxWidth ? kMaxWidth : width;
      state.width = width;
    }
    return domainOk(nlohmann::json{{"sidebar", ToJson(stateId, state)}}.dump());
  }

  std::string Get(const nlohmann::json& args) {
    const std::string stateId = ResolveId(args);
    SidebarState& state = Ensure(stateId);
    return domainOk(nlohmann::json{{"sidebar", ToJson(stateId, state)}}.dump());
  }

  std::string Reset(const nlohmann::json& args) {
    const std::string stateId = ResolveId(args);
    SidebarState& state = Ensure(stateId);
    state.collapsed = false;
    state.width = kDefaultWidth;
    return domainOk(nlohmann::json{{"sidebar", ToJson(stateId, state)}}.dump());
  }

  std::mutex mutex_;
  std::map<std::string, SidebarState> states_;
};

}  // namespace

WB_REGISTER_DOMAIN(SidebarDomain)

}  // namespace wb
