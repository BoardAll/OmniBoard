// tests/unit/background/background_test.cpp — domain "background" (1.4).

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

TEST_CASE("background list enumerates eleven presets", "[background]") {
  const std::string response = wb::invokeDomain("background", "list", "{}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "count") == 11.0);
  REQUIRE(JsonContains(response, "\"id\":\"whiteboard\""));
  REQUIRE(JsonContains(response, "\"id\":\"dot\""));
  REQUIRE(JsonContains(response, "\"id\":\"grid\""));
  REQUIRE(JsonContains(response, "\"id\":\"blackboard\""));
  REQUIRE(JsonContains(response, "\"id\":\"greenboard\""));
  REQUIRE(JsonContains(response, "\"id\":\"dark-dot\""));
  REQUIRE(JsonContains(response, "\"id\":\"dark-grid\""));
  REQUIRE(JsonContains(response, "点阵白板"));
  REQUIRE(JsonContains(response, "横线纸"));
  REQUIRE(JsonContains(response, "方格纸"));
}

TEST_CASE("background set applies a preset to a page", "[background]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  REQUIRE(!pageId.empty());

  const std::string response = wb::invokeDomain(
      "background", "set", "{\"pageId\":\"" + pageId + "\",\"preset\":\"grid\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "preset") == "grid");
  REQUIRE(JsonString(response, "pattern") == "grid");
  REQUIRE(JsonContains(response, "\"baseColor\":\"#FFFFFF\""));

  const std::string fetched =
      wb::invokeDomain("background", "get", "{\"pageId\":\"" + pageId + "\"}");
  REQUIRE(JsonString(fetched, "preset") == "grid");

  // The page domain reads the same slot.
  const std::string listed = wb::invokeDomain(
      "page", "list", "{\"boardId\":\"" + SceneBoardId(board) + "\"}");
  REQUIRE(JsonContains(listed, "\"pattern\":\"grid\""));
}

TEST_CASE("background set stores a raw background object verbatim",
          "[background]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);

  const std::string response = wb::invokeDomain(
      "background", "set",
      "{\"pageId\":\"" + pageId +
          "\",\"background\":{\"type\":\"solid\",\"color\":\"#123456\"}}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "\"color\":\"#123456\""));
  REQUIRE(JsonContains(response, "\"type\":\"solid\""));
}

TEST_CASE("background set rejects unknown preset or page", "[background]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);

  const std::string badPreset = wb::invokeDomain(
      "background", "set",
      "{\"pageId\":\"" + pageId + "\",\"preset\":\"nope\"}");
  REQUIRE(JsonBool(badPreset, "ok", false));
  REQUIRE(JsonString(badPreset, "code") == "NotFound");

  const std::string badPage = wb::invokeDomain(
      "background", "set", "{\"pageId\":\"page-nope\",\"preset\":\"grid\"}");
  REQUIRE(JsonBool(badPage, "ok", false));
  REQUIRE(JsonString(badPage, "code") == "NotFound");

  const std::string missing = wb::invokeDomain(
      "background", "set", "{\"pageId\":\"" + pageId + "\"}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonString(missing, "code") == "InvalidArgument");
}

TEST_CASE("background set refuses locked pages", "[background]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  wb::invokeDomain("page", "lock",
                   "{\"pageId\":\"" + pageId + "\",\"locked\":true}");

  const std::string response = wb::invokeDomain(
      "background", "set", "{\"pageId\":\"" + pageId + "\",\"preset\":\"dot\"}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonString(response, "code") == "Conflict");
}
