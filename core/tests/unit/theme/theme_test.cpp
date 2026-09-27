// tests/unit/theme/theme_test.cpp — domain "theme" (task package 1.4).
// The current theme is process-wide; tests that load themes reassert the
// built-in default at the end where later assertions depend on it.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

TEST_CASE("theme list enumerates the nine built-ins", "[theme]") {
  const std::string response = wb::invokeDomain("theme", "list", "{}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "count") == 9.0);
  REQUIRE(JsonContains(response, "\"id\":\"clean-professional\""));
  REQUIRE(JsonContains(response, "\"id\":\"dark-night\""));
  REQUIRE(JsonContains(response, "\"id\":\"blackboard\""));
  REQUIRE(JsonContains(response, "\"id\":\"greenboard\""));
  REQUIRE(JsonContains(response, "\"id\":\"minimal\""));
  REQUIRE(JsonContains(response, "\"id\":\"hand-drawn\""));
  REQUIRE(JsonContains(response, "\"id\":\"cyber\""));
  REQUIRE(JsonContains(response, "\"id\":\"kids\""));
  REQUIRE(JsonContains(response, "\"id\":\"enterprise\""));
  REQUIRE(JsonContains(response, "\"primary\":\"#3370FF\""));
  REQUIRE(JsonContains(response, "清爽专业"));
}

TEST_CASE("theme current defaults to clean-professional with full tokens",
          "[theme]") {
  wb::invokeDomain("theme", "load", "{\"theme\":\"clean-professional\"}");
  const std::string response = wb::invokeDomain("theme", "current", "{}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "id") == "clean-professional");
  REQUIRE(JsonContains(response, "\"bg.canvas\":\"#F7F8FA\""));
  REQUIRE(JsonContains(response, "\"bg.elevated\":\"#FFFFFF\""));
  REQUIRE(JsonContains(response, "\"toolbar.active\":\"#3370FF\""));
  REQUIRE(JsonContains(response, "\"radial.highlight\":\"#3370FF\""));
  REQUIRE(JsonContains(response, "\"radial.bg\":\"#FFFFFF\""));
  REQUIRE(JsonContains(response, "\"card.border\":\"#E4E7EC\""));
  REQUIRE(JsonNumber(response, "l") == 12.0);
  REQUIRE(JsonContains(response, "\"opacity\":{\"panel\":1.0"));
}

TEST_CASE("theme load switches built-ins by id string or object", "[theme]") {
  const std::string byString =
      wb::invokeDomain("theme", "load", "{\"theme\":\"dark-night\"}");
  REQUIRE(JsonBool(byString, "ok", true));
  REQUIRE(JsonString(byString, "source") == "builtin");
  REQUIRE(JsonString(byString, "id") == "dark-night");
  REQUIRE(JsonContains(byString, "\"dark\":true"));
  REQUIRE(JsonContains(byString, "\"primary\":\"#4C88FF\""));

  const std::string byObject =
      wb::invokeDomain("theme", "load", "{\"theme\":{\"id\":\"cyber\"}}");
  REQUIRE(JsonBool(byObject, "ok", true));
  REQUIRE(JsonString(byObject, "source") == "builtin");
  REQUIRE(JsonString(byObject, "id") == "cyber");

  const std::string current = wb::invokeDomain("theme", "current", "{}");
  REQUIRE(JsonString(current, "id") == "cyber");

  // Restore the default for any later test that assumes it.
  wb::invokeDomain("theme", "load", "{\"theme\":\"clean-professional\"}");
}

TEST_CASE("theme load accepts a custom theme carrying colors", "[theme]") {
  const std::string response = wb::invokeDomain(
      "theme", "load",
      "{\"theme\":{\"colors\":{\"primary\":\"#FF0000\"},\"id\":\"my-theme\","
      "\"name\":\"我的主题\"}}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "source") == "custom");
  REQUIRE(JsonString(response, "id") == "my-theme");
  REQUIRE(JsonContains(response, "\"primary\":\"#FF0000\""));

  const std::string current = wb::invokeDomain("theme", "current", "{}");
  REQUIRE(JsonString(current, "id") == "my-theme");
  REQUIRE(JsonContains(current, "我的主题"));

  wb::invokeDomain("theme", "load", "{\"theme\":\"clean-professional\"}");
}

TEST_CASE("theme load and get reject unknown ids", "[theme]") {
  const std::string loadUnknown =
      wb::invokeDomain("theme", "load", "{\"theme\":\"nope\"}");
  REQUIRE(JsonBool(loadUnknown, "ok", false));
  REQUIRE(JsonString(loadUnknown, "code") == "NotFound");

  const std::string loadMissing = wb::invokeDomain("theme", "load", "{}");
  REQUIRE(JsonBool(loadMissing, "ok", false));
  REQUIRE(JsonString(loadMissing, "code") == "InvalidArgument");

  const std::string getUnknown =
      wb::invokeDomain("theme", "get", "{\"themeId\":\"nope\"}");
  REQUIRE(JsonBool(getUnknown, "ok", false));
  REQUIRE(JsonString(getUnknown, "code") == "NotFound");
}

TEST_CASE("theme get returns a built-in without switching current", "[theme]") {
  wb::invokeDomain("theme", "load", "{\"theme\":\"clean-professional\"}");
  const std::string response =
      wb::invokeDomain("theme", "get", "{\"themeId\":\"minimal\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "id") == "minimal");
  REQUIRE(JsonContains(response, "\"primary\":\"#000000\""));

  const std::string current = wb::invokeDomain("theme", "current", "{}");
  REQUIRE(JsonString(current, "id") == "clean-professional");
}
