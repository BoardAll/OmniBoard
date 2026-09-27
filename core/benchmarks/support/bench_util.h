#pragma once

// tests/../benchmarks/support/bench_util.h — 基准共享支持头（Wave 4.1）。
//
// 与 integration/support/test_probe.h 同源的轻量字符串探针（wb_benchmarks
// 未链接 nlohmann 的 include 路径），供各基准文件做建景与冒烟校验。
// 本文件位于 support/ 子目录且为 .h，不会被 benchmarks/CMakeLists.txt 的
// GLOB（*.cpp）收集为独立编译单元。
//
// 提示：nlohmann::json 对象按键字典序 dump；基准只做存在性/数值探针，
// 不依赖键序细节（除注明外）。

#include <cstdlib>
#include <string>

#include "wb/ffi/domain.h"
#include "wb/wb.h"

// --- 基础字符串探针 ---------------------------------------------------------

inline bool JsonContains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

/// 首次出现的 "key":"..." 字符串值；不存在返回 ""。
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

/// json 中 "key":true/false 出现次数。
inline int JsonBoolCount(const std::string& json, const std::string& key,
                         bool expected) {
  const std::string needle = "\"" + key + "\":" + (expected ? "true" : "false");
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
};

/// 创建一块白板（含默认页）；解析出 handle / boardId / 第一页 id。
inline Scene MakeScene() {
  Scene scene;
  const std::string raw = wb::invokeDomain("board", "create", "{}");
  scene.ok = JsonBool(raw, "ok", true);
  scene.boardId = JsonStringAt(raw, "id", 0);
  scene.pageId = JsonStringAfter(raw, "id", "\"pages\"");
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

/// 一个标准矩形元素的 JSON（position/size 嵌套结构）。
inline std::string RectElement(float x, float y, float w, float h,
                               const std::string& text = std::string()) {
  std::string body = "{\"type\":\"rect\",\"position\":{\"x\":" +
                     std::to_string(x) + ",\"y\":" + std::to_string(y) +
                     "},\"size\":{\"width\":" + std::to_string(w) +
                     ",\"height\":" + std::to_string(h) + "}";
  if (!text.empty()) body += ",\"text\":\"" + text + "\"";
  return body + "}";
}
