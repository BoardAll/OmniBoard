#pragma once

// model/geom_math.h — geometry math helpers (task package 1.3, INTERNAL).
// Pure functions used by the geometry/layout/element domains.

#include <cmath>

#include <nlohmann/json.hpp>

#include "wb/base/point.h"
#include "wb/base/rect.h"

namespace wb {
namespace scene {

constexpr float kDeg2Rad = 3.14159265358979323846f / 180.0f;

inline float NumberOr(const nlohmann::json& object, const char* key, float fallback) {
  return object.contains(key) && object[key].is_number() ? object[key].get<float>()
                                                         : fallback;
}

/// Reads element position/size with schema defaults.
inline Rect ElementRect(const nlohmann::json& element) {
  Rect rect;
  if (element.contains("position") && element["position"].is_object()) {
    rect.x = NumberOr(element["position"], "x", 0.0f);
    rect.y = NumberOr(element["position"], "y", 0.0f);
  }
  if (element.contains("size") && element["size"].is_object()) {
    rect.width = NumberOr(element["size"], "width", 0.0f);
    rect.height = NumberOr(element["size"], "height", 0.0f);
  }
  return rect;
}

inline float ElementRotationRadians(const nlohmann::json& element) {
  return NumberOr(element, "rotation", 0.0f) * kDeg2Rad;
}

inline Point RotateAround(float x, float y, float cx, float cy, float radians) {
  const float c = std::cos(radians);
  const float s = std::sin(radians);
  const float dx = x - cx;
  const float dy = y - cy;
  return Point{cx + dx * c - dy * s, cy + dx * s + dy * c};
}

/// Axis-aligned bounding box of a (possibly rotated) element:
/// out = {minX, minY, maxX, maxY}.
inline void ElementAabb(const nlohmann::json& element, float out[4]) {
  const Rect rect = ElementRect(element);
  const float cx = rect.x + rect.width / 2.0f;
  const float cy = rect.y + rect.height / 2.0f;
  const float rotation = ElementRotationRadians(element);
  const Point corners[4] = {
      RotateAround(rect.x, rect.y, cx, cy, rotation),
      RotateAround(rect.right(), rect.y, cx, cy, rotation),
      RotateAround(rect.right(), rect.bottom(), cx, cy, rotation),
      RotateAround(rect.x, rect.bottom(), cx, cy, rotation),
  };
  out[0] = out[1] = 1e30f;
  out[2] = out[3] = -1e30f;
  for (const Point& p : corners) {
    out[0] = p.x < out[0] ? p.x : out[0];
    out[1] = p.y < out[1] ? p.y : out[1];
    out[2] = p.x > out[2] ? p.x : out[2];
    out[3] = p.y > out[3] ? p.y : out[3];
  }
}

inline float PointSegmentDistance(float px, float py, float ax, float ay, float bx,
                                  float by) {
  const float vx = bx - ax;
  const float vy = by - ay;
  const float lengthSq = vx * vx + vy * vy;
  float t = 0.0f;
  if (lengthSq > 1e-9f) {
    t = ((px - ax) * vx + (py - ay) * vy) / lengthSq;
    t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
  }
  const float dx = px - (ax + t * vx);
  const float dy = py - (ay + t * vy);
  return std::sqrt(dx * dx + dy * dy);
}

}  // namespace scene
}  // namespace wb
