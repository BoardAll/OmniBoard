// benchmarks/bench_page_switch.cpp — 页面切换 / 侧栏 / 复制基准（Wave 4.1）。
//
// 对齐《测试方案设计》§10.1/§10.2 可在纯 CPU 环境测量的用例：
//   1. 页面切换数据加载（page.list 定位目标页 + element.list 装载 100
//      元素重页 = 前端切页时的引擎侧数据链路）。
//   2. 侧栏刷新（102 页 page.list 全量导出，含 elementCount 汇总）。
//   3. 页面复制（100 元素深拷贝、元素 id 重映射）+ 删除回收，保证进程
//      内存储有界。
//
// 场景固定：1 块白板 = 默认页 + 100 张轻量页 + 1 张 100 元素重页；
// 无随机、不依赖系统时间。BENCHMARK 采样数由 Catch2 CLI 统一控制
// （--benchmark-samples N / --benchmark-warmup-time MS）。

#include <catch2/benchmark/catch_benchmark.hpp>
#include <catch2/catch_test_macros.hpp>

#include <string>

#include "support/bench_util.h"

namespace {

constexpr int kLightPages = 100;    // 侧栏常规页数量
constexpr int kHeavyElements = 100;  // 重页元素数量

}  // namespace

TEST_CASE("页面切换与复制基准", "[bench][page]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);
  REQUIRE_FALSE(scene.boardId.empty());

  // 100 张轻量页（侧栏规模）。
  for (int i = 0; i < kLightPages; ++i) {
    wb_free(wb_page_create(scene.boardId.c_str(), "{}"));
  }

  // 1 张 100 元素重页（切换目标）。
  const std::string heavyPage = JsonString(
      TakeAndFree(wb_page_create(scene.boardId.c_str(), "{}")), "pageId");
  REQUIRE_FALSE(heavyPage.empty());
  for (int i = 0; i < kHeavyElements; ++i) {
    const float x = static_cast<float>((i % 10) * 30);
    const float y = static_cast<float>((i / 10) * 24);
    wb_free(
        wb_element_create(heavyPage.c_str(), RectElement(x, y, 24, 16).c_str()));
  }
  REQUIRE(JsonNumber(TakeAndFree(wb_element_list(heavyPage.c_str())), "count") ==
          static_cast<double>(kHeavyElements));
  REQUIRE(JsonNumber(TakeAndFree(wb_page_list(scene.boardId.c_str())), "count") ==
          static_cast<double>(kLightPages + 2));

  BENCHMARK("页面切换（page.list 定位目标页 + element.list 装载 100 元素）") {
    const std::string pages = TakeAndFree(wb_page_list(scene.boardId.c_str()));
    const std::size_t located = pages.find(heavyPage);
    const std::string elements =
        TakeAndFree(wb_element_list(heavyPage.c_str()));
    return std::to_string(located) + ":" + std::to_string(elements.size());
  };

  BENCHMARK("侧栏刷新（page.list 导出 102 页摘要）") {
    return TakeAndFree(wb_page_list(scene.boardId.c_str()));
  };

  BENCHMARK("页面复制（100 元素深拷贝 id 重映射）+ 删除回收") {
    const std::string copy = TakeAndFree(wb_page_duplicate(heavyPage.c_str()));
    const std::string copyId = JsonString(copy, "pageId");
    wb_free(wb_page_delete(copyId.c_str()));
    return copy;
  };
}
