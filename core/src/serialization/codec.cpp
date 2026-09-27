// serialization/codec.cpp — scene binary codec (task package 1.1).
// Owns: core/src/serialization. See wb/serialization/codec.h for the layout.

#include "wb/serialization/codec.h"

#include <cstring>

#include <nlohmann/json.hpp>

namespace wb {
namespace {

void WriteU32(std::string& out, std::uint32_t v) {
  out.push_back(static_cast<char>(v & 0xFF));
  out.push_back(static_cast<char>((v >> 8) & 0xFF));
  out.push_back(static_cast<char>((v >> 16) & 0xFF));
  out.push_back(static_cast<char>((v >> 24) & 0xFF));
}

void WriteU64(std::string& out, std::uint64_t v) {
  for (int i = 0; i < 8; ++i) {
    out.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
  }
}

std::uint32_t ReadU32(const std::string& bytes, std::size_t offset) {
  return static_cast<std::uint32_t>(static_cast<unsigned char>(bytes[offset])) |
         (static_cast<std::uint32_t>(static_cast<unsigned char>(bytes[offset + 1])) << 8) |
         (static_cast<std::uint32_t>(static_cast<unsigned char>(bytes[offset + 2])) << 16) |
         (static_cast<std::uint32_t>(static_cast<unsigned char>(bytes[offset + 3])) << 24);
}

std::uint64_t ReadU64(const std::string& bytes, std::size_t offset) {
  std::uint64_t v = 0;
  for (int i = 0; i < 8; ++i) {
    v |= static_cast<std::uint64_t>(static_cast<unsigned char>(bytes[offset + i]))
         << (8 * i);
  }
  return v;
}

}  // namespace

std::uint32_t crc32(const std::uint8_t* data, std::size_t length) {
  std::uint32_t crc = 0xFFFFFFFFu;
  for (std::size_t i = 0; i < length; ++i) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xEDB88320u & (~(crc & 1u) + 1u));
    }
  }
  return ~crc;
}

std::string encodeBinary(const std::string& jsonPayload) {
  const auto parsed = nlohmann::json::parse(jsonPayload, nullptr, false);
  if (parsed.is_discarded()) {
    return std::string();
  }
  std::string out;
  out.reserve(kBinaryHeaderSize + jsonPayload.size() + kBinaryCrcSize);
  out.append("WBB1", 4);
  WriteU32(out, kBinaryFormatVersion);
  WriteU64(out, static_cast<std::uint64_t>(jsonPayload.size()));
  out.append(jsonPayload);
  WriteU32(out, crc32(reinterpret_cast<const std::uint8_t*>(out.data()), out.size()));
  return out;
}

Result<std::string> decodeBinary(const std::string& bytes) {
  if (bytes.size() < kBinaryHeaderSize + kBinaryCrcSize) {
    return Result<std::string>::failure(ErrorCode::InvalidArgument,
                                        "binary container is truncated");
  }
  if (std::memcmp(bytes.data(), "WBB1", 4) != 0) {
    return Result<std::string>::failure(ErrorCode::InvalidArgument,
                                        "bad binary magic (expected WBB1)");
  }
  const std::uint32_t version = ReadU32(bytes, 4);
  if (version != kBinaryFormatVersion) {
    return Result<std::string>::failure(ErrorCode::NotSupported,
                                        "unsupported binary format version");
  }
  const std::uint64_t payloadSize = ReadU64(bytes, 8);
  if (payloadSize != bytes.size() - kBinaryHeaderSize - kBinaryCrcSize) {
    return Result<std::string>::failure(ErrorCode::InvalidArgument,
                                        "payload size mismatch");
  }
  const std::uint32_t expectedCrc =
      ReadU32(bytes, kBinaryHeaderSize + static_cast<std::size_t>(payloadSize));
  const std::uint32_t actualCrc = crc32(
      reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size() - kBinaryCrcSize);
  if (expectedCrc != actualCrc) {
    return Result<std::string>::failure(ErrorCode::InvalidArgument, "CRC mismatch");
  }
  std::string payload = bytes.substr(kBinaryHeaderSize, static_cast<std::size_t>(payloadSize));
  const auto parsed = nlohmann::json::parse(payload, nullptr, false);
  if (parsed.is_discarded()) {
    return Result<std::string>::failure(ErrorCode::InvalidArgument,
                                        "payload is not valid JSON");
  }
  return Result<std::string>::success(std::move(payload));
}

}  // namespace wb
