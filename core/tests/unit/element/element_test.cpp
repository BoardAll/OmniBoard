// tests/unit/element/element_test.cpp — domain "element" (task package 1.3).

#include <catch2/catch_test_macros.hpp>

#include <cstddef>
#include <string>

#include "wb/ffi/domain.h"

#include "../support/scene_probe.h"

namespace {

std::string ElementOp(const std::string& op, const std::string& args) {
  return wb::invokeDomain("element", op, args);
}

std::string ListOp(const std::string& pageId) {
  return ElementOp("list", "{\"pageId\":\"" + pageId + "\"}");
}

}  // namespace

TEST_CASE("element.create assigns zIndex and list returns z-order",
          "[element]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);

  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":200,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!b.empty());
  REQUIRE(a != b);

  const std::string list = ListOp(pageId);
  REQUIRE(JsonBool(list, "ok", true));
  REQUIRE(JsonContains(list, "\"count\":2"));
  REQUIRE(list.find("\"" + a + "\"") < list.find("\"" + b + "\""));
  REQUIRE(JsonContains(list, "\"zIndex\":0"));
  REQUIRE(JsonContains(list, "\"zIndex\":1"));
}

TEST_CASE("element.update merges, reports previous and reorders", "[element]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);

  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":200,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string c = SceneCreateElement(
      pageId,
      "{\"type\":\"shape\",\"position\":{\"x\":400,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());
  REQUIRE(!b.empty());
  REQUIRE(!c.empty());

  // Patch merge: position replaced, opacity added, id protected.
  std::string response = ElementOp(
      "update",
      "{\"elementId\":\"" + a +
          "\",\"patch\":{\"position\":{\"x\":100,\"y\":10},\"opacity\":0.5,"
          "\"id\":\"hacked\"}}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "x") == 100.0);
  REQUIRE(JsonNumber(response, "opacity") == 0.5);
  REQUIRE(JsonString(response, "id") == a);
  // `previous` keeps the pre-update geometry.
  const std::size_t previous = response.find("\"previous\"");
  REQUIRE(previous != std::string::npos);
  REQUIRE(JsonNumberAt(response, "x", previous) == 0.0);
  REQUIRE(JsonNumberAt(response, "y", previous) == 0.0);

  // zIndex reorder: bring c (top) to the bottom.
  response = ElementOp("update",
                       "{\"elementId\":\"" + c + "\",\"patch\":{\"zIndex\":0}}");
  REQUIRE(JsonBool(response, "ok", true));
  const std::string list = ListOp(pageId);
  REQUIRE(list.find("\"" + c + "\"") < list.find("\"" + a + "\""));
  REQUIRE(JsonContains(list, "\"zIndex\":0"));
}

TEST_CASE("element.delete cascades attached connectors", "[element]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);

  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":300,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string connector = SceneCreateElement(
      pageId, "{\"type\":\"connector\",\"data\":{\"fromElementId\":\"" + a +
                  "\",\"toElementId\":\"" + b + "\",\"style\":\"straight\"}}");
  REQUIRE(!connector.empty());

  const std::string response =
      ElementOp("delete", "{\"elementId\":\"" + a + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "\"elementId\":\"" + a + "\""));
  REQUIRE(JsonContains(response, "\"deletedConnectorIds\":[\"" + connector +
                                    "\"]"));

  const std::string list = ListOp(pageId);
  REQUIRE(JsonContains(list, "\"count\":1"));
  REQUIRE(!JsonContains(list, "\"" + connector + "\""));
  REQUIRE(JsonContains(list, "\"" + b + "\""));
}

TEST_CASE("element.batch is atomic: failure rolls the page back",
          "[element]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);

  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());

  // Second op references a missing element -> whole batch rolled back.
  std::string response = ElementOp(
      "batch",
      "{\"pageId\":\"" + pageId +
          "\",\"ops\":["
          "{\"op\":\"create\",\"element\":{\"type\":\"text\",\"position\":"
          "{\"x\":10,\"y\":10},\"size\":{\"width\":10,\"height\":10}}},"
          "{\"op\":\"update\",\"elementId\":\"element-nope\",\"patch\":{}}"
          "]}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"Conflict\""));
  REQUIRE(JsonNumber(response, "failedIndex") == 1.0);
  REQUIRE(JsonContains(response, "\"failedOp\":\"update\""));

  std::string list = ListOp(pageId);
  REQUIRE(JsonContains(list, "\"count\":1"));

  // Happy path applies every op.
  response = ElementOp(
      "batch",
      "{\"pageId\":\"" + pageId +
          "\",\"ops\":["
          "{\"op\":\"create\",\"element\":{\"type\":\"text\",\"position\":"
          "{\"x\":10,\"y\":10},\"size\":{\"width\":10,\"height\":10}}},"
          "{\"op\":\"create\",\"element\":{\"type\":\"shape\",\"position\":"
          "{\"x\":20,\"y\":20},\"size\":{\"width\":10,\"height\":10}}}"
          "]}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "executed") == 2.0);
  list = ListOp(pageId);
  REQUIRE(JsonContains(list, "\"count\":3"));
}

TEST_CASE("locked pages reject element mutations", "[element]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());

  std::string response = wb::invokeDomain(
      "page", "lock", "{\"pageId\":\"" + pageId + "\",\"locked\":true}");
  REQUIRE(JsonBool(response, "ok", true));

  response = ElementOp(
      "create",
      "{\"pageId\":\"" + pageId +
          "\",\"element\":{\"type\":\"text\",\"position\":{\"x\":0,\"y\":0}"
          ",\"size\":{\"width\":10,\"height\":10}}}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"Conflict\""));

  response = ElementOp(
      "update",
      "{\"elementId\":\"" + a + "\",\"patch\":{\"opacity\":0.1}}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"Conflict\""));

  response = ElementOp("delete", "{\"elementId\":\"" + a + "\"}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"Conflict\""));

  // Unlock restores mutations.
  response = wb::invokeDomain(
      "page", "lock", "{\"pageId\":\"" + pageId + "\",\"locked\":false}");
  REQUIRE(JsonBool(response, "ok", true));
  response = ElementOp(
      "update",
      "{\"elementId\":\"" + a + "\",\"patch\":{\"opacity\":0.1}}");
  REQUIRE(JsonBool(response, "ok", true));
}

TEST_CASE("element ops fail with NotFound on unknown ids", "[element]") {
  std::string response =
      ElementOp("list", "{\"pageId\":\"page-nope\"}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"NotFound\""));

  response = ElementOp("create",
                       "{\"pageId\":\"page-nope\",\"element\":{\"type\":\"x\"}}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"NotFound\""));

  response =
      ElementOp("update", "{\"elementId\":\"element-nope\",\"patch\":{}}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"NotFound\""));
}
