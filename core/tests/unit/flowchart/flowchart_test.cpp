// tests/unit/flowchart/flowchart_test.cpp — domain "flowchart" (1.5).

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

std::string CreateFlowchart(const Scene& scene) {
  const std::string response = wb::invokeDomain(
      "flowchart", "create",
      "{\"pageId\":\"" + scene.pageId +
          "\",\"element\":{\"position\":{\"x\":0,\"y\":0},"
          "\"size\":{\"width\":600,\"height\":400}}}");
  return JsonBool(response, "ok", true) ? JsonString(response, "elementId")
                                        : std::string();
}

std::string AddNode(const std::string& flowchartId, const std::string& body) {
  const std::string response = wb::invokeDomain(
      "flowchart", "addNode",
      "{\"flowchartId\":\"" + flowchartId + "\",\"node\":" + body + "}");
  return JsonBool(response, "ok", true) ? JsonString(response, "id")
                                        : std::string();
}

void Connect(const std::string& flowchartId, const std::string& from,
             const std::string& to) {
  const std::string response = wb::invokeDomain(
      "flowchart", "connect",
      "{\"flowchartId\":\"" + flowchartId + "\",\"from\":\"" + from +
          "\",\"to\":\"" + to + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
}

/// Position value of node `id` inside an autoLayout response. The connectors
/// array dumps before nodes alphabetically and also carries node ids inside
/// from/to, so the search is anchored to the nodes array.
double NodeNumber(const std::string& response, const std::string& id,
                  const std::string& key) {
  const std::size_t nodes = response.find("\"nodes\":[");
  REQUIRE(nodes != std::string::npos);
  const std::size_t pos = response.find("\"" + id + "\"", nodes);
  REQUIRE(pos != std::string::npos);
  return JsonNumberAt(response, key, pos);
}

}  // namespace

TEST_CASE("flowchart autoLayout layers nodes top to bottom", "[flowchart]") {
  const Scene scene = NewScene();
  const std::string flow = CreateFlowchart(scene);
  REQUIRE(!flow.empty());

  const std::string start = AddNode(flow, "{\"type\":\"start\",\"text\":\"开始\"}");
  const std::string step = AddNode(flow, "{\"type\":\"process\",\"text\":\"处理\"}");
  const std::string check = AddNode(flow, "{\"type\":\"decision\",\"text\":\"判断\"}");
  const std::string end = AddNode(flow, "{\"type\":\"end\",\"text\":\"结束\"}");
  REQUIRE(start == "node-1");
  REQUIRE(step == "node-2");
  REQUIRE(check == "node-3");
  REQUIRE(end == "node-4");

  Connect(flow, start, step);
  Connect(flow, step, check);
  Connect(flow, check, end);

  const std::string layout = wb::invokeDomain(
      "flowchart", "autoLayout", "{\"flowchartId\":\"" + flow + "\"}");
  REQUIRE(JsonBool(layout, "ok", true));
  REQUIRE(JsonNumber(layout, "nodeCount") == 4.0);
  REQUIRE(JsonNumber(layout, "connectorCount") == 3.0);
  REQUIRE(JsonContains(layout, "\"direction\":\"topToBottom\""));

  // Each layer sits below the previous one (layer height 60 + gap 60).
  const double y1 = NodeNumber(layout, "node-1", "y");
  const double y2 = NodeNumber(layout, "node-2", "y");
  const double y3 = NodeNumber(layout, "node-3", "y");
  const double y4 = NodeNumber(layout, "node-4", "y");
  REQUIRE(y2 >= y1 + 60.0);
  REQUIRE(y3 >= y2 + 60.0);
  REQUIRE(y4 >= y3 + 60.0);
  // Default node width 160 centred on x=0.
  REQUIRE(std::fabs(NodeNumber(layout, "node-1", "x") + 80.0) < 1e-6);

  // Connectors carry orthogonal waypoints after layout.
  REQUIRE(JsonContains(layout, "\"waypoints\":["));
  REQUIRE(JsonContains(layout, "\"connectors\":["));
}

TEST_CASE("flowchart autoLayout keeps locked nodes in place", "[flowchart]") {
  const Scene scene = NewScene();
  const std::string flow = CreateFlowchart(scene);
  const std::string first = AddNode(flow, "{\"type\":\"start\",\"text\":\"A\"}");
  const std::string middle = AddNode(flow, "{\"type\":\"process\",\"text\":\"B\"}");
  const std::string last = AddNode(flow, "{\"type\":\"end\",\"text\":\"C\"}");
  Connect(flow, first, middle);
  Connect(flow, middle, last);

  const std::string locked = wb::invokeDomain(
      "flowchart", "lockNode",
      "{\"flowchartId\":\"" + flow + "\",\"nodeId\":\"" + middle + "\"}");
  REQUIRE(JsonBool(locked, "ok", true));
  REQUIRE(JsonBool(locked, "locked", true));

  const std::string layout = wb::invokeDomain(
      "flowchart", "autoLayout", "{\"flowchartId\":\"" + flow + "\"}");
  REQUIRE(JsonBool(layout, "ok", true));
  // The locked node keeps its original box (0,0).
  REQUIRE(std::fabs(NodeNumber(layout, "node-2", "y")) < 1e-6);
  REQUIRE(std::fabs(NodeNumber(layout, "node-2", "x")) < 1e-6);
  // Others still move.
  const double y3 = NodeNumber(layout, "node-3", "y");
  REQUIRE(y3 >= 120.0);
}

TEST_CASE("flowchart leftToRight switches the layout axis", "[flowchart]") {
  const Scene scene = NewScene();
  const std::string flow = CreateFlowchart(scene);
  const std::string a = AddNode(flow, "{\"type\":\"start\",\"text\":\"A\"}");
  const std::string b = AddNode(flow, "{\"type\":\"process\",\"text\":\"B\"}");
  Connect(flow, a, b);

  const std::string layout = wb::invokeDomain(
      "flowchart", "autoLayout",
      "{\"flowchartId\":\"" + flow +
          "\",\"options\":{\"direction\":\"leftToRight\"}}");
  REQUIRE(JsonBool(layout, "ok", true));
  REQUIRE(JsonContains(layout, "\"direction\":\"leftToRight\""));
  const double x1 = NodeNumber(layout, "node-1", "x");
  const double x2 = NodeNumber(layout, "node-2", "x");
  REQUIRE(x2 >= x1 + 160.0);
  // Same y centre for both columns.
  REQUIRE(std::fabs(NodeNumber(layout, "node-1", "y") -
                    NodeNumber(layout, "node-2", "y")) < 1e-6);

  const std::string bad = wb::invokeDomain(
      "flowchart", "autoLayout",
      "{\"flowchartId\":\"" + flow +
          "\",\"options\":{\"direction\":\"diagonal\"}}");
  REQUIRE(JsonBool(bad, "ok", false));
  REQUIRE(JsonString(bad, "code") == "InvalidArgument");
}

TEST_CASE("flowchart labelBranches marks yes/no edges once", "[flowchart]") {
  const Scene scene = NewScene();
  const std::string flow = CreateFlowchart(scene);
  const std::string check = AddNode(flow, "{\"type\":\"decision\",\"text\":\"判断\"}");
  const std::string yes = AddNode(flow, "{\"type\":\"process\",\"text\":\"是\"}");
  const std::string no = AddNode(flow, "{\"type\":\"process\",\"text\":\"否\"}");
  const std::string plain = AddNode(flow, "{\"type\":\"process\",\"text\":\"普通\"}");
  Connect(flow, check, yes);
  Connect(flow, check, no);
  Connect(flow, plain, yes);  // non-decision edge stays unlabelled

  const std::string labeled = wb::invokeDomain(
      "flowchart", "labelBranches", "{\"flowchartId\":\"" + flow + "\"}");
  REQUIRE(JsonBool(labeled, "ok", true));
  REQUIRE(JsonNumber(labeled, "labeled") == 2.0);
  REQUIRE(JsonNumber(labeled, "decisionCount") == 1.0);
  REQUIRE(JsonContains(labeled, "\"label\":\"是\""));
  REQUIRE(JsonContains(labeled, "\"label\":\"否\""));

  // Second run is a no-op because the labels already exist.
  const std::string again = wb::invokeDomain(
      "flowchart", "labelBranches", "{\"flowchartId\":\"" + flow + "\"}");
  REQUIRE(JsonNumber(again, "labeled") == 0.0);
}

TEST_CASE("flowchart toSwimlane builds lanes from node groups", "[flowchart]") {
  const Scene scene = NewScene();
  const std::string plain = CreateFlowchart(scene);
  const std::string a = AddNode(plain, "{\"type\":\"process\",\"text\":\"A\"}");
  const std::string b = AddNode(plain, "{\"type\":\"process\",\"text\":\"B\"}");
  REQUIRE(!a.empty());

  const std::string single = wb::invokeDomain(
      "flowchart", "toSwimlane",
      "{\"flowchartId\":\"" + plain + "\",\"orientation\":0}");
  REQUIRE(JsonBool(single, "ok", true));
  REQUIRE(JsonNumber(single, "laneCount") == 1.0);
  REQUIRE(JsonString(single, "orientation") == "horizontal");
  REQUIRE(JsonContains(single, "\"name\":\"泳道 1\""));
  REQUIRE(JsonContains(single, "\"id\":\"lane-1\""));

  const std::string grouped = CreateFlowchart(scene);
  AddNode(grouped, "{\"type\":\"process\",\"text\":\"A\",\"swimlaneId\":\"lane-a\"}");
  AddNode(grouped, "{\"type\":\"process\",\"text\":\"B\",\"swimlaneId\":\"lane-b\"}");
  const std::string lanes = wb::invokeDomain(
      "flowchart", "toSwimlane",
      "{\"flowchartId\":\"" + grouped + "\",\"orientation\":1}");
  REQUIRE(JsonNumber(lanes, "laneCount") == 2.0);
  REQUIRE(JsonString(lanes, "orientation") == "vertical");
  REQUIRE(JsonContains(lanes, "\"id\":\"lane-a\""));
  REQUIRE(JsonContains(lanes, "\"id\":\"lane-b\""));
}

TEST_CASE("flowchart refuses bad references and locked pages", "[flowchart]") {
  const Scene scene = NewScene();
  const std::string flow = CreateFlowchart(scene);
  const std::string node = AddNode(flow, "{\"type\":\"process\",\"text\":\"A\"}");

  const std::string badTarget = wb::invokeDomain(
      "flowchart", "connect",
      "{\"flowchartId\":\"" + flow + "\",\"from\":\"" + node +
          "\",\"to\":\"node-404\"}");
  REQUIRE(JsonBool(badTarget, "ok", false));
  REQUIRE(JsonString(badTarget, "code") == "NotFound");

  const std::string badLayout = wb::invokeDomain(
      "flowchart", "autoLayout", "{\"flowchartId\":\"element-nope\"}");
  REQUIRE(JsonBool(badLayout, "ok", false));
  REQUIRE(JsonString(badLayout, "code") == "NotFound");

  const std::string firstEdge = wb::invokeDomain(
      "flowchart", "connect",
      "{\"flowchartId\":\"" + flow + "\",\"id\":\"edge-x\",\"from\":\"" + node +
          "\",\"to\":\"" + node + "\"}");
  REQUIRE(JsonBool(firstEdge, "ok", true));

  const std::string duplicate = wb::invokeDomain(
      "flowchart", "connect",
      "{\"flowchartId\":\"" + flow + "\",\"id\":\"edge-x\",\"from\":\"" + node +
          "\",\"to\":\"" + node + "\"}");
  REQUIRE(JsonBool(duplicate, "ok", false));
  REQUIRE(JsonString(duplicate, "code") == "Conflict");

  wb::invokeDomain("page", "lock",
                   "{\"pageId\":\"" + scene.pageId + "\",\"locked\":true}");
  const std::string locked = wb::invokeDomain(
      "flowchart", "addNode",
      "{\"flowchartId\":\"" + flow + "\",\"node\":{\"type\":\"process\"}}");
  REQUIRE(JsonBool(locked, "ok", false));
  REQUIRE(JsonString(locked, "code") == "Conflict");

  const std::string list = wb::invokeDomain(
      "flowchart", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonNumber(list, "count") == 1.0);
  REQUIRE(JsonContains(list, "\"nodeCount\":1"));
}
