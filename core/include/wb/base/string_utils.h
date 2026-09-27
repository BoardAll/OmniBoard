#pragma once

// wb::base — small string helpers. Contract file (Wave 0).

#include <string>
#include <vector>

namespace wb {

std::vector<std::string> split(const std::string& s, char delim);

std::string join(const std::vector<std::string>& parts, const std::string& sep);

std::string trim(const std::string& s);

bool startsWith(const std::string& s, const std::string& prefix);

bool endsWith(const std::string& s, const std::string& suffix);

std::string toLower(const std::string& s);

}  // namespace wb
