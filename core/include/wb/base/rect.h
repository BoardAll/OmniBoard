#pragma once

// wb::base — axis-aligned rectangle. Contract file (Wave 0).

#include "wb/base/point.h"

namespace wb {

struct Rect {
  float x = 0;
  float y = 0;
  float width = 0;
  float height = 0;

  float left() const { return x; }
  float top() const { return y; }
  float right() const { return x + width; }
  float bottom() const { return y + height; }

  bool empty() const { return width <= 0 || height <= 0; }

  bool contains(const Point& p) const {
    return p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height;
  }

  bool intersects(const Rect& other) const {
    return !(other.x > right() || other.right() < x || other.y > bottom() ||
             other.bottom() < y);
  }

  Rect unionWith(const Rect& other) const {
    const float nx = x < other.x ? x : other.x;
    const float ny = y < other.y ? y : other.y;
    const float nr = right() > other.right() ? right() : other.right();
    const float nb = bottom() > other.bottom() ? bottom() : other.bottom();
    return Rect{nx, ny, nr - nx, nb - ny};
  }
};

inline bool operator==(const Rect& a, const Rect& b) {
  return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

}  // namespace wb
