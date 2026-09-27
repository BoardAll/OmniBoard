// render/render.cpp — domain "render" (task package 1.4).
// Owns: core/src/render.
//
// Ops (《渲染引擎设计》§3-6/13-15):
//   getDisplayList {pageId, layer?}   -> ordered draw list + dirty rect
//   thumbnail      {pageId, width?, height?}
//                                     -> {"thumbnail":{...}} (cached)
//   cacheStats     {}                 -> {"cache":{...}}
//   cacheClear     {}                 -> {"cleared":N, "bytes":freed}
//   perfStats      {}                 -> {"frames","lastFrameMs","avgFrameMs",
//                                         "fps","drawCalls"}
//   recordFrame    {frameMs, drawCalls?}  -> engine/UI feeds one frame
//
// Elements are emitted in z-order (ascending) with their render layer:
//   render3d -> Render3D, render2d -> Render2D, function -> Function,
//   annotation -> Annotation, document -> Document, everything else Dynamic.
// Hidden elements are skipped; the dirty rect unions the rotation-aware
// AABBs of the emitted items. Thumbnails are keyed "thumb:<page>:<w>x<h>"
// in a bounded cache (256 entries, oldest evicted first).

#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>
#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

#include "../model/geom_math.h"
#include "../model/scene_store.h"
#include "wb/ffi/domain.h"

namespace wb {
namespace {

using scene::SceneStore;
using scene::PageRec;

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

std::string Lower(std::string text) {
  for (char& c : text) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  return text;
}

std::string LayerOf(const std::string& type) {
  if (type == "render3d" || type == "3d") return "Render3D";
  if (type == "render2d" || type == "2d") return "Render2D";
  if (type == "function") return "Function";
  if (type == "annotation") return "Annotation";
  if (type == "document") return "Document";
  return "Dynamic";
}

constexpr std::size_t kMaxCacheEntries = 256;

struct CacheState {
  std::mutex mutex;
  std::map<std::string, std::size_t> entries;  // key -> bytes
  std::size_t bytes = 0;
  long long hits = 0;
  long long misses = 0;
};

struct PerfState {
  std::mutex mutex;
  long long frames = 0;
  long long drawCalls = 0;
  double lastFrameMs = 0.0;
  double totalFrameMs = 0.0;
};

CacheState& Cache() {
  static CacheState state;
  return state;
}

PerfState& Perf() {
  static PerfState state;
  return state;
}

/// Inserts or refreshes a cache entry; returns true when it was a hit.
bool CacheTouch(const std::string& key, std::size_t bytes) {
  CacheState& cache = Cache();
  std::lock_guard<std::mutex> lock(cache.mutex);
  auto it = cache.entries.find(key);
  if (it != cache.entries.end()) {
    ++cache.hits;
    return true;
  }
  ++cache.misses;
  if (cache.entries.size() >= kMaxCacheEntries && !cache.entries.empty()) {
    auto oldest = cache.entries.begin();
    cache.bytes -= oldest->second;
    cache.entries.erase(oldest);
  }
  cache.entries[key] = bytes;
  cache.bytes += bytes;
  return false;
}

class RenderDomain : public DomainHandler {
 public:
  std::string name() const override { return "render"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "getDisplayList") return GetDisplayList(args);
    if (op == "thumbnail") return Thumbnail(args);
    if (op == "cacheStats") return CacheStats();
    if (op == "cacheClear") return CacheClear();
    if (op == "perfStats") return PerfStats();
    if (op == "recordFrame") return RecordFrame(args);
    return domainError("NotFound", "unknown render op: " + op);
  }

 private:
  std::string GetDisplayList(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    const std::string layerFilter =
        args.contains("layer") && args["layer"].is_string()
            ? Lower(args["layer"].get<std::string>())
            : std::string();

    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }

    nlohmann::json items = nlohmann::json::array();
    float dirty[4] = {0.0f, 0.0f, -1.0f, -1.0f};
    bool hasDirty = false;
    for (std::size_t i = 0; i < page->elements.size(); ++i) {
      const nlohmann::json& element = page->elements[i];
      if (element.value("hidden", false)) continue;
      const std::string type = element.value("type", std::string());
      const std::string layer = LayerOf(type);
      if (!layerFilter.empty() && Lower(layer) != layerFilter) continue;

      const Rect rect = scene::ElementRect(element);
      nlohmann::json item;
      item["elementId"] = element.value("id", std::string());
      item["type"] = type;
      item["layer"] = layer;
      item["zIndex"] = static_cast<int>(i);
      item["opacity"] = scene::NumberOr(element, "opacity", 1.0f);
      item["rotation"] = scene::NumberOr(element, "rotation", 0.0f);
      nlohmann::json bounds;
      bounds["x"] = rect.x;
      bounds["y"] = rect.y;
      bounds["width"] = rect.width;
      bounds["height"] = rect.height;
      item["bounds"] = std::move(bounds);
      items.push_back(std::move(item));

      float aabb[4];
      scene::ElementAabb(element, aabb);
      if (!hasDirty) {
        dirty[0] = aabb[0];
        dirty[1] = aabb[1];
        dirty[2] = aabb[2];
        dirty[3] = aabb[3];
        hasDirty = true;
      } else {
        dirty[0] = std::min(dirty[0], aabb[0]);
        dirty[1] = std::min(dirty[1], aabb[1]);
        dirty[2] = std::max(dirty[2], aabb[2]);
        dirty[3] = std::max(dirty[3], aabb[3]);
      }
    }

    nlohmann::json result;
    result["pageId"] = pageId;
    result["layer"] = layerFilter.empty() ? "all" : layerFilter;
    result["count"] = static_cast<int>(items.size());
    result["items"] = std::move(items);
    result["background"] = page->background;
    result["pageHidden"] = page->hidden;
    if (hasDirty) {
      nlohmann::json rect;
      rect["x"] = dirty[0];
      rect["y"] = dirty[1];
      rect["width"] = dirty[2] - dirty[0];
      rect["height"] = dirty[3] - dirty[1];
      result["dirtyRect"] = std::move(rect);
    } else {
      result["dirtyRect"] = nullptr;
    }
    return domainOk(result.dump());
  }

  std::string Thumbnail(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    int width = args.value("width", 200);
    int height = args.value("height", 125);
    width = std::max(16, std::min(width, 1024));
    height = std::max(16, std::min(height, 1024));

    int elementCount = 0;
    nlohmann::json background;
    {
      std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
      PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
      if (page == nullptr) {
        return domainError("NotFound", "unknown page: " + pageId);
      }
      elementCount = static_cast<int>(page->elements.size());
      background = page->background;
    }

    const std::string cacheKey = "thumb:" + pageId + ":" +
                                 std::to_string(width) + "x" +
                                 std::to_string(height);
    CacheTouch(cacheKey, static_cast<std::size_t>(width) * height * 4u);

    nlohmann::json thumbnail;
    thumbnail["pageId"] = pageId;
    thumbnail["format"] = "rgba";
    thumbnail["width"] = width;
    thumbnail["height"] = height;
    thumbnail["cacheKey"] = cacheKey;
    thumbnail["bytes"] = width * height * 4;
    thumbnail["elementCount"] = elementCount;
    thumbnail["background"] = std::move(background);
    return domainOk(nlohmann::json{{"thumbnail", std::move(thumbnail)}}.dump());
  }

  std::string CacheStats() {
    CacheState& cache = Cache();
    std::lock_guard<std::mutex> lock(cache.mutex);
    const long long total = cache.hits + cache.misses;
    nlohmann::json stats;
    stats["entries"] = static_cast<int>(cache.entries.size());
    stats["maxEntries"] = static_cast<int>(kMaxCacheEntries);
    stats["bytes"] = static_cast<std::int64_t>(cache.bytes);
    stats["hits"] = cache.hits;
    stats["misses"] = cache.misses;
    stats["hitRate"] = total > 0
                           ? static_cast<double>(cache.hits) /
                                 static_cast<double>(total)
                           : 0.0;
    return domainOk(nlohmann::json{{"cache", std::move(stats)}}.dump());
  }

  std::string CacheClear() {
    CacheState& cache = Cache();
    std::lock_guard<std::mutex> lock(cache.mutex);
    const std::size_t cleared = cache.entries.size();
    const std::size_t freed = cache.bytes;
    cache.entries.clear();
    cache.bytes = 0;
    nlohmann::json result;
    result["cleared"] = static_cast<int>(cleared);
    result["bytes"] = static_cast<std::int64_t>(freed);
    return domainOk(result.dump());
  }

  std::string PerfStats() {
    PerfState& perf = Perf();
    std::lock_guard<std::mutex> lock(perf.mutex);
    return domainOk(PerfPayload(perf).dump());
  }

  std::string RecordFrame(const nlohmann::json& args) {
    const double frameMs = args.contains("frameMs") && args["frameMs"].is_number()
                               ? args["frameMs"].get<double>()
                               : 0.0;
    const long long drawCalls =
        args.contains("drawCalls") && args["drawCalls"].is_number_integer()
            ? args["drawCalls"].get<long long>()
            : 0;
    PerfState& perf = Perf();
    std::lock_guard<std::mutex> lock(perf.mutex);
    ++perf.frames;
    perf.lastFrameMs = frameMs;
    perf.totalFrameMs += frameMs;
    perf.drawCalls += drawCalls;
    return domainOk(PerfPayload(perf).dump());
  }

  static nlohmann::json PerfPayload(const PerfState& perf) {
    const double avg =
        perf.frames > 0 ? perf.totalFrameMs / static_cast<double>(perf.frames)
                        : 0.0;
    nlohmann::json result;
    result["frames"] = perf.frames;
    result["lastFrameMs"] = perf.lastFrameMs;
    result["avgFrameMs"] = avg;
    result["fps"] = avg > 0.0 ? 1000.0 / avg : 0.0;
    result["drawCalls"] = perf.drawCalls;
    return result;
  }
};

}  // namespace

WB_REGISTER_DOMAIN(RenderDomain)

}  // namespace wb
