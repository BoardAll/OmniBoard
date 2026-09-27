#pragma once

// wb::base — RGBA color. Contract file (Wave 0).

#include <cstdint>
#include <string>

namespace wb {

struct Color {
  std::uint8_t r = 0;
  std::uint8_t g = 0;
  std::uint8_t b = 0;
  std::uint8_t a = 255;

  // Parses "#RRGGBB" or "#RRGGBBAA" (leading '#' optional). Returns black on
  // malformed input.
  static Color fromHex(const std::string& hex);

  // Serializes to "#RRGGBBAA".
  std::string toHex() const;
};

inline bool operator==(const Color& c1, const Color& c2) {
  return c1.r == c2.r && c1.g == c2.g && c1.b == c2.b && c1.a == c2.a;
}

}  // namespace wb
