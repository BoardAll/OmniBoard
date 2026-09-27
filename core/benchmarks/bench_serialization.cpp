// benchmarks/bench_serialization.cpp — 文档序列化基准（Wave 4.1）。
//
// 对齐《测试方案设计》§10.1/§10.2：WBB1 二进制容器（见 wb/serialization/
// codec.h）在 1000 元素文档载荷上的吞吐。
//   1. encodeBinary：JSON 校验 + 头/尾封装 + CRC32 计算。
//   2. decodeBinary：Magic/版本/长度/CRC 校验 + JSON 校验后取回载荷。
//   3. 完整往返：encode → decode → 载荷逐字节一致。
//
// 载荷固定：1000 元素页的 element.list JSON（≈ 百 KB 级），无随机。
// 说明：这里直接调用 core 的公共 C++ API（非 FFI），符合基准"贴引擎
// 热路径"的定位；单次成本为毫秒级（nlohmann 解析 + 逐位 CRC）。

#include <catch2/benchmark/catch_benchmark.hpp>
#include <catch2/catch_test_macros.hpp>

#include <cstddef>
#include <string>

#include "support/bench_util.h"
#include "wb/serialization/codec.h"

namespace {

constexpr int kElementCount = 1000;

}  // namespace

TEST_CASE("文档序列化基准（1000 元素载荷）", "[bench][serialization]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  const std::string page = JsonString(
      TakeAndFree(wb_page_create(scene.boardId.c_str(), "{}")), "pageId");
  REQUIRE_FALSE(page.empty());
  for (int i = 0; i < kElementCount; ++i) {
    const float x = static_cast<float>((i % 50) * 24);
    const float y = static_cast<float>((i / 50) * 18);
    wb_free(wb_element_create(page.c_str(), RectElement(x, y, 20, 12).c_str()));
  }

  // 固定载荷：渲染/序列化前的数据抓取结果。
  const std::string payload = TakeAndFree(wb_element_list(page.c_str()));
  REQUIRE(JsonNumber(payload, "count") == static_cast<double>(kElementCount));

  // 冒烟：编码非空、往返逐字节一致（BENCHMARK 只测吞吐）。
  const std::string encodedSmoke = wb::encodeBinary(payload);
  REQUIRE_FALSE(encodedSmoke.empty());
  {
    const wb::Result<std::string> roundTrip = wb::decodeBinary(encodedSmoke);
    REQUIRE(roundTrip.ok());
    REQUIRE(roundTrip.value == payload);
  }
  const std::string encoded = wb::encodeBinary(payload);
  REQUIRE_FALSE(encoded.empty());

  BENCHMARK("encodeBinary（1000 元素 JSON → WBB1 容器）") {
    return wb::encodeBinary(payload);
  };

  BENCHMARK("decodeBinary（头/CRC 校验 + JSON 校验 → 载荷）") {
    const wb::Result<std::string> decoded = wb::decodeBinary(encoded);
    return decoded.ok() ? decoded.value.size() : std::size_t(0);
  };

  BENCHMARK("序列化完整往返（encode → decode → 载荷一致）") {
    const wb::Result<std::string> decoded =
        wb::decodeBinary(wb::encodeBinary(payload));
    return decoded.ok() && decoded.value == payload;
  };
}
