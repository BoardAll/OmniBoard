// tests/unit/layout/layout_test.cpp — domain "layout" (task package 1.3).

#include <catch2/catch_test_macros.hpp>

#include <cstddef>
#include <string>
#include <vector>

#include "wb/ffi/domain.h"

#include "../support/scene_probe.h"

namespace {

std::string AlignOp(const std::string& pageId, const std::vector<std::string>& ids,
                    const std::string& mode) {
  return wb::invokeDomain(
      "layout", "align",
      "{\"pageId\":\"" + pageId + "\",\"elementIds\":" + JsonIdArray(ids) +
          ",\"mode\":\"" + mode + "\"}");
}

std::string DistributeOp(const std::string& pageId,
                         const std::vector<std::string>& ids,
                         const std::string& orientation) {
  return wb::invokeDomain(
      "layout", "distribute",
      "{\"pageId\":\"" + pageId + "\",\"elementIds\":" + JsonIdArray(ids) +
          ",\"orientation\":\"" + orientation + "\"}");
}

/// position.x of the element whose id first occurs at `idPos`.
double ElementX(const std::string& list, const std::string& elementId) {
  const std::size_t pos = list.find("\"" + elementId + "\"");
  return JsonNumberAt(list, "x", pos);
}

double ElementY(const std::string& list, const std::string& elementId) {
  const std::size_t pos = list.find("\"" + elementId + "\"");
  return JsonNumberAt(list, "y", pos);
}

std::string ListOp(const std::string& pageId) {
  return wb::invokeDomain("element", "list", "{\"pageId\":\"" + pageId + "\"}");
}

}  // namespace

TEST_CASE("layout.align left / hcenter / top across a selection", "[layout]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":100,\"y\":100},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string c = SceneCreateElement(
      pageId,
      "{\"type\":\"shape\",\"position\":{\"x\":400,\"y\":300},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());
  REQUIRE(!b.empty());
  REQUIRE(!c.empty());
  const std::vector<std::string> all = {a, b, c};

  std::string response = AlignOp(pageId, all, "left");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "moved") == 3.0);
  REQUIRE(JsonContains(response, "\"mode\":\"left\""));
  std::string list = ListOp(pageId);
  REQUIRE(ElementX(list, a) == 0.0);
  REQUIRE(ElementX(list, b) == 0.0);
  REQUIRE(ElementX(list, c) == 0.0);

  response = AlignOp(pageId, all, "top");
  REQUIRE(JsonBool(response, "ok", true));
  list = ListOp(pageId);
  REQUIRE(ElementY(list, a) == 0.0);
  REQUIRE(ElementY(list, b) == 0.0);
  REQUIRE(ElementY(list, c) == 0.0);
}

TEST_CASE("layout.align hcenter / vcenter use the union centre", "[layout]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":200,\"y\":100},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());
  REQUIRE(!b.empty());

  // Union x [0,300] centre 150: both centres land on 150 -> x=100.
  std::string response = AlignOp(pageId, {a, b}, "hcenter");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "width") == 300.0);
  std::string list = ListOp(pageId);
  REQUIRE(ElementX(list, a) == 100.0);
  REQUIRE(ElementX(list, b) == 100.0);

  // Union y [0,150] centre 75: both centres land on 75 -> y=50.
  response = AlignOp(pageId, {a, b}, "vcenter");
  REQUIRE(JsonBool(response, "ok", true));
  list = ListOp(pageId);
  REQUIRE(ElementY(list, a) == 50.0);
  REQUIRE(ElementY(list, b) == 50.0);
  // X positions from the hcenter step are untouched by vcenter.
  REQUIRE(ElementX(list, a) == 100.0);
}

TEST_CASE("layout.align validates mode and selection size", "[layout]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());

  std::string response = AlignOp(pageId, {a}, "left");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"InvalidArgument\""));

  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":200,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  response = AlignOp(pageId, {a, b}, "diagonal");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"InvalidArgument\""));

  response = AlignOp(pageId, {a, "element-nope"}, "left");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"NotFound\""));
}

TEST_CASE("layout.distribute equalises centre spacing, ends stay put",
          "[layout]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":150,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string c = SceneCreateElement(
      pageId,
      "{\"type\":\"shape\",\"position\":{\"x\":400,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());
  REQUIRE(!b.empty());
  REQUIRE(!c.empty());

  // Centres 50 / 200 / 450 -> equal spacing puts the middle at 250 (x=200).
  const std::string response = DistributeOp(pageId, {a, b, c}, "horizontal");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "moved") == 3.0);
  REQUIRE(JsonContains(response, "\"orientation\":\"horizontal\""));
  const std::string list = ListOp(pageId);
  REQUIRE(ElementX(list, a) == 0.0);
  REQUIRE(ElementX(list, b) == 200.0);
  REQUIRE(ElementX(list, c) == 400.0);

  const std::string tooFew = DistributeOp(pageId, {a, b}, "horizontal");
  REQUIRE(JsonBool(tooFew, "ok", false));
  REQUIRE(JsonContains(tooFew, "\"code\":\"InvalidArgument\""));

  const std::string badAxis = DistributeOp(pageId, {a, b, c}, "diagonal");
  REQUIRE(JsonBool(badAxis, "ok", false));
  REQUIRE(JsonContains(badAxis, "\"code\":\"InvalidArgument\""));
}

TEST_CASE("layout.snap returns guides and deltas within threshold",
          "[layout]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":100,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());

  // x=97 is 3px from the left edge (100): snaps; y=37 is far from 0/25/50.
  std::string response = wb::invokeDomain(
      "layout", "snap", "{\"pageId\":\"" + pageId + "\",\"x\":97,\"y\":37}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "snappedX") == 100.0);
  REQUIRE(JsonNumber(response, "snappedY") == 37.0);
  REQUIRE(JsonNumber(response, "deltaX") == 3.0);
  REQUIRE(JsonNumber(response, "deltaY") == 0.0);
  REQUIRE(JsonContains(response, "\"axis\":\"x\""));
  REQUIRE(JsonContains(response, "\"position\":100.0"));
  REQUIRE(JsonContains(response, "\"" + a + "\""));

  // Outside the 8px threshold nothing snaps and no guides are reported.
  response = wb::invokeDomain(
      "layout", "snap", "{\"pageId\":\"" + pageId + "\",\"x\":50,\"y\":120}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "snappedX") == 50.0);
  REQUIRE(JsonNumber(response, "deltaX") == 0.0);
  REQUIRE(JsonNumber(response, "snappedY") == 120.0);
  REQUIRE(JsonContains(response, "\"guides\":[]"));

  // Excluded (dragged) elements do not act as guides.
  response = wb::invokeDomain(
      "layout", "snap",
      "{\"pageId\":\"" + pageId + "\",\"x\":97,\"y\":25,\"excludeIds\":" +
          JsonIdArray({a}) + "}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "snappedX") == 97.0);
  REQUIRE(JsonContains(response, "\"guides\":[]"));

  // Custom threshold widens the catch radius.
  response = wb::invokeDomain(
      "layout", "snap",
      "{\"pageId\":\"" + pageId +
          "\",\"x\":90,\"y\":25,\"threshold\":15}");
  REQUIRE(JsonNumber(response, "snappedX") == 100.0);
  REQUIRE(JsonNumber(response, "deltaX") == 10.0);
}

TEST_CASE("layout ops report NotFound for unknown pages", "[layout]") {
  const std::string missing = "page-nope";
  REQUIRE(JsonBool(AlignOp(missing, {"e1", "e2"}, "left"), "ok", false));
  REQUIRE(JsonBool(DistributeOp(missing, {"e1", "e2", "e3"}, "horizontal"),
                   "ok", false));
  REQUIRE(JsonBool(wb::invokeDomain(
                       "layout", "snap",
                       "{\"pageId\":\"" + missing + "\",\"x\":0,\"y\":0}"),
                   "ok", false));
}
