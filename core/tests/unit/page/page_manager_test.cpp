// tests/unit/page/page_manager_test.cpp — domain "page" (task package 1.3).

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "wb/ffi/domain.h"

#include "../support/scene_probe.h"

namespace {

/// Creates a board and returns its board id; the default page is page 1.
std::string MakeBoard() {
  std::string response;
  const unsigned long long handle = SceneNewBoard(&response);
  (void)handle;
  return SceneBoardId(response);
}

std::string PageOp(const std::string& op, const std::string& args) {
  return wb::invokeDomain("page", op, args);
}

}  // namespace

TEST_CASE("page.list returns the default page", "[page]") {
  const std::string boardId = MakeBoard();
  const std::string response =
      PageOp("list", "{\"boardId\":\"" + boardId + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "\"count\":1"));
  REQUIRE(JsonContains(response, "页面 1"));
  REQUIRE(JsonBool(response, "locked", false));
  REQUIRE(JsonBool(response, "hidden", false));
}

TEST_CASE("page.create appends and page.rename keeps an inverse", "[page]") {
  const std::string boardId = MakeBoard();
  std::string response = PageOp("create", "{\"boardId\":\"" + boardId + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "\"name\":\"页面 2\""));
  const std::string pageId = JsonString(response, "pageId");
  REQUIRE(!pageId.empty());

  response = PageOp("rename", "{\"pageId\":\"" + pageId +
                                 "\",\"name\":\"流程设计\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "\"name\":\"流程设计\""));
  // Explicit inverse carries the previous name.
  const std::size_t inverse = response.find("\"inverse\"");
  REQUIRE(inverse != std::string::npos);
  REQUIRE(JsonStringAt(response, "name", inverse) == "页面 2");
}

TEST_CASE("page.duplicate deep-copies with fresh ids", "[page]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string boardId = SceneBoardId(board);
  const std::string firstPage = SceneFirstPageId(board);
  const std::string elementId = SceneCreateElement(
      firstPage,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!elementId.empty());

  const std::string response =
      PageOp("duplicate", "{\"pageId\":\"" + firstPage + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  const std::string newPageId = JsonString(response, "pageId");
  REQUIRE(!newPageId.empty());
  REQUIRE(newPageId != firstPage);
  REQUIRE(JsonContains(response, "\"elementCount\":1"));

  // The copy owns independent elements with new ids.
  const std::string list =
      wb::invokeDomain("element", "list", "{\"pageId\":\"" + newPageId + "\"}");
  REQUIRE(JsonBool(list, "ok", true));
  REQUIRE(JsonContains(list, "\"count\":1"));
  REQUIRE(!JsonContains(list, "\"" + elementId + "\""));
  REQUIRE(JsonContains(list, "\"id\":\"element-"));

  // The source keeps its element.
  const std::string sourceList = wb::invokeDomain(
      "element", "list", "{\"pageId\":\"" + firstPage + "\"}");
  REQUIRE(JsonContains(sourceList, "\"" + elementId + "\""));
}

TEST_CASE("page.move reorders inside the board", "[page]") {
  const std::string boardId = MakeBoard();
  std::string response = PageOp("create", "{\"boardId\":\"" + boardId + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  const std::string page2 = JsonString(response, "pageId");
  response = PageOp("create", "{\"boardId\":\"" + boardId + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  const std::string page3 = JsonString(response, "pageId");

  const std::string firstPage = SceneFirstPageId(
      PageOp("list", "{\"boardId\":\"" + boardId + "\"}"));
  REQUIRE(!firstPage.empty());

  // Move page 1 (index 0) to the end: order becomes 页面 2, 页面 3, 页面 1.
  response =
      PageOp("move", "{\"pageId\":\"" + firstPage + "\",\"newIndex\":2}");
  REQUIRE(JsonBool(response, "ok", true));
  bool ok = false;
  REQUIRE(JsonNumber(response, "previousIndex", &ok) == 0.0);
  REQUIRE(ok);

  const std::string list =
      PageOp("list", "{\"boardId\":\"" + boardId + "\"}");
  REQUIRE(JsonContains(list, "\"count\":3"));
  REQUIRE(list.find(page2) < list.find(page3));
  REQUIRE(list.find(page3) < list.find(firstPage));
}

TEST_CASE("page.delete removes a page and boards keep the last one",
          "[page]") {
  const std::string boardId = MakeBoard();
  const std::string response =
      PageOp("create", "{\"boardId\":\"" + boardId + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  const std::string page2 = JsonString(response, "pageId");

  const std::string deleted =
      PageOp("delete", "{\"pageId\":\"" + page2 + "\"}");
  REQUIRE(JsonBool(deleted, "ok", true));
  REQUIRE(JsonContains(deleted, "\"boardId\":\"" + boardId + "\""));
  REQUIRE(JsonContains(deleted, "\"deleted\":"));

  // Now exactly one page remains; deleting it is a conflict.
  const std::string remaining =
      PageOp("list", "{\"boardId\":\"" + boardId + "\"}");
  const std::string firstPage =
      JsonStringAt(remaining, "id", remaining.find("\"pages\""));
  REQUIRE(!firstPage.empty());
  const std::string conflict =
      PageOp("delete", "{\"pageId\":\"" + firstPage + "\"}");
  REQUIRE(JsonBool(conflict, "ok", false));
  REQUIRE(JsonContains(conflict, "\"code\":\"Conflict\""));
}

TEST_CASE("page.setBackground / lock / hide keep inverses", "[page]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);

  std::string response = PageOp(
      "setBackground",
      "{\"pageId\":\"" + pageId + "\",\"background\":{\"type\":\"dot\"}}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "\"type\":\"dot\""));
  std::size_t inverse = response.find("\"inverse\"");
  REQUIRE(inverse != std::string::npos);
  REQUIRE(JsonContains(response.substr(inverse), "\"background\":{}"));

  response = PageOp("lock", "{\"pageId\":\"" + pageId + "\",\"locked\":true}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonBool(response, "locked", true));
  inverse = response.find("\"inverse\"");
  REQUIRE(inverse != std::string::npos);
  REQUIRE(JsonBool(response.substr(inverse), "locked", false));

  response = PageOp("hide", "{\"pageId\":\"" + pageId + "\",\"hidden\":true}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonBool(response, "hidden", true));
}

TEST_CASE("page ops on unknown ids fail with NotFound", "[page]") {
  const std::string response =
      PageOp("list", "{\"boardId\":\"board-does-not-exist\"}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"NotFound\""));

  const std::string rename = PageOp(
      "rename", "{\"pageId\":\"page-does-not-exist\",\"name\":\"x\"}");
  REQUIRE(JsonBool(rename, "ok", false));
  REQUIRE(JsonContains(rename, "\"code\":\"NotFound\""));
}
