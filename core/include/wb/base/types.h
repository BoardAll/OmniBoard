#pragma once

// wb::base — foundational type aliases shared by every module.
// Contract file: owned by Wave 0 (contract phase). Do not modify without
// coordination — all task packages depend on these definitions.

#include <cstdint>
#include <string>

namespace wb {

using Handle = std::uint64_t;
using ElementId = std::string;
using PageId = std::string;
using BoardId = std::string;
using UserId = std::string;
using ToolId = std::string;
using Timestamp = std::int64_t;

constexpr Handle kInvalidHandle = 0;

}  // namespace wb
