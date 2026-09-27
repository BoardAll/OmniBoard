// tests/unit/serialization/codec_test.cpp — binary scene codec (task package 1.1).
// Tags: [serialization]

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "wb/serialization/codec.h"

TEST_CASE("binary codec round trip", "[serialization]") {
  const std::string payload = "{\"board\":\"b1\",\"pages\":[]}";
  const std::string encoded = wb::encodeBinary(payload);
  REQUIRE_FALSE(encoded.empty());
  REQUIRE(encoded.size() == wb::kBinaryHeaderSize + payload.size() + wb::kBinaryCrcSize);
  REQUIRE(encoded.compare(0, 4, "WBB1") == 0);

  const auto decoded = wb::decodeBinary(encoded);
  REQUIRE(decoded.ok());
  REQUIRE(decoded.value == payload);
}

TEST_CASE("encodeBinary rejects malformed JSON", "[serialization]") {
  REQUIRE(wb::encodeBinary("not-json-at-all").empty());
}

TEST_CASE("decodeBinary detects corruption", "[serialization]") {
  const std::string encoded = wb::encodeBinary("{\"a\":1}");
  REQUIRE_FALSE(encoded.empty());

  // Truncated container.
  const auto truncated = wb::decodeBinary(encoded.substr(0, 10));
  REQUIRE_FALSE(truncated.ok());
  REQUIRE(truncated.error.code == wb::ErrorCode::InvalidArgument);

  // Bad magic.
  std::string badMagic = encoded;
  badMagic[0] = 'X';
  REQUIRE_FALSE(wb::decodeBinary(badMagic).ok());

  // Unsupported version.
  std::string badVersion = encoded;
  badVersion[4] = static_cast<char>(99);
  const auto versionResult = wb::decodeBinary(badVersion);
  REQUIRE_FALSE(versionResult.ok());
  REQUIRE(versionResult.error.code == wb::ErrorCode::NotSupported);

  // Flipped payload byte -> CRC mismatch.
  std::string bitFlip = encoded;
  bitFlip[wb::kBinaryHeaderSize] ^= 0x20;
  const auto crcResult = wb::decodeBinary(bitFlip);
  REQUIRE_FALSE(crcResult.ok());
  REQUIRE(crcResult.error.code == wb::ErrorCode::InvalidArgument);
}

TEST_CASE("crc32 matches known vector", "[serialization]") {
  // CRC32(IEEE) of "123456789" is 0xCBF43926.
  const std::string data = "123456789";
  REQUIRE(wb::crc32(reinterpret_cast<const std::uint8_t*>(data.data()), data.size()) ==
          0xCBF43926u);
}
