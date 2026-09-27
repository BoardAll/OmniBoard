// base/transform.cpp — affine transform helpers (task package 1.1).
// Owns: core/src/base. See wb/base/transform.h for the contract.

#include "wb/base/transform.h"

#include <cmath>

namespace wb {

Transform Transform::rotation(float radians) {
  const float c = std::cos(radians);
  const float s = std::sin(radians);
  // Column-major Skia order: [a b c d e f] => x' = a*x + c*y + e.
  return Transform{c, s, -s, c, 0, 0};
}

}  // namespace wb
