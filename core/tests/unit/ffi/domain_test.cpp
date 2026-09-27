// tests/unit/ffi/domain_test.cpp — domain registry contract (task package 1.1).
// Tags: [domain]

#include <catch2/catch_test_macros.hpp>

#include <memory>
#include <stdexcept>
#include <string>

#include "wb/ffi/domain.h"

namespace {

class EchoDomain : public wb::DomainHandler {
 public:
  std::string name() const override { return "test_echo"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    if (op == "echo") {
      return wb::domainOk(argsJson.empty() ? "{}" : argsJson);
    }
    if (op == "boom") {
      throw std::runtime_error("boom!");
    }
    return wb::domainError("NotFound", "unknown op: " + op);
  }
};

bool Contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

}  // namespace

TEST_CASE("registerDomain + invokeDomain round trip", "[domain]") {
  wb::registerDomain(std::make_unique<EchoDomain>());

  const std::string ok = wb::invokeDomain("test_echo", "echo", "{\"a\":1}");
  REQUIRE(Contains(ok, "\"ok\":true"));
  REQUIRE(Contains(ok, "\"a\":1"));

  // Registered name appears in the domain list (sorted).
  const auto domains = wb::listDomains();
  bool found = false;
  for (const auto& d : domains) {
    if (d == "test_echo") {
      found = true;
    }
  }
  REQUIRE(found);
}

TEST_CASE("invokeDomain failure modes never throw", "[domain]") {
  const std::string unknown =
      wb::invokeDomain("no_such_domain_xyz", "anything", "{}");
  REQUIRE(Contains(unknown, "\"ok\":false"));
  REQUIRE(Contains(unknown, "\"code\":\"NotFound\""));

  REQUIRE(Contains(wb::invokeDomain("", "op", "{}"), "\"code\":\"InvalidArgument\""));

  // Handler-level NotFound.
  wb::registerDomain(std::make_unique<EchoDomain>());
  REQUIRE(Contains(wb::invokeDomain("test_echo", "nope", "{}"), "\"code\":\"NotFound\""));

  // Exceptions are converted to InternalError responses.
  const std::string thrown = wb::invokeDomain("test_echo", "boom", "{}");
  REQUIRE(Contains(thrown, "\"ok\":false"));
  REQUIRE(Contains(thrown, "\"code\":\"InternalError\""));
  REQUIRE(Contains(thrown, "boom!"));
}

TEST_CASE("response builders emit the contract shape", "[domain]") {
  REQUIRE(wb::domainError("Conflict", "locked") ==
          "{\"error\":{\"code\":\"Conflict\",\"message\":\"locked\"},\"ok\":false}");
  REQUIRE(wb::domainOk("{}") == "{\"ok\":true,\"result\":{}}");
  REQUIRE(Contains(wb::domainOk("{\"n\":1}"), "\"result\":{\"n\":1}"));
  // Invalid result JSON degrades to an error response, never throws.
  REQUIRE(Contains(wb::domainOk("{not-json"), "\"ok\":false"));
}
