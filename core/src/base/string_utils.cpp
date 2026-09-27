// base/string_utils.cpp — small string helpers (task package 1.1).
// Owns: core/src/base. See wb/base/string_utils.h for the contract.

#include "wb/base/string_utils.h"

#include <algorithm>
#include <cctype>

namespace wb {

std::vector<std::string> split(const std::string& s, char delim) {
  std::vector<std::string> parts;
  std::string current;
  for (char c : s) {
    if (c == delim) {
      parts.push_back(current);
      current.clear();
    } else {
      current.push_back(c);
    }
  }
  parts.push_back(current);
  return parts;
}

std::string join(const std::vector<std::string>& parts, const std::string& sep) {
  std::string result;
  for (std::size_t i = 0; i < parts.size(); ++i) {
    if (i > 0) {
      result += sep;
    }
    result += parts[i];
  }
  return result;
}

std::string trim(const std::string& s) {
  auto isSpace = [](unsigned char c) { return std::isspace(c) != 0; };
  std::size_t begin = 0;
  std::size_t end = s.size();
  while (begin < end && isSpace(static_cast<unsigned char>(s[begin]))) {
    ++begin;
  }
  while (end > begin && isSpace(static_cast<unsigned char>(s[end - 1]))) {
    --end;
  }
  return s.substr(begin, end - begin);
}

bool startsWith(const std::string& s, const std::string& prefix) {
  return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

bool endsWith(const std::string& s, const std::string& suffix) {
  return s.size() >= suffix.size() &&
         s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string toLower(const std::string& s) {
  std::string result = s;
  std::transform(result.begin(), result.end(), result.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return result;
}

}  // namespace wb
