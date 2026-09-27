// tests/unit/mindmap/mindmap_test.cpp — domain "mindmap" (1.5).

#include <cmath>
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

std::string CreateMindmap(const Scene& scene) {
  const std::string response = wb::invokeDomain(
      "mindmap", "create",
      "{\"pageId\":\"" + scene.pageId +
          "\",\"element\":{\"position\":{\"x\":0,\"y\":0},"
          "\"size\":{\"width\":500,\"height\":400}}}");
  return JsonBool(response, "ok", true) ? JsonString(response, "elementId")
                                        : std::string();
}

std::string AddNode(const std::string& mindmapId, const std::string& body) {
  const std::string response = wb::invokeDomain(
      "mindmap", "addNode",
      "{\"mindmapId\":\"" + mindmapId + "\",\"node\":" + body + "}");
  return JsonBool(response, "ok", true) ? JsonString(response, "id")
                                        : std::string();
}

/// Position value of node `id` inside a layout response.
double NodeNumber(const std::string& response, const std::string& id,
                  const std::string& key) {
  const std::size_t pos = response.find("\"" + id + "\"");
  REQUIRE(pos != std::string::npos);
  return JsonNumberAt(response, key, pos);
}

}  // namespace

TEST_CASE("mindmap addNode builds the tree under the requested parent",
          "[mindmap]") {
  const Scene scene = NewScene();
  const std::string map = CreateMindmap(scene);
  REQUIRE(!map.empty());

  const std::string branch = AddNode(map, "{\"text\":\"分支A\"}");
  REQUIRE(branch == "mm-2");
  const std::string leaf =
      AddNode(map, "{\"parentId\":\"mm-2\",\"text\":\"叶子\"}");
  REQUIRE(leaf == "mm-3");

  const std::string again = wb::invokeDomain(
      "mindmap", "addNode",
      "{\"mindmapId\":\"" + map + "\",\"parentId\":\"mm-2\",\"text\":\"叶子2\"}");
  REQUIRE(JsonNumber(again, "nodeCount") == 4.0);

  const std::string missingParent = wb::invokeDomain(
      "mindmap", "addNode",
      "{\"mindmapId\":\"" + map + "\",\"parentId\":\"mm-404\",\"text\":\"x\"}");
  REQUIRE(JsonBool(missingParent, "ok", false));
  REQUIRE(JsonString(missingParent, "code") == "NotFound");

  const std::string noText = wb::invokeDomain(
      "mindmap", "addNode", "{\"mindmapId\":\"" + map + "\"}");
  REQUIRE(JsonBool(noText, "ok", false));
  REQUIRE(JsonString(noText, "code") == "InvalidArgument");
}

TEST_CASE("mindmap tree layout grows right and stacks leaves", "[mindmap]") {
  const Scene scene = NewScene();
  const std::string map = CreateMindmap(scene);
  const std::string branch = AddNode(map, "{\"text\":\"分支A\"}");
  const std::string leaf = AddNode(
      map, "{\"parentId\":\"mm-2\",\"text\":\"叶子\"}");  // depth 2
  const std::string sibling = AddNode(map, "{\"text\":\"分支B\"}");  // depth 1
  REQUIRE(branch == "mm-2");
  REQUIRE(leaf == "mm-3");
  REQUIRE(sibling == "mm-4");

  const std::string layout = wb::invokeDomain(
      "mindmap", "layout", "{\"mindmapId\":\"" + map + "\"}");
  REQUIRE(JsonBool(layout, "ok", true));
  REQUIRE(JsonNumber(layout, "nodeCount") == 4.0);
  REQUIRE(JsonString(layout, "layout") == "tree");

  // Depth grows to the right; same-depth nodes share the column.
  const double xRoot = NodeNumber(layout, "mm-1", "x");
  const double xBranch = NodeNumber(layout, "mm-2", "x");
  const double xLeaf = NodeNumber(layout, "mm-3", "x");
  const double xSibling = NodeNumber(layout, "mm-4", "x");
  REQUIRE(xRoot < xBranch);
  REQUIRE(xBranch < xLeaf);
  REQUIRE(std::fabs(xBranch - xSibling) < 1e-6);

  // Root centre sits at the origin: y = -height/2.
  REQUIRE(std::fabs(NodeNumber(layout, "mm-1", "y") + 16.0) < 1e-6);
  // The second leaf row is below the first.
  REQUIRE(NodeNumber(layout, "mm-4", "y") > NodeNumber(layout, "mm-3", "y"));
}

TEST_CASE("mindmap radial layout places depth on rings", "[mindmap]") {
  const Scene scene = NewScene();
  const std::string map = CreateMindmap(scene);
  const std::string branch = AddNode(map, "{\"text\":\"分支A\"}");
  REQUIRE(!branch.empty());

  const std::string set = wb::invokeDomain(
      "mindmap", "setLayout",
      "{\"mindmapId\":\"" + map + "\",\"layout\":\"radial\"}");
  REQUIRE(JsonBool(set, "ok", true));
  REQUIRE(JsonString(set, "layout") == "radial");

  const std::string layout = wb::invokeDomain(
      "mindmap", "layout", "{\"mindmapId\":\"" + map + "\"}");
  REQUIRE(JsonNumber(layout, "nodeCount") == 2.0);
  REQUIRE(JsonString(layout, "layout") == "radial");
  // Ring 1 radius 160; a single child lands at the bottom of the sweep.
  REQUIRE(std::fabs(NodeNumber(layout, "mm-2", "y") - 144.0) < 1e-6);

  const std::string bad = wb::invokeDomain(
      "mindmap", "setLayout",
      "{\"mindmapId\":\"" + map + "\",\"layout\":\"star\"}");
  REQUIRE(JsonBool(bad, "ok", false));
  REQUIRE(JsonString(bad, "code") == "InvalidArgument");
}

TEST_CASE("mindmap setStyle, removeNode and export", "[mindmap]") {
  const Scene scene = NewScene();
  const std::string map = CreateMindmap(scene);
  AddNode(map, "{\"text\":\"分支A\"}");
  AddNode(map, "{\"parentId\":\"mm-2\",\"text\":\"叶子\"}");
  AddNode(map, "{\"text\":\"分支B\"}");

  const std::string styled = wb::invokeDomain(
      "mindmap", "setStyle",
      "{\"mindmapId\":\"" + map +
          "\",\"nodeId\":\"mm-2\",\"style\":{\"color\":\"#FF0000\"}}");
  REQUIRE(JsonBool(styled, "ok", true));
  REQUIRE(JsonContains(styled, "\"color\":\"#FF0000\""));

  // Removing mm-2 drops its subtree (mm-3) as well.
  const std::string removed = wb::invokeDomain(
      "mindmap", "removeNode",
      "{\"mindmapId\":\"" + map + "\",\"nodeId\":\"mm-2\"}");
  REQUIRE(JsonBool(removed, "ok", true));
  REQUIRE(JsonNumber(removed, "nodeCount") == 2.0);

  const std::string root = wb::invokeDomain(
      "mindmap", "removeNode",
      "{\"mindmapId\":\"" + map + "\",\"nodeId\":\"mm-1\"}");
  REQUIRE(JsonBool(root, "ok", false));
  REQUIRE(JsonString(root, "code") == "InvalidArgument");

  const std::string markdown = wb::invokeDomain(
      "mindmap", "export",
      "{\"mindmapId\":\"" + map + "\",\"format\":\"markdown\"}");
  REQUIRE(JsonBool(markdown, "ok", true));
  REQUIRE(JsonString(markdown, "format") == "markdown");
  REQUIRE(JsonContains(markdown, "# "));
  REQUIRE(JsonContains(markdown, "分支B"));

  const std::string badFormat = wb::invokeDomain(
      "mindmap", "export",
      "{\"mindmapId\":\"" + map + "\",\"format\":\"pdf\"}");
  REQUIRE(JsonBool(badFormat, "ok", false));
  REQUIRE(JsonString(badFormat, "code") == "InvalidArgument");
}

TEST_CASE("mindmap guards type, lock and list", "[mindmap]") {
  const Scene scene = NewScene();
  const std::string map = CreateMindmap(scene);
  const std::string sticky = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}");

  const std::string wrong = wb::invokeDomain(
      "mindmap", "layout", "{\"mindmapId\":\"" + sticky + "\"}");
  REQUIRE(JsonBool(wrong, "ok", false));
  REQUIRE(JsonString(wrong, "code") == "InvalidArgument");

  const std::string list = wb::invokeDomain(
      "mindmap", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonNumber(list, "count") == 1.0);
  REQUIRE(JsonContains(list, "\"nodeCount\":1"));

  wb::invokeDomain("page", "lock",
                   "{\"pageId\":\"" + scene.pageId + "\",\"locked\":true}");
  const std::string locked = wb::invokeDomain(
      "mindmap", "addNode",
      "{\"mindmapId\":\"" + map + "\",\"text\":\"x\"}");
  REQUIRE(JsonBool(locked, "ok", false));
  REQUIRE(JsonString(locked, "code") == "Conflict");
}
