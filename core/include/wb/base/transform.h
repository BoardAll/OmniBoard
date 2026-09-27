#pragma once

// wb::base — 2D affine transform (a b c d e f / column-major per Skia order).
// Contract file (Wave 0).

namespace wb {

struct Transform {
  float m[6] = {1, 0, 0, 1, 0, 0};

  static Transform identity() { return Transform{}; }

  static Transform translation(float tx, float ty) {
    return Transform{1, 0, 0, 1, tx, ty};
  }

  static Transform scale(float sx, float sy) {
    return Transform{sx, 0, 0, sy, 0, 0};
  }

  static Transform rotation(float radians);
};

}  // namespace wb
