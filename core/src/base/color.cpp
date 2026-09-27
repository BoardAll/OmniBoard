// base/color.cpp — RGBA color helpers (task package 1.1).
// Owns: core/src/base. See wb/base/color.h for the contract.

#include "wb/base/color.h"

#include <cstdio>
#include <string>

namespace wb {
namespace {

int HexValue(char c) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  if (c >= 'A' && c <= 'F') {
    return c - 'A' + 10;
  }
  return -1;
}

}  // namespace

Color Color::fromHex(const std::string& hex) {
  std::string s = hex;
  if (!s.empty() && s.front() == '#') {
    s.erase(s.begin());
  }
  if (s.size() != 6 && s.size() != 8) {
    return Color{};
  }
  int values[8];
  for (std::size_t i = 0; i < s.size(); ++i) {
    values[i] = HexValue(s[i]);
    if (values[i] < 0) {
      return Color{};
    }
  }
  Color color;
  color.r = static_cast<std::uint8_t>(values[0] * 16 + values[1]);
  color.g = static_cast<std::uint8_t>(values[2] * 16 + values[3]);
  color.b = static_cast<std::uint8_t>(values[4] * 16 + values[5]);
  color.a = s.size() == 8 ? static_cast<std::uint8_t>(values[6] * 16 + values[7]) : 255;
  return color;
}

std::string Color::toHex() const {
  char buffer[10];
  std::snprintf(buffer, sizeof(buffer), "#%02X%02X%02X%02X", static_cast<unsigned>(r),
                static_cast<unsigned>(g), static_cast<unsigned>(b),
                static_cast<unsigned>(a));
  return std::string(buffer);
}

}  // namespace wb
