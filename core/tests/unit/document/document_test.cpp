// tests/unit/document/document_test.cpp — domain "document" (1.6).

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

struct Scene {
  std::string board;
  std::string pageId;
};

Scene NewScene() {
  Scene scene;
  SceneNewBoard(&scene.board);
  scene.pageId = SceneFirstPageId(scene.board);
  return scene;
}

std::string Import(const Scene& scene, const std::string& body) {
  return wb::invokeDomain("document", "import",
                          "{\"pageId\":\"" + scene.pageId + "\"," + body + "}");
}

std::string Info(const std::string& id) {
  return wb::invokeDomain("document", "info", "{\"elementId\":\"" + id + "\"}");
}

}  // namespace

TEST_CASE("document import registers pages and info reads them", "[document]") {
  const Scene scene = NewScene();
  const std::string imported =
      Import(scene, "\"source\":\"docs/手册.pdf\",\"title\":\"手册\","
                    "\"pageCount\":5");
  REQUIRE(JsonBool(imported, "ok", true));
  const std::string doc = JsonString(imported, "elementId");
  REQUIRE(!doc.empty());
  REQUIRE(JsonString(imported, "title") == "手册");
  REQUIRE(JsonNumber(imported, "pageCount") == 5.0);
  REQUIRE(JsonNumber(imported, "currentPage") == 1.0);
  REQUIRE(JsonString(imported, "backend") == "stub");

  const std::string info = Info(doc);
  REQUIRE(JsonBool(info, "ok", true));
  REQUIRE(JsonNumber(info, "pageCount") == 5.0);
  REQUIRE(JsonNumber(info, "currentPage") == 1.0);
  REQUIRE(JsonContains(info, "\"index\":5"));
  REQUIRE(JsonContains(info, "\"width\":595"));
  REQUIRE(JsonContains(info, "\"height\":842"));

  const std::string jumped = wb::invokeDomain(
      "document", "setPage", "{\"elementId\":\"" + doc + "\",\"page\":3}");
  REQUIRE(JsonBool(jumped, "ok", true));
  REQUIRE(JsonNumber(jumped, "currentPage") == 3.0);

  for (const char* page : {"0", "9"}) {
    const std::string bad = wb::invokeDomain(
        "document", "setPage",
        "{\"elementId\":\"" + doc + "\",\"page\":" + page + "}");
    REQUIRE(JsonBool(bad, "ok", false));
    REQUIRE(JsonString(bad, "code") == "InvalidArgument");
  }

  const std::string noArg = wb::invokeDomain(
      "document", "setPage", "{\"elementId\":\"" + doc + "\"}");
  REQUIRE(JsonBool(noArg, "ok", false));
  REQUIRE(JsonString(noArg, "code") == "InvalidArgument");

  // Defaults: title from the file name, pageCount 1.
  const std::string defaulted =
      Import(scene, "\"source\":\"x/y/report.pdf\"");
  REQUIRE(JsonBool(defaulted, "ok", true));
  REQUIRE(JsonString(defaulted, "title") == "report");
  REQUIRE(JsonNumber(defaulted, "pageCount") == 1.0);
}

TEST_CASE("document guards type, lock, missing pages and list", "[document]") {
  const Scene scene = NewScene();
  const std::string imported =
      Import(scene, "\"source\":\"a.pdf\",\"pageCount\":2");
  REQUIRE(JsonBool(imported, "ok", true));
  const std::string doc = JsonString(imported, "elementId");

  const std::string sticky = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}");

  const std::string wrong = Info(sticky);
  REQUIRE(JsonBool(wrong, "ok", false));
  REQUIRE(JsonString(wrong, "code") == "InvalidArgument");

  const std::string missing = Info("element-nope");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonString(missing, "code") == "NotFound");

  const std::string list = wb::invokeDomain(
      "document", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonNumber(list, "count") == 1.0);
  REQUIRE(JsonContains(list, "\"pageCount\":2"));
  REQUIRE(JsonContains(list, "\"title\":\"a\""));

  wb::invokeDomain("page", "lock",
                   "{\"pageId\":\"" + scene.pageId + "\",\"locked\":true}");
  const std::string lockedPage = wb::invokeDomain(
      "document", "setPage", "{\"elementId\":\"" + doc + "\",\"page\":2}");
  REQUIRE(JsonBool(lockedPage, "ok", false));
  REQUIRE(JsonString(lockedPage, "code") == "Conflict");

  const std::string lockedImport = Import(scene, "\"source\":\"b.pdf\"");
  REQUIRE(JsonBool(lockedImport, "ok", false));
  REQUIRE(JsonString(lockedImport, "code") == "Conflict");

  const std::string missingPage = wb::invokeDomain(
      "document", "import", "{\"pageId\":\"page-nope\",\"source\":\"c.pdf\"}");
  REQUIRE(JsonBool(missingPage, "ok", false));
  REQUIRE(JsonString(missingPage, "code") == "NotFound");
}
