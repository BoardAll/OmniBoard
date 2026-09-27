// tests/integration/test_flowchart_render.cpp — 集成链路：流程图 × 渲染数据
// （《测试方案设计》§7.1 清单第 3 项）。
//
// 覆盖链路：
//   1. flowchart.create/addNode/connect → 节点 incoming/outgoing 与连线联动。
//   2. autoLayout(topToBottom) → 分层坐标单调、polyline waypoints 生成。
//   3. labelBranches → decision 出边标注 "是"/"否"。
//   4. toSwimlane → 未分组节点归入 lane-1 泳道。
//   5. render.getDisplayList → 流程图出现在 Dynamic 层、dirtyRect 生成、
//      layer 过滤联动（跨模块数据 → 渲染数据生成链路）。
//
// 注：nlohmann::json 按键字典序 dump，autoLayout 响应里 connectors（含
// waypoints）先于 nodes 输出，因此节点坐标用锚定 "nodes" 之后的探针读取。

#include <catch2/catch_test_macros.hpp>

#include <string>
#include <vector>

#include "support/test_probe.h"

namespace {

/// 建好流程图元素（带显式几何，便于渲染 dirtyRect 断言）。
struct FlowScene {
  Scene scene;
  std::string flowchartId;
};

FlowScene BuildFlowchart() {
  FlowScene flow;
  flow.scene = MakeScene();
  const std::string created = TakeAndFree(wb_flowchart_create(
      flow.scene.pageId.c_str(),
      "{\"position\":{\"x\":100,\"y\":100},\"size\":{\"width\":400,"
      "\"height\":300}}"));
  flow.flowchartId = JsonString(created, "elementId");
  return flow;
}

std::string AddNode(const std::string& flowchartId, const std::string& id,
                    const std::string& type) {
  return wb::invokeDomain(
      "flowchart", "addNode",
      "{\"flowchartId\":\"" + flowchartId + "\",\"node\":{\"id\":\"" + id +
          "\",\"type\":\"" + type + "\",\"text\":\"" + id + "\"}}");
}

std::string Connect(const std::string& flowchartId, const std::string& from,
                    const std::string& to) {
  return wb::invokeDomain("flowchart", "connect",
                          "{\"flowchartId\":\"" + flowchartId +
                              "\",\"from\":\"" + from + "\",\"to\":\"" + to +
                              "\"}");
}

}  // namespace

TEST_CASE("flowchart render: connect and autoLayout produce render data",
          "[integration][flowchart][render]") {
  const FlowScene flow = BuildFlowchart();
  REQUIRE(flow.scene.ok);
  REQUIRE_FALSE(flow.flowchartId.empty());

  // 1) 增节点：nodeCount 递增。
  REQUIRE(JsonBool(AddNode(flow.flowchartId, "n1", "start"), "ok", true));
  REQUIRE(JsonBool(AddNode(flow.flowchartId, "n2", "process"), "ok", true));
  REQUIRE(JsonBool(AddNode(flow.flowchartId, "n3", "decision"), "ok", true));
  REQUIRE(JsonBool(AddNode(flow.flowchartId, "n4", "end"), "ok", true));
  const std::string lastNode = AddNode(flow.flowchartId, "n5", "end");
  REQUIRE(JsonBool(lastNode, "ok", true));
  REQUIRE(JsonNumber(lastNode, "nodeCount") == 5.0);

  // 2) 连线：connectorCount 递增；incoming/outgoing 随 connect 更新。
  REQUIRE(JsonBool(Connect(flow.flowchartId, "n1", "n2"), "ok", true));
  REQUIRE(JsonBool(Connect(flow.flowchartId, "n2", "n3"), "ok", true));
  REQUIRE(JsonBool(Connect(flow.flowchartId, "n3", "n4"), "ok", true));
  const std::string lastEdge = Connect(flow.flowchartId, "n3", "n5");
  REQUIRE(JsonBool(lastEdge, "ok", true));
  REQUIRE(JsonNumber(lastEdge, "connectorCount") == 4.0);
  REQUIRE(JsonContains(lastEdge, "\"id\":\"edge-4\""));
  REQUIRE(JsonContains(lastEdge, "\"from\":\"n3\""));
  REQUIRE(JsonContains(lastEdge, "\"to\":\"n5\""));

  // 3) autoLayout(topToBottom)：分层坐标向下单调；同层节点对齐。
  const std::string layout = TakeAndFree(wb_flowchart_auto_layout(
      flow.flowchartId.c_str(), "{\"direction\":\"topToBottom\"}"));
  REQUIRE(JsonBool(layout, "ok", true));
  REQUIRE(JsonNumber(layout, "nodeCount") == 5.0);
  REQUIRE(JsonNumber(layout, "connectorCount") == 4.0);
  REQUIRE(JsonString(layout, "direction") == "topToBottom");
  {
    // 节点坐标锚定 "nodes" 数组之后读取（waypoints 在 connectors 中先输出）。
    const std::size_t nodesPos = layout.find("\"nodes\":[");
    REQUIRE(nodesPos != std::string::npos);
    const std::vector<double> ys = JsonNumbersAt(layout, "y", nodesPos);
    REQUIRE(ys.size() == 5);
    // 层 0 < 层 1 < 层 2 < 层 3，且 n4 / n5 同层 y 相同。
    REQUIRE(ys[0] < ys[1]);
    REQUIRE(ys[1] < ys[2]);
    REQUIRE(ys[2] < ys[3]);
    REQUIRE(ys[3] == ys[4]);

    // n3 outgoing list accumulates both connectors: edge-3, edge-4.
    const std::size_t n3Pos = layout.find("\"id\":\"n3\"", nodesPos);
    REQUIRE(n3Pos != std::string::npos);
    REQUIRE(JsonContains(layout.substr(n3Pos, 512),
                         "\"outgoing\":[\"edge-3\",\"edge-4\"]"));
  }
  // 4 条 polyline 连线都生成了正交折线 waypoints。
  REQUIRE(CountOccurrences(layout, "\"waypoints\":[{\"x\":") == 4);

  // 4) labelBranches：decision 的两条出边分别标 "是"/"否"。
  const std::string labeled =
      TakeAndFree(wb_flowchart_label_branches(flow.flowchartId.c_str()));
  REQUIRE(JsonBool(labeled, "ok", true));
  REQUIRE(JsonNumber(labeled, "decisionCount") == 1.0);
  REQUIRE(JsonNumber(labeled, "labeled") == 2.0);
  REQUIRE(JsonContains(labeled, "\"是\""));
  REQUIRE(JsonContains(labeled, "\"否\""));

  // 5) toSwimlane：未分组节点全部归入 lane-1。
  const std::string swimlane =
      TakeAndFree(wb_flowchart_to_swimlane(flow.flowchartId.c_str(), 0));
  REQUIRE(JsonBool(swimlane, "ok", true));
  REQUIRE(JsonNumber(swimlane, "laneCount") == 1.0);
  REQUIRE(JsonContains(swimlane, "lane-1"));
  REQUIRE(JsonContains(swimlane, "泳道 1"));

  // 6) 渲染数据链路：flowchart 出现在 Dynamic 层，dirtyRect 与元素几何对齐。
  const std::string display = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + flow.scene.pageId + "\"}");
  REQUIRE(JsonBool(display, "ok", true));
  REQUIRE(JsonNumber(display, "count") == 1.0);
  REQUIRE(JsonContains(display, "\"type\":\"flowchart\""));
  REQUIRE(JsonContains(display, "\"layer\":\"Dynamic\""));
  // dirtyRect 键序为 height/width/x/y（字典序），100×100 起 400×300。
  REQUIRE(JsonContains(display, "\"dirtyRect\":{\"height\":300"));
  REQUIRE(JsonContains(display, "\"width\":400"));

  // 7) layer 过滤：Function 层为空、Dynamic 层命中。
  const std::string functionLayer = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + flow.scene.pageId + "\",\"layer\":\"Function\"}");
  REQUIRE(JsonNumber(functionLayer, "count") == 0.0);
  const std::string dynamicLayer = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + flow.scene.pageId + "\",\"layer\":\"Dynamic\"}");
  REQUIRE(JsonNumber(dynamicLayer, "count") == 1.0);
}

TEST_CASE("flowchart render: removing node cascades connector cleanup", "[integration][flowchart]") {
  const FlowScene flow = BuildFlowchart();
  REQUIRE(flow.scene.ok);
  REQUIRE(JsonBool(AddNode(flow.flowchartId, "n1", "start"), "ok", true));
  REQUIRE(JsonBool(AddNode(flow.flowchartId, "n2", "process"), "ok", true));
  REQUIRE(JsonBool(Connect(flow.flowchartId, "n1", "n2"), "ok", true));

  const std::string removed = wb::invokeDomain(
      "flowchart", "removeNode",
      "{\"flowchartId\":\"" + flow.flowchartId + "\",\"nodeId\":\"n1\"}");
  REQUIRE(JsonBool(removed, "ok", true));
  REQUIRE(JsonNumber(removed, "nodeCount") == 1.0);
  REQUIRE(JsonNumber(removed, "connectorCount") == 0.0);

  // 未知节点：NotFound。
  const std::string missing = wb::invokeDomain(
      "flowchart", "removeNode",
      "{\"flowchartId\":\"" + flow.flowchartId + "\",\"nodeId\":\"ghost\"}");
  REQUIRE(JsonBool(missing, "ok", false));
}
