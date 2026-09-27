// tests/integration/test_function_render.cpp — 集成链路：函数绘图 × 渲染数据
// （《测试方案设计》§7.1 清单第 4 项）。
//
// 覆盖链路：
//   1. function.create → function.add（多表达式、expr-N 编号）与
//      analyze 数据生成链路（零点/极值/导数/积分/面积/对称性）。
//   2. export(json/csv) → 采样点与首可见表达式联动。
//   3. function.list 的 expressionCount 摘要联动。
//   4. render.getDisplayList → 函数元素进入 Function 层、dirtyRect 与
//      元素几何（position/size 嵌套结构）对齐、layer 过滤联动。
//
// 注：nlohmann::json 按键字典序 dump；csv 内容为内嵌转义字符串，
// 探针按原始转义形态（\n）匹配。

#include <catch2/catch_test_macros.hpp>

#include <string>
#include <vector>

#include "support/test_probe.h"

namespace {

/// 建好函数元素（显式几何，便于渲染 dirtyRect 断言）。
struct FunctionScene {
  Scene scene;
  std::string functionId;
};

FunctionScene BuildFunction() {
  FunctionScene fn;
  fn.scene = MakeScene();
  const std::string created = TakeAndFree(wb_function_create(
      fn.scene.pageId.c_str(),
      "{\"position\":{\"x\":60,\"y\":70},\"size\":{\"width\":320,"
      "\"height\":240}}"));
  fn.functionId = JsonString(created, "elementId");
  return fn;
}

}  // namespace

TEST_CASE("function render: expression analysis generates samples",
          "[integration][function]") {
  const FunctionScene fn = BuildFunction();
  REQUIRE(fn.scene.ok);
  REQUIRE_FALSE(fn.functionId.empty());

  // 1) 表达式管理：add 递增 expressionCount，expr-N 自动编号。
  const std::string first =
      TakeAndFree(wb_function_add(fn.functionId.c_str(), "sin(x)"));
  REQUIRE(JsonBool(first, "ok", true));
  REQUIRE(JsonNumber(first, "expressionCount") == 1.0);
  REQUIRE(JsonContains(first, "\"id\":\"expr-1\""));
  REQUIRE(JsonContains(first, "\"expression\":\"sin(x)\""));

  const std::string second =
      TakeAndFree(wb_function_add(fn.functionId.c_str(), "x^2"));
  REQUIRE(JsonBool(second, "ok", true));
  REQUIRE(JsonNumber(second, "expressionCount") == 2.0);
  REQUIRE(JsonContains(second, "\"id\":\"expr-2\""));

  // 非法表达式：InvalidArgument。
  const std::string bad =
      TakeAndFree(wb_function_add(fn.functionId.c_str(), "sin("));
  REQUIRE(JsonBool(bad, "ok", false));
  REQUIRE(JsonContains(bad, "InvalidArgument"));

  // 2) analyze("all")：首个可见表达式 sin(x) 的完整分析数据。
  const std::string analysis =
      TakeAndFree(wb_function_analyze(fn.functionId.c_str(), "all"));
  REQUIRE(JsonBool(analysis, "ok", true));
  REQUIRE(JsonContains(analysis, "\"expression\":\"sin(x)\""));
  REQUIRE(JsonContains(analysis, "\"type\":\"all\""));
  // sin(x) 在 [-10,10] 上零点非空（±π、±2π、±3π、0 附近）。
  REQUIRE(JsonContains(analysis, "\"zeros\":["));
  REQUIRE_FALSE(JsonContains(analysis, "\"zeros\":[]"));
  // 极值：±π/2、±3π/2、±5π/2 共 6 个（宽松断言 ≥4）。
  REQUIRE(JsonArrayLength(analysis, "extrema") >= 4);
  // 导数采样 256 点；对称性判定为奇函数。
  REQUIRE(JsonContains(analysis, "\"derivative\":{\"count\":256"));
  REQUIRE(JsonString(analysis, "symmetry") == "odd");
  REQUIRE(JsonContains(analysis, "\"integral\":"));
  REQUIRE(JsonContains(analysis, "\"area\":"));

  // 3) setStyle 指定表达式改色 → 元素数据联动。
  const std::string styled = TakeAndFree(wb_function_set_style(
      fn.functionId.c_str(),
      "{\"expressionId\":\"expr-1\",\"color\":\"#00FF00\"}"));
  REQUIRE(JsonBool(styled, "ok", true));
  REQUIRE(JsonContains(styled, "\"color\":\"#00FF00\""));

  // 未知表达式：NotFound。
  const std::string ghost = TakeAndFree(wb_function_set_style(
      fn.functionId.c_str(),
      "{\"expressionId\":\"expr-9\",\"color\":\"#000000\"}"));
  REQUIRE(JsonBool(ghost, "ok", false));
  REQUIRE(JsonContains(ghost, "NotFound"));
}

TEST_CASE("function render: export samples and display list layers",
          "[integration][function][render]") {
  const FunctionScene fn = BuildFunction();
  REQUIRE(fn.scene.ok);
  REQUIRE(JsonBool(TakeAndFree(wb_function_add(fn.functionId.c_str(), "sin(x)")),
                   "ok", true));

  // 1) export(json)：256 个采样点，首点 x = 视口左边界 -10。
  const std::string jsonExport =
      TakeAndFree(wb_function_export(fn.functionId.c_str(), "json"));
  REQUIRE(JsonBool(jsonExport, "ok", true));
  REQUIRE(JsonNumber(jsonExport, "count") == 256.0);
  REQUIRE(JsonContains(jsonExport, "\"format\":\"json\""));
  REQUIRE(JsonContains(jsonExport, "\"points\":[{\"x\":-10.0"));
  REQUIRE(JsonArrayLength(jsonExport, "points") == 256);

  // 2) export(csv)：CSV 头 "x,y\n"（内嵌转义串）。
  const std::string csvExport =
      TakeAndFree(wb_function_export(fn.functionId.c_str(), "csv"));
  REQUIRE(JsonBool(csvExport, "ok", true));
  REQUIRE(JsonContains(csvExport, "\"format\":\"csv\""));
  REQUIRE(JsonContains(csvExport, "\"csv\":\"x,y\\n"));
  REQUIRE(JsonNumber(csvExport, "count") == 256.0);

  // 未知导出格式：InvalidArgument。
  const std::string badExport =
      TakeAndFree(wb_function_export(fn.functionId.c_str(), "pdf"));
  REQUIRE(JsonBool(badExport, "ok", false));
  REQUIRE(JsonContains(badExport, "InvalidArgument"));

  // 3) 渲染数据链路：函数元素进入 Function 层，dirtyRect 与几何对齐。
  const std::string display = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + fn.scene.pageId + "\"}");
  REQUIRE(JsonBool(display, "ok", true));
  REQUIRE(JsonNumber(display, "count") == 1.0);
  REQUIRE(JsonContains(display, "\"type\":\"function\""));
  REQUIRE(JsonContains(display, "\"layer\":\"Function\""));
  // dirtyRect 键序为 height/width/x/y（字典序）：60,70 起 320×240。
  REQUIRE(JsonContains(display, "\"dirtyRect\":{\"height\":240"));
  REQUIRE(JsonContains(display, "\"width\":320"));

  // 4) layer 过滤联动：只保留 Function 层。
  const std::string functionLayer = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + fn.scene.pageId + "\",\"layer\":\"Function\"}");
  REQUIRE(JsonNumber(functionLayer, "count") == 1.0);
  const std::string dynamicLayer = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + fn.scene.pageId + "\",\"layer\":\"Dynamic\"}");
  REQUIRE(JsonNumber(dynamicLayer, "count") == 0.0);

  // 5) function.list 摘要联动：expressionCount 与表达式数一致。
  const std::string listed = wb::invokeDomain(
      "function", "list", "{\"pageId\":\"" + fn.scene.pageId + "\"}");
  REQUIRE(JsonBool(listed, "ok", true));
  REQUIRE(JsonNumber(listed, "count") == 1.0);
  REQUIRE(JsonContains(listed, "\"expressionCount\":1"));
}

TEST_CASE("function render: expression removal updates list counts",
          "[integration][function]") {
  const FunctionScene fn = BuildFunction();
  REQUIRE(fn.scene.ok);
  REQUIRE(JsonBool(TakeAndFree(wb_function_add(fn.functionId.c_str(), "sin(x)")),
                   "ok", true));
  REQUIRE(JsonBool(TakeAndFree(wb_function_add(fn.functionId.c_str(), "x^2")),
                   "ok", true));

  // 移除 expr-1 → 仅剩 1 条表达式（首可见变为 x^2）。
  const std::string removed = wb::invokeDomain(
      "function", "remove",
      "{\"elementId\":\"" + fn.functionId + "\",\"expressionId\":\"expr-1\"}");
  REQUIRE(JsonBool(removed, "ok", true));
  REQUIRE(JsonNumber(removed, "expressionCount") == 1.0);

  // 重复移除：NotFound。
  const std::string again = wb::invokeDomain(
      "function", "remove",
      "{\"elementId\":\"" + fn.functionId + "\",\"expressionId\":\"expr-1\"}");
  REQUIRE(JsonBool(again, "ok", false));
  REQUIRE(JsonContains(again, "NotFound"));

  // 分析/导出跟随首个可见表达式 x^2；列表计数联动。
  const std::string analysis =
      TakeAndFree(wb_function_analyze(fn.functionId.c_str(), "symmetry"));
  REQUIRE(JsonBool(analysis, "ok", true));
  REQUIRE(JsonContains(analysis, "\"expression\":\"x^2\""));
  REQUIRE(JsonString(analysis, "symmetry") == "even");

  const std::string listed = wb::invokeDomain(
      "function", "list", "{\"pageId\":\"" + fn.scene.pageId + "\"}");
  REQUIRE(JsonContains(listed, "\"expressionCount\":1"));
}
