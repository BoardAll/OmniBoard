// benchmarks/bench_flowchart_function.cpp — 流程图布局与函数数据生成基准
// （Wave 4.1）。
//
// 对齐《测试方案设计》§10.1/§10.2：
//   1. 流程图 autoLayout topToBottom（100 节点 / 99 条边）——对齐
//      §10.1「100 节点自动布局 < 100ms」验收线。
//   2. 函数 analyze all（sin(x)：256 采样点 + 零点/极值/导数/积分/对称性）。
//   3. 函数导出 CSV（sin(x)：256 采样点）。
//
// 场景固定：n0 → n1 → … → n99 链式有向图（process 节点）；函数表达式
// "sin(x)"（默认 viewport [-10,10]²、256 采样）；无随机、不依赖系统时间。

#include <catch2/benchmark/catch_benchmark.hpp>
#include <catch2/catch_test_macros.hpp>

#include <string>

#include "support/bench_util.h"

namespace {

constexpr int kNodeCount = 100;

}  // namespace

TEST_CASE("流程图布局与函数数据生成基准", "[bench][flowchart][function]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  // 100 节点链式流程图（n0 → n1 → … → n99，共 99 条边）。
  const std::string flowId = JsonString(
      TakeAndFree(wb_flowchart_create(scene.pageId.c_str(), "{}")), "elementId");
  REQUIRE_FALSE(flowId.empty());
  for (int i = 0; i < kNodeCount; ++i) {
    const std::string node =
        wb::invokeDomain("flowchart", "addNode",
                         "{\"flowchartId\":\"" + flowId +
                             "\",\"node\":{\"id\":\"n" + std::to_string(i) +
                             "\",\"type\":\"process\",\"text\":\"n" +
                             std::to_string(i) + "\"}}");
    REQUIRE(JsonBool(node, "ok", true));
  }
  for (int i = 0; i + 1 < kNodeCount; ++i) {
    const std::string edge = wb::invokeDomain(
        "flowchart", "connect",
        "{\"flowchartId\":\"" + flowId + "\",\"from\":\"n" +
            std::to_string(i) + "\",\"to\":\"n" + std::to_string(i + 1) +
            "\"}");
    REQUIRE(JsonBool(edge, "ok", true));
  }
  {
    const std::string layout = TakeAndFree(wb_flowchart_auto_layout(
        flowId.c_str(), "{\"direction\":\"topToBottom\"}"));
    REQUIRE(JsonBool(layout, "ok", true));
    REQUIRE(JsonNumber(layout, "nodeCount") == static_cast<double>(kNodeCount));
    REQUIRE(JsonNumber(layout, "connectorCount") ==
            static_cast<double>(kNodeCount - 1));
  }

  BENCHMARK("流程图 autoLayout topToBottom（100 节点 / 99 条边）") {
    return TakeAndFree(wb_flowchart_auto_layout(
        flowId.c_str(), "{\"direction\":\"topToBottom\"}"));
  };

  // 函数元素（sin(x)，默认 viewport / 256 采样）。
  const std::string fnId = JsonString(
      TakeAndFree(wb_function_create(scene.pageId.c_str(), "{}")), "elementId");
  REQUIRE_FALSE(fnId.empty());
  REQUIRE(JsonBool(TakeAndFree(wb_function_add(fnId.c_str(), "sin(x)")), "ok",
                   true));

  BENCHMARK("函数 analyze all（sin(x)，256 采样点全分析）") {
    return TakeAndFree(wb_function_analyze(fnId.c_str(), "all"));
  };

  BENCHMARK("函数导出 CSV（sin(x)，256 采样点）") {
    return TakeAndFree(wb_function_export(fnId.c_str(), "csv"));
  };
}
