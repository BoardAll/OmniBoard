// theme/theme.cpp — domain "theme" (task package 1.4).
// Owns: core/src/theme.
//
// Ops (《主题与背景系统设计》§3-5):
//   list    {}            -> {"themes":[{id,name,primary,canvas,dark}...],"count":9}
//   current {}            -> {"theme":{full tokens}}
//   load    {theme}       -> theme may be a built-in id string, an object
//                            {"id":...} referencing a built-in, or a full
//                            custom theme object carrying "colors".
//                            -> {"theme":{full}, "source":"builtin|custom"}
//   get     {themeId}     -> {"theme":{full}} | NotFound
//
// Nine built-in themes per the design table, each expanded into the full
// token set: colors (bg.*, toolbar.*, radial.*, sidebar.bg, card.*),
// radius.s|m|l = 4|8|12 and opacity radial 0.9 / toolbar 0.95 / panel 1.0.
// The default current theme is "clean-professional".

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

struct ThemeSpec {
  const char* id;
  const char* name;
  bool dark;
  const char* primary;
  const char* canvas;    // bg.canvas
  const char* surface;   // bg.surface + sidebar.bg
  const char* elevated;  // bg.elevated + toolbar.bg + radial.bg + card.bg
  const char* hover;     // card.hover
  const char* border;    // card.border
  const char* icon;      // toolbar.icon
};

const ThemeSpec kThemes[] = {
    {"clean-professional", "清爽专业", false, "#3370FF", "#F7F8FA", "#FFFFFF",
     "#FFFFFF", "#F2F4F7", "#E4E7EC", "#475467"},
    {"dark-night", "暗夜", true, "#4C88FF", "#121417", "#1A1D24", "#23272F",
     "#2C313B", "#343A46", "#AAB2C0"},
    {"blackboard", "黑板", true, "#FFFFFF", "#1A1D21", "#23272B", "#2C3136",
     "#363C42", "#454C54", "#D0D5DD"},
    {"greenboard", "绿板", true, "#FFFFFF", "#1E3A2F", "#27493C", "#2F5647",
     "#386354", "#47755F", "#D5E8DD"},
    {"minimal", "极简黑白", false, "#000000", "#FFFFFF", "#F7F7F7", "#FFFFFF",
     "#EFEFEF", "#D9D9D9", "#1A1A1A"},
    {"hand-drawn", "手绘", false, "#8B5A2B", "#FDF6E3", "#FBF0D9", "#FFF9EC",
     "#F6E9CC", "#E3D5B5", "#6B4F2A"},
    {"cyber", "赛博", true, "#00E5FF", "#0A0E27", "#111633", "#1A2148",
     "#232B5C", "#2E3875", "#9BB8FF"},
    {"kids", "儿童", false, "#FF6B9D", "#FFF9E6", "#FFFFFF", "#FFFFFF",
     "#FFF0F5", "#FFD9E5", "#8A6D3B"},
    {"enterprise", "企业", false, "#1E5AA8", "#F5F7FA", "#FFFFFF", "#FFFFFF",
     "#EEF2F8", "#DCE3EE", "#40536B"},
};

constexpr std::size_t kThemeCount = sizeof(kThemes) / sizeof(kThemes[0]);

nlohmann::json BuildTheme(const ThemeSpec& spec) {
  nlohmann::json theme;
  theme["id"] = spec.id;
  theme["name"] = spec.name;
  theme["dark"] = spec.dark;
  nlohmann::json colors;
  colors["bg.canvas"] = spec.canvas;
  colors["bg.surface"] = spec.surface;
  colors["bg.elevated"] = spec.elevated;
  colors["primary"] = spec.primary;
  colors["toolbar.bg"] = spec.elevated;
  colors["toolbar.icon"] = spec.icon;
  colors["toolbar.active"] = spec.primary;
  colors["radial.bg"] = spec.elevated;
  colors["radial.highlight"] = spec.primary;
  colors["sidebar.bg"] = spec.surface;
  colors["card.bg"] = spec.elevated;
  colors["card.hover"] = spec.hover;
  colors["card.border"] = spec.border;
  theme["colors"] = std::move(colors);
  nlohmann::json radius;
  radius["s"] = 4;
  radius["m"] = 8;
  radius["l"] = 12;
  theme["radius"] = std::move(radius);
  nlohmann::json opacity;
  opacity["radial"] = 0.9;
  opacity["toolbar"] = 0.95;
  opacity["panel"] = 1.0;
  theme["opacity"] = std::move(opacity);
  return theme;
}

const ThemeSpec* FindSpec(const std::string& id) {
  for (const ThemeSpec& spec : kThemes) {
    if (id == spec.id) return &spec;
  }
  return nullptr;
}

class ThemeDomain : public DomainHandler {
 public:
  ThemeDomain() : current_(BuildTheme(kThemes[0])) {}

  std::string name() const override { return "theme"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "list") return List();
    if (op == "current") return Current();
    if (op == "load") return Load(args);
    if (op == "get") return Get(args);
    return domainError("NotFound", "unknown theme op: " + op);
  }

 private:
  std::string List() {
    nlohmann::json themes = nlohmann::json::array();
    for (const ThemeSpec& spec : kThemes) {
      nlohmann::json item;
      item["id"] = spec.id;
      item["name"] = spec.name;
      item["primary"] = spec.primary;
      item["canvas"] = spec.canvas;
      item["dark"] = spec.dark;
      themes.push_back(std::move(item));
    }
    nlohmann::json result;
    result["themes"] = std::move(themes);
    result["count"] = static_cast<int>(kThemeCount);
    return domainOk(result.dump());
  }

  std::string Current() {
    std::lock_guard<std::mutex> lock(mutex_);
    return domainOk(nlohmann::json{{"theme", current_}}.dump());
  }

  std::string Load(const nlohmann::json& args) {
    const nlohmann::json requested = args.value("theme", nlohmann::json());
    if (requested.is_string()) {
      return LoadBuiltin(requested.get<std::string>());
    }
    if (requested.is_object()) {
      if (requested.contains("colors") && requested["colors"].is_object()) {
        // Custom theme: keep verbatim, defaulting id/name when absent.
        nlohmann::json theme = requested;
        theme["id"] = requested.value("id", "custom");
        theme["name"] = requested.value("name", "自定义主题");
        theme["dark"] = requested.value("dark", false);
        std::lock_guard<std::mutex> lock(mutex_);
        current_ = std::move(theme);
        nlohmann::json result;
        result["theme"] = current_;
        result["source"] = "custom";
        return domainOk(result.dump());
      }
      const std::string id = requested.value("id", std::string());
      if (!id.empty()) return LoadBuiltin(id);
    }
    return domainError("InvalidArgument", "args.theme is required");
  }

  std::string LoadBuiltin(const std::string& id) {
    const ThemeSpec* spec = FindSpec(id);
    if (spec == nullptr) {
      return domainError("NotFound", "unknown theme: " + id);
    }
    nlohmann::json theme = BuildTheme(*spec);
    std::lock_guard<std::mutex> lock(mutex_);
    current_ = theme;
    nlohmann::json result;
    result["theme"] = std::move(theme);
    result["source"] = "builtin";
    return domainOk(result.dump());
  }

  std::string Get(const nlohmann::json& args) {
    const std::string themeId = args.value("themeId", std::string());
    const ThemeSpec* spec = FindSpec(themeId);
    if (spec == nullptr) {
      return domainError("NotFound", "unknown theme: " + themeId);
    }
    return domainOk(nlohmann::json{{"theme", BuildTheme(*spec)}}.dump());
  }

  std::mutex mutex_;
  nlohmann::json current_;
};

}  // namespace

WB_REGISTER_DOMAIN(ThemeDomain)

}  // namespace wb
