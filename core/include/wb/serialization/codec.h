#pragma once

// wb::serialization — scene binary codec (task package 1.1).
// Owns: core/src/serialization + this header.
//
// Binary layout (little-endian), per《C++ 核心引擎接口设计》§14:
//   offset 0  : magic "WBB1"        (4 bytes)
//   offset 4  : format version      (uint32, currently 1)
//   offset 8  : payload size        (uint64, bytes of the JSON payload)
//   offset 16 : UTF-8 JSON payload  (scene document)
//   trailing  : CRC32 of header+payload (uint32, IEEE/zip polynomial)

#include <cstdint>
#include <cstddef>
#include <string>

#include "wb/base/error.h"

namespace wb {

/// CRC32 (IEEE 802.3 / zip), table-free bitwise implementation.
std::uint32_t crc32(const std::uint8_t* data, std::size_t length);

/// Wraps `jsonPayload` (must be valid UTF-8 JSON) into the binary container.
/// Returns the byte string; on malformed JSON returns empty string.
std::string encodeBinary(const std::string& jsonPayload);

/// Parses the binary container. Fails with InvalidArgument for a bad magic /
/// version / size mismatch / CRC mismatch, and for a payload that is not
/// valid JSON.
Result<std::string> decodeBinary(const std::string& bytes);

constexpr std::uint32_t kBinaryFormatVersion = 1;
constexpr std::size_t kBinaryHeaderSize = 16;
constexpr std::size_t kBinaryCrcSize = 4;

}  // namespace wb
