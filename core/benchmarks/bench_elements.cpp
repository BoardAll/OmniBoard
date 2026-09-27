// benchmarks/bench_elements.cpp — 元素子系统吞吐基准（Wave 4.1）。
//
// 对齐《测试方案设计》§10.1/§10.2 可在纯 CPU 环境测量的用例：
//   1. 1000 个元素创建（逐条 element.create 的真实交互路径，含新建页
//      与回收，保证进程内存储有界）。
//   2. 1000 个元素遍历（element.list 全量导出 = 渲染/序列化前的数据
//      抓取路径）。
//   3. 1000 个元素命中测试（geometry.hitTest 未命中全扫描 = 最坏路径）。
//
// 说明：基准不依赖真随机与系统时间；每个 BENCHMARK 的采样数由 Catch2
// 统一控制（默认 100 samples / warmup ≈ 100ms），可用命令行
// --benchmark-samples N / --benchmark-warmup-time MS 调整时长。

#include <catch2/benchmark/catch_benchmark.hpp>
#include <catch2/catch_test_macros.hpp>

#include <string>

#include "support/bench_util.h"

namespace {

constexpr int kElementCount = 1000;

/// 在 pageId 上创建 count 个错开的矩形元素（结果直接释放，不计拷贝）。
void CreateElements(const std::string& pageId, int count) {
  for (int i = 0; i < count; ++i) {
    const float x = static_cast<float>((i % 50) * 24);
    const float y = static_cast<float>((i / 50) * 18);
    wb_free(wb_element_create(pageId.c_str(), RectElement(x, y, 20, 12).c_str()));
  }
}

}  // namespace

TEST_CASE("元素吞吐基准（1000 元素）", "[bench][elements]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);
  REQUIRE_FALSE(scene.boardId.empty());

  // 固定场景：一个含 1000 个元素的页面（供遍历/命中测试复用）。
  const std::string page = JsonString(
      TakeAndFree(wb_page_create(scene.boardId.c_str(), "{}")), "pageId");
  REQUIRE_FALSE(page.empty());
  CreateElements(page, kElementCount);
  REQUIRE(JsonNumber(TakeAndFree(wb_element_list(page.c_str())), "count") ==
          static_cast<double>(kElementCount));

  BENCHMARK("1000 元素创建（新建页→逐条 create→回收页）") {
    const std::string tempPage = JsonString(
        TakeAndFree(wb_page_create(scene.boardId.c_str(), "{}")), "pageId");
    CreateElements(tempPage, kElementCount);
    wb_free(wb_page_delete(tempPage.c_str()));
    return tempPage;
  };

  BENCHMARK("1000 元素遍历（element.list 全量导出）") {
    return TakeAndFree(wb_element_list(page.c_str()));
  };

  BENCHMARK("1000 元素命中测试（geometry.hitTest 未命中全扫描）") {
    return wb::invokeDomain("geometry", "hitTest",
                            "{\"pageId\":\"" + page +
                                "\",\"x\":99999,\"y\":99999}");
  };
}
