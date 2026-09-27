#pragma once

// wb::base — point / size primitives. Contract file (Wave 0).

#include "wb/base/types.h"

namespace wb {

struct Point {
  float x = 0;
  float y = 0;
};

struct Size {
  float width = 0;
  float height = 0;
};

inline bool operator==(const Point& a, const Point& b) {
  return a.x == b.x && a.y == b.y;
}

inline Point operator+(const Point& a, const Point& b) {
  return Point{a.x + b.x, a.y + b.y};
}

inline Point operator-(const Point& a, const Point& b) {
  return Point{a.x - b.x, a.y - b.y};
}

}  // namespace wb
