#pragma once

// tests/integration/support/test_probe.h — 集成测试共享支持头（Wave 4.1）。
//
// 定位：跨模块链路测试（命令↔文档、页面↔元素、流程图/函数/3D↔渲染数据、
// CRDT 双副本、权限↔审计）使用的轻量断言工具。
//
// 注意：wb_tests 只链接 wb::core + Catch2，没有 nlohmann/json 的 include
// 路径，因此本文件与 unit 测试（tests/unit/support/scene_probe.h）一样，
// 全部基于纯字符串探针检查领域响应。本头文件位于 support/ 子目录且为
// .h，不会被 tests/CMakeLists.txt 的 GLOB（unit/*.cpp、integration/*.cpp）
// 收集为测试源。
//
// 提示：nlohmann::json 对象按键字典序 dump，例如 flowchart autoLayout 的
// result 输出顺序是 connectors（含 waypoints）在 nodes 之前；需要按子对象
// 定位数值时用 JsonNumbersAt 指定锚点。

#include <cctype>
#include <cstddef>
#include <cstdlib>
#include <string>
#include <vector>

#include "wb/ffi/domain.h"
#include "wb/wb.h"

// --- 基础字符串探针 ---------------------------------------------------------

inline bool JsonContains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

/// 首次出现的 "key":"..." 字符串值（from 之后）；不存在返回 ""。
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

/// anchor 之后第一个 "key":"..."，用于从响应中截取子对象内的 id。
inline std::string JsonStringAfter(const std::string& json,
                                   const std::string& key,
                                   const std::string& anchor) {
  const std::size_t pos = json.find(anchor);
  return JsonStringAt(json, key, pos == std::string::npos ? 0 : pos);
}

/// 首次出现的 "key":N 数字值；ok=false 表示缺失或非数字。
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

/// 收集 from 之后所有 "key":N 数字（按出现顺序）。
inline std::vector<double> JsonNumbersAt(const std::string& json,
                                         const std::string& key,
                                         std::size_t from) {
  std::vector<double> values;
  const std::string needle = "\"" + key + "\":";
  std::size_t pos = from;
  while ((pos = json.find(needle, pos)) != std::string::npos) {
    const std::size_t valueStart = pos + needle.size();
    if (valueStart < json.size()) {
      const char first = json[valueStart];
      if (first == '"' || first == 't' || first == 'f' || first == 'n') {
        pos = valueStart;
        continue;
      }
      const char* start = json.c_str() + valueStart;
      char* end = nullptr;
      const double value = std::strtod(start, &end);
      if (end != start) values.push_back(value);
    }
    pos = valueStart;
  }
  return values;
}

inline std::vector<double> JsonNumbers(const std::string& json,
                                       const std::string& key) {
  return JsonNumbersAt(json, key, 0);
}

/// json 中 "key":true/false 出现次数（用于计数断言）。
inline int JsonBoolCount(const std::string& json, const std::string& key,
                         bool expected) {
  const std::string needle =
      "\"" + key + "\":" + (expected ? "true" : "false");
  int count = 0;
  std::size_t pos = 0;
  while ((pos = json.find(needle, pos)) != std::string::npos) {
    ++count;
    pos += needle.size();
  }
  return count;
}

inline bool JsonBool(const std::string& json, const std::string& key,
                     bool expected) {
  return JsonBoolCount(json, key, expected) > 0;
}

/// 统计 needle 在 json 中出现的次数。
inline int CountOccurrences(const std::string& json, const std::string& needle) {
  int count = 0;
  std::size_t pos = 0;
  while ((pos = json.find(needle, pos)) != std::string::npos) {
    ++count;
    pos += needle.size();
  }
  return count;
}

/// 提取 "key":"..."（转义感知），返回保持转义形态的原始片段。
/// 用于比较 CRDT encodeState 的 state 内嵌 JSON 字符串是否逐字节一致。
inline std::string JsonEscapedString(const std::string& json,
                                     const std::string& key) {
  const std::string needle = "\"" + key + "\":\"";
  const std::size_t pos = json.find(needle);
  if (pos == std::string::npos) return std::string();
  std::string out;
  for (std::size_t i = pos + needle.size(); i < json.size(); ++i) {
    const char c = json[i];
    if (c == '\\' && i + 1 < json.size()) {
      out.push_back(c);
      out.push_back(json[++i]);
      continue;
    }
    if (c == '"') break;
    out.push_back(c);
  }
  return out;
}

/// "key":[...] 数组的顶层元素个数（字符串/转义感知的括号扫描）。
inline std::size_t JsonArrayLength(const std::string& json,
                                   const std::string& key) {
  const std::string needle = "\"" + key + "\":[";
  const std::size_t pos = json.find(needle);
  if (pos == std::string::npos) return 0;
  int depth = 1;
  bool inString = false;
  bool anyValue = false;
  std::size_t commas = 0;
  for (std::size_t i = pos + needle.size(); i < json.size() && depth > 0; ++i) {
    const char c = json[i];
    if (inString) {
      if (c == '\\') {
        ++i;
        continue;
      }
      if (c == '"') inString = false;
      continue;
    }
    if (c == '"') {
      inString = true;
      anyValue = true;
      continue;
    }
    if (c == '[' || c == '{') {
      ++depth;
      anyValue = true;
      continue;
    }
    if (c == ']' || c == '}') {
      --depth;
      if (depth == 0) break;
      continue;
    }
    if (c == ',') {
      if (depth == 1) ++commas;
      continue;
    }
    if (!std::isspace(static_cast<unsigned char>(c))) anyValue = true;
  }
  return anyValue ? commas + 1 : 0;
}

/// arrayJson：["a","b",...]；用于 elementIds 一类数组参数。
inline std::string JsonIdArray(const std::vector<std::string>& ids) {
  std::string out = "[";
  for (std::size_t i = 0; i < ids.size(); ++i) {
    if (i > 0) out += ",";
    out += "\"" + ids[i] + "\"";
  }
  return out + "]";
}

// --- FFI 辅助 ----------------------------------------------------------------

/// 释放 wb_* 返回的 const char*（wb_free）并返回 std::string 拷贝。
inline std::string TakeAndFree(const char* owned) {
  if (owned == nullptr) return std::string();
  std::string copy(owned);
  wb_free(owned);
  return copy;
}

// --- 场景辅助（跨模块） -------------------------------------------------------

struct Scene {
  bool ok = false;
  unsigned long long handle = 0;
  std::string boardId;
  std::string pageId;  // board.create 的默认第一页
  std::string raw;     // board.create 原始响应
};

/// 创建一块白板（含默认页）；解析出 handle / boardId / 第一页 id。
inline Scene MakeScene() {
  Scene scene;
  scene.raw = wb::invokeDomain("board", "create", "{}");
  bool handleOk = false;
  const double handle = JsonNumber(scene.raw, "handle", &handleOk);
  scene.ok = handleOk && JsonBool(scene.raw, "ok", true);
  scene.handle = handleOk ? static_cast<unsigned long long>(handle) : 0ULL;
  scene.boardId = JsonStringAt(scene.raw, "id", 0);
  scene.pageId = JsonStringAfter(scene.raw, "id", "\"pages\"");
  return scene;
}

/// 在该页创建元素（FFI 链路）。elementJson 为元素对象体；返回 elementId。
inline std::string CreateElement(const std::string& pageId,
                                 const std::string& elementJson) {
  const std::string response =
      TakeAndFree(wb_element_create(pageId.c_str(), elementJson.c_str()));
  return JsonBool(response, "ok", true) ? JsonString(response, "elementId")
                                        : std::string();
}

/// 一个标准矩形元素的 JSON（position/size 嵌套结构，render 层依赖）。
inline std::string RectElement(float x, float y, float w, float h,
                               const std::string& text = std::string()) {
  std::string body = "{\"type\":\"rect\",\"position\":{\"x\":" +
                     std::to_string(x) + ",\"y\":" + std::to_string(y) +
                     "},\"size\":{\"width\":" + std::to_string(w) +
                     ",\"height\":" + std::to_string(h) + "}";
  if (!text.empty()) body += ",\"text\":\"" + text + "\"";
  return body + "}";
}
