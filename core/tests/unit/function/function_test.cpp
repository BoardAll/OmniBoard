// tests/unit/function/function_test.cpp — domain "function" (1.5).

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

std::string CreatePlot(const Scene& scene) {
  const std::string response = wb::invokeDomain(
      "function", "create",
      "{\"pageId\":\"" + scene.pageId +
          "\",\"element\":{\"position\":{\"x\":0,\"y\":0},"
          "\"size\":{\"width\":400,\"height\":300}}}");
  return JsonBool(response, "ok", true) ? JsonString(response, "elementId")
                                        : std::string();
}

}  // namespace

TEST_CASE("function add parses expressions and dedups ids", "[function]") {
  const Scene scene = NewScene();
  const std::string plot = CreatePlot(scene);
  REQUIRE(!plot.empty());

  const std::string first = wb::invokeDomain(
      "function", "add",
      "{\"elementId\":\"" + plot + "\",\"expression\":\"y = sin(x)\"}");
  REQUIRE(JsonBool(first, "ok", true));
  REQUIRE(JsonNumber(first, "expressionCount") == 1.0);
  REQUIRE(JsonContains(first, "\"id\":\"expr-1\""));
  REQUIRE(JsonContains(first, "\"expression\":\"y = sin(x)\""));

  const std::string second = wb::invokeDomain(
      "function", "add",
      "{\"elementId\":\"" + plot + "\",\"expression\":\"x^2 + 1\"}");
  REQUIRE(JsonNumber(second, "expressionCount") == 2.0);
  REQUIRE(JsonContains(second, "\"id\":\"expr-2\""));

  // Malformed expressions are refused before touching the element.
  const std::string broken = wb::invokeDomain(
      "function", "add",
      "{\"elementId\":\"" + plot + "\",\"expression\":\"sin(\"}");
  REQUIRE(JsonBool(broken, "ok", false));
  REQUIRE(JsonString(broken, "code") == "InvalidArgument");

  const std::string removed = wb::invokeDomain(
      "function", "remove",
      "{\"elementId\":\"" + plot + "\",\"expressionId\":\"expr-1\"}");
  REQUIRE(JsonBool(removed, "ok", true));
  REQUIRE(JsonNumber(removed, "expressionCount") == 1.0);

  const std::string missing = wb::invokeDomain(
      "function", "remove",
      "{\"elementId\":\"" + plot + "\",\"expressionId\":\"expr-99\"}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonString(missing, "code") == "NotFound");
}

TEST_CASE("function analyze finds zeros and extrema", "[function]") {
  const Scene scene = NewScene();
  const std::string plot = CreatePlot(scene);
  wb::invokeDomain("function", "add",
                   "{\"elementId\":\"" + plot + "\",\"expression\":\"sin(x)\"}");

  const std::string zeros = wb::invokeDomain(
      "function", "analyze",
      "{\"elementId\":\"" + plot + "\",\"type\":\"zeros\"}");
  REQUIRE(JsonBool(zeros, "ok", true));
  REQUIRE(JsonContains(zeros, "\"zeros\":["));
  // sin(x) over [-10,10] crosses zero 7 times.
  REQUIRE(JsonContains(zeros, "-9.4247"));

  const std::string extrema = wb::invokeDomain(
      "function", "analyze",
      "{\"elementId\":\"" + plot + "\",\"type\":\"extrema\"}");
  REQUIRE(JsonBool(extrema, "ok", true));
  REQUIRE(JsonContains(extrema, "\"type\":\"max\""));
  REQUIRE(JsonContains(extrema, "\"type\":\"min\""));

  const std::string unknown = wb::invokeDomain(
      "function", "analyze",
      "{\"elementId\":\"" + plot + "\",\"type\":\"nope\"}");
  REQUIRE(JsonBool(unknown, "ok", false));
  REQUIRE(JsonString(unknown, "code") == "InvalidArgument");
}

TEST_CASE("function analyze integral, area and symmetry", "[function]") {
  const Scene scene = NewScene();
  const std::string plot = CreatePlot(scene);
  wb::invokeDomain("function", "add",
                   "{\"elementId\":\"" + plot + "\",\"expression\":\"x\"}");

  const std::string integral = wb::invokeDomain(
      "function", "analyze",
      "{\"elementId\":\"" + plot + "\",\"type\":\"integral\"}");
  REQUIRE(JsonBool(integral, "ok", true));
  const double value = JsonNumber(integral, "integral");
  REQUIRE(std::fabs(value) < 1e-6);  // odd function over a symmetric viewport

  const std::string area = wb::invokeDomain(
      "function", "analyze",
      "{\"elementId\":\"" + plot + "\",\"type\":\"area\"}");
  // |x| has a corner at 0 which falls between sample grid points, so the
  // trapezoid rule carries an O(h^2) error of ~0.0015 here.
  REQUIRE(std::fabs(JsonNumber(area, "area") - 100.0) < 1e-2);

  const std::string derivative = wb::invokeDomain(
      "function", "analyze",
      "{\"elementId\":\"" + plot + "\",\"type\":\"derivative\"}");
  REQUIRE(JsonBool(derivative, "ok", true));
  REQUIRE(JsonNumber(derivative, "count") == 256.0);

  const std::string even = wb::invokeDomain(
      "function", "analyze",
      "{\"elementId\":\"" + plot + "\",\"type\":\"all\"}");
  REQUIRE(JsonBool(even, "ok", true));
  REQUIRE(JsonContains(even, "\"symmetry\":\"odd\""));

  const std::string square = CreatePlot(scene);
  wb::invokeDomain("function", "add",
                   "{\"elementId\":\"" + square + "\",\"expression\":\"x^2\"}");
  const std::string symmetric = wb::invokeDomain(
      "function", "analyze",
      "{\"elementId\":\"" + square + "\",\"type\":\"symmetry\"}");
  REQUIRE(JsonContains(symmetric, "\"symmetry\":\"even\""));
}

TEST_CASE("function export produces csv and json samples", "[function]") {
  const Scene scene = NewScene();
  const std::string plot = CreatePlot(scene);
  wb::invokeDomain("function", "add",
                   "{\"elementId\":\"" + plot + "\",\"expression\":\"x^2\"}");

  const std::string csv = wb::invokeDomain(
      "function", "export",
      "{\"elementId\":\"" + plot + "\",\"format\":\"csv\"}");
  REQUIRE(JsonBool(csv, "ok", true));
  REQUIRE(JsonString(csv, "format") == "csv");
  REQUIRE(JsonContains(csv, "x,y\\n"));  // header, JSON-escaped newline

  const std::string json = wb::invokeDomain(
      "function", "export",
      "{\"elementId\":\"" + plot + "\",\"format\":\"json\"}");
  REQUIRE(JsonBool(json, "ok", true));
  REQUIRE(JsonContains(json, "\"points\":["));
  REQUIRE(JsonNumber(json, "count") == 256.0);

  const std::string bad = wb::invokeDomain(
      "function", "export",
      "{\"elementId\":\"" + plot + "\",\"format\":\"xml\"}");
  REQUIRE(JsonBool(bad, "ok", false));
  REQUIRE(JsonString(bad, "code") == "InvalidArgument");
}

TEST_CASE("function setStyle targets global style or one expression",
          "[function]") {
  const Scene scene = NewScene();
  const std::string plot = CreatePlot(scene);
  wb::invokeDomain("function", "add",
                   "{\"elementId\":\"" + plot + "\",\"expression\":\"x\"}");

  const std::string global = wb::invokeDomain(
      "function", "setStyle",
      "{\"elementId\":\"" + plot +
          "\",\"style\":{\"grid\":{\"show\":false}}}");
  REQUIRE(JsonBool(global, "ok", true));

  const std::string perExpression = wb::invokeDomain(
      "function", "setStyle",
      "{\"elementId\":\"" + plot +
          "\",\"style\":{\"expressionId\":\"expr-1\",\"color\":\"#FF0000\"}}");
  REQUIRE(JsonBool(perExpression, "ok", true));
  REQUIRE(JsonContains(perExpression, "\"color\":\"#FF0000\""));

  const std::string missing = wb::invokeDomain(
      "function", "setStyle",
      "{\"elementId\":\"" + plot +
          "\",\"style\":{\"expressionId\":\"expr-9\",\"color\":\"#000000\"}}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonString(missing, "code") == "NotFound");
}

TEST_CASE("function guards element type, page lock and list filtering",
          "[function]") {
  const Scene scene = NewScene();
  const std::string plot = CreatePlot(scene);
  const std::string sticky = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}");

  const std::string wrong = wb::invokeDomain(
      "function", "add",
      "{\"elementId\":\"" + sticky + "\",\"expression\":\"x\"}");
  REQUIRE(JsonBool(wrong, "ok", false));
  REQUIRE(JsonString(wrong, "code") == "InvalidArgument");

  const std::string unknownElement = wb::invokeDomain(
      "function", "add",
      "{\"elementId\":\"element-nope\",\"expression\":\"x\"}");
  REQUIRE(JsonString(unknownElement, "code") == "NotFound");

  const std::string list = wb::invokeDomain(
      "function", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonNumber(list, "count") == 1.0);
  REQUIRE(JsonContains(list, "\"type\":\"function\""));

  wb::invokeDomain("page", "lock",
                   "{\"pageId\":\"" + scene.pageId + "\",\"locked\":true}");
  const std::string locked = wb::invokeDomain(
      "function", "add",
      "{\"elementId\":\"" + plot + "\",\"expression\":\"x\"}");
  REQUIRE(JsonBool(locked, "ok", false));
  REQUIRE(JsonString(locked, "code") == "Conflict");
}
