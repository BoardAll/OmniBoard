// tests/unit/tool/tool_registry_test.cpp — ToolRegistry (task package 1.2).
// Tags: [tool]

#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cctype>
#include <memory>
#include <string>

#include "wb/ffi/domain.h"

namespace {

bool Contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

int ExtractInt(const std::string& json, const std::string& key) {
  const std::string needle = "\"" + key + "\":";
  const auto pos = json.find(needle);
  if (pos == std::string::npos) return -1;
  const auto begin = pos + needle.size();
  std::size_t end = begin;
  while (end < json.size() && std::isdigit(static_cast<unsigned char>(json[end]))) {
    ++end;
  }
  if (end == begin) return -1;
  return std::stoi(json.substr(begin, end - begin));
}

class PingDomain : public wb::DomainHandler {
 public:
  std::string name() const override { return "tooltest"; }
  std::string handle(const std::string& op, const std::string& /*argsJson*/) override {
    if (op == "ping") {
      return "{\"ok\":true,\"result\":{\"pong\":true}}";
    }
    return "{\"ok\":false,\"error\":{\"code\":\"NotFound\",\"message\":"
           "\"unknown op\"}}";
  }
};

}  // namespace

TEST_CASE("tool list exposes at least 60 catalogued tools", "[tool]") {
  const std::string response = wb::invokeDomain("tool", "list", "{}");
  REQUIRE(Contains(response, "\"ok\":true"));

  const int count = ExtractInt(response, "count");
  REQUIRE(count >= 60);

  // Spot-check well-known ids and required metadata fields.
  REQUIRE(Contains(response, "\"id\":\"element.create\""));
  REQUIRE(Contains(response, "\"id\":\"command.undo\""));
  REQUIRE(Contains(response, "\"id\":\"3d.export\""));
  REQUIRE(Contains(response, "\"category\":\"render3d\""));
  REQUIRE(Contains(response, "\"name\":"));
  REQUIRE(Contains(response, "\"description\":"));
}

TEST_CASE("tool get returns metadata or NotFound", "[tool]") {
  const std::string found = wb::invokeDomain("tool", "get", R"({"toolId":"element.create"})");
  REQUIRE(Contains(found, "\"ok\":true"));
  REQUIRE(Contains(found, "\"id\":\"element.create\""));

  const std::string missing = wb::invokeDomain("tool", "get", R"({"toolId":"nope.never"})");
  REQUIRE(Contains(missing, "\"ok\":false"));
  REQUIRE(Contains(missing, "\"code\":\"NotFound\""));
}

TEST_CASE("tool execute forwards to the target domain", "[tool]") {
  wb::registerDomain(std::make_unique<PingDomain>());

  const std::string ok =
      wb::invokeDomain("tool", "execute", R"({"toolId":"tooltest.ping","args":{}})");
  REQUIRE(Contains(ok, "\"ok\":true"));
  REQUIRE(Contains(ok, "\"pong\":true"));

  // Unknown domain prefix stays an error (3d alias maps to render3d).
  const std::string unknown =
      wb::invokeDomain("tool", "execute", R"({"toolId":"nope.never","args":{}})");
  REQUIRE(Contains(unknown, "\"ok\":false"));
  REQUIRE(Contains(unknown, "\"code\":\"NotFound\""));

  // Malformed id without a dot is rejected.
  const std::string malformed =
      wb::invokeDomain("tool", "execute", R"({"toolId":"nodot","args":{}})");
  REQUIRE(Contains(malformed, "\"code\":\"InvalidArgument\""));

  // Unknown op on the tool domain.
  const std::string badOp = wb::invokeDomain("tool", "explode", "{}");
  REQUIRE(Contains(badOp, "\"code\":\"NotFound\""));
}
