// tests/unit/model/board_test.cpp — domain "board" + FFI board lifecycle
// (task package 1.3).

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "wb/ffi/domain.h"
#include "wb/wb.h"

#include "../support/scene_probe.h"

TEST_CASE("board.create returns a handle, default page and summary", "[model]") {
  const std::string response = wb::invokeDomain("board", "create", "{}");
  REQUIRE(JsonBool(response, "ok", true));
  bool hasHandle = false;
  const double handle = JsonNumber(response, "handle", &hasHandle);
  REQUIRE(hasHandle);
  REQUIRE(handle > 0.0);
  REQUIRE(JsonContains(response, "\"pageCount\":1"));
  REQUIRE(JsonContains(response, "\"name\":\"未命名白板\""));
  REQUIRE(JsonContains(response, "\"name\":\"页面 1\""));
  REQUIRE(JsonContains(response, "\"elementCount\":0"));
  const std::string boardId = SceneBoardId(response);
  REQUIRE(JsonContains(boardId, "board-"));

  // Cleanup through the FFI destroy path.
  wb_destroy_board(static_cast<uint64_t>(handle));
}

TEST_CASE("board.create honours the name option", "[model]") {
  const std::string response =
      wb::invokeDomain("board", "create", "{\"name\":\"需求梳理\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "\"name\":\"需求梳理\""));
  bool ok = false;
  wb_destroy_board(static_cast<uint64_t>(JsonNumber(response, "handle", &ok)));
}

TEST_CASE("FFI board lifecycle: create, get, destroy", "[model]") {
  const uint64_t handle = wb_create_board("{\"name\":\"测试板\"}");
  REQUIRE(handle != 0);

  const char* got = wb_board_get(handle);
  REQUIRE(got != nullptr);
  const std::string gotJson(got);
  wb_free(got);
  REQUIRE(JsonBool(gotJson, "ok", true));
  REQUIRE(JsonContains(gotJson, "测试板"));
  bool hasHandle = false;
  REQUIRE(JsonNumber(gotJson, "handle", &hasHandle) ==
          static_cast<double>(handle));
  REQUIRE(hasHandle);

  wb_destroy_board(handle);
  const char* gone = wb_board_get(handle);
  REQUIRE(gone != nullptr);
  const std::string goneJson(gone);
  wb_free(gone);
  REQUIRE(JsonBool(goneJson, "ok", false));
  REQUIRE(JsonContains(goneJson, "\"code\":\"NotFound\""));
}

TEST_CASE("board.get rejects unknown handles", "[model]") {
  const std::string response =
      wb::invokeDomain("board", "get", "{\"handle\":999999}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"NotFound\""));
}
