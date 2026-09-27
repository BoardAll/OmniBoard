#pragma once

// tests/unit/support/scene_probe.h — helpers shared by the package-1.3 domain
// tests (model / page / element / geometry / layout).
//
// wb_tests links only wb::core + Catch2 and has no nlohmann/json include
// path, so domain responses are inspected with plain string probes.

#include <cstdlib>
#include <string>
#include <vector>

#include "wb/ffi/domain.h"

inline bool JsonContains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

/// String value of the first "key":"..." at/after `from`; "" when absent.
inline std::string JsonStringAt(const std::string& json, const std::string& key,
                                std::size_t from = 0) {
  const std::string needle = "\"" + key + "\":\"";
  const std::size_t pos = json.find(needle, from);
  if (pos == std::string::npos) return std::string();
  const std::size_t valueStart = pos + needle.size();
  const std::size_t end = json.find('"', valueStart);
  return end == std::string::npos ? std::string()
                                  : json.substr(valueStart, end - valueStart);
}

inline std::string JsonString(const std::string& json, const std::string& key) {
  return JsonStringAt(json, key, 0);
}

/// Numeric value of the first "key":N at/after `from`; *ok=false when absent
/// or when the value is not a number.
inline double JsonNumberAt(const std::string& json, const std::string& key,
                           std::size_t from = 0, bool* ok = nullptr) {
  const std::string needle = "\"" + key + "\":";
  const std::size_t pos = json.find(needle, from);
  if (pos == std::string::npos) {
    if (ok != nullptr) *ok = false;
    return 0.0;
  }
  const std::size_t valueStart = pos + needle.size();
  if (valueStart >= json.size()) {
    if (ok != nullptr) *ok = false;
    return 0.0;
  }
  const char first = json[valueStart];
  if (first == '"' || first == 't' || first == 'f' || first == 'n') {
    if (ok != nullptr) *ok = false;
    return 0.0;
  }
  const char* start = json.c_str() + valueStart;
  char* end = nullptr;
  const double value = std::strtod(start, &end);
  if (ok != nullptr) *ok = end != start;
  return value;
}

inline double JsonNumber(const std::string& json, const std::string& key,
                         bool* ok = nullptr) {
  return JsonNumberAt(json, key, 0, ok);
}

inline bool JsonBool(const std::string& json, const std::string& key, bool expected) {
  return json.find("\"" + key + "\":" + (expected ? "true" : "false")) !=
         std::string::npos;
}

/// Builds ["id1","id2",...] for elementIds-style arguments.
inline std::string JsonIdArray(const std::vector<std::string>& ids) {
  std::string out = "[";
  for (std::size_t i = 0; i < ids.size(); ++i) {
    if (i > 0) out += ",";
    out += "\"" + ids[i] + "\"";
  }
  return out + "]";
}

// --- Scene helpers -----------------------------------------------------------

/// Creates a board with its default page. Returns the FFI handle (0 on error);
/// when `responseOut` is set, receives the raw board.create response.
inline unsigned long long SceneNewBoard(std::string* responseOut = nullptr) {
  const std::string response = wb::invokeDomain("board", "create", "{}");
  if (responseOut != nullptr) *responseOut = response;
  bool ok = false;
  const double handle = JsonNumber(response, "handle", &ok);
  return ok && handle > 0.0 ? static_cast<unsigned long long>(handle) : 0ULL;
}

/// Board id of a board.create response (first "id" occurrence).
inline std::string SceneBoardId(const std::string& boardResponse) {
  return JsonStringAt(boardResponse, "id", 0);
}

/// First page id of a board.create response (first "id" inside "pages").
inline std::string SceneFirstPageId(const std::string& boardResponse) {
  const std::size_t pages = boardResponse.find("\"pages\"");
  return JsonStringAt(boardResponse, "id", pages == std::string::npos ? 0 : pages);
}

/// Creates an element from a raw JSON object body. Returns elementId or "".
inline std::string SceneCreateElement(const std::string& pageId,
                                      const std::string& elementJson) {
  const std::string response =
      wb::invokeDomain("element", "create",
                       "{\"pageId\":\"" + pageId + "\",\"element\":" +
                           elementJson + "}");
  return JsonBool(response, "ok", true) ? JsonString(response, "elementId")
                                        : std::string();
}
