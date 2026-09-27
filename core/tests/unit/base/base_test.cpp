// tests/unit/base/base_test.cpp — base utilities (task package 1.1).
// Tags: [base]

#include <catch2/catch_test_macros.hpp>

#include <atomic>
#include <stdexcept>

#include "wb/base/color.h"
#include "wb/base/memory.h"
#include "wb/base/object_pool.h"
#include "wb/base/point.h"
#include "wb/base/string_utils.h"
#include "wb/base/thread_pool.h"
#include "wb/base/transform.h"

TEST_CASE("string_utils split/join/trim", "[base]") {
  const auto parts = wb::split("a,b,,c", ',');
  REQUIRE(parts.size() == 4);
  REQUIRE(parts[0] == "a");
  REQUIRE(parts[2].empty());
  REQUIRE(parts[3] == "c");

  REQUIRE(wb::join({"x", "y", "z"}, "-") == "x-y-z");
  REQUIRE(wb::join({}, "-").empty());

  REQUIRE(wb::trim("  hello \t\n") == "hello");
  REQUIRE(wb::trim("no-trim") == "no-trim");
  REQUIRE(wb::trim("   ").empty());
}

TEST_CASE("string_utils affix and case", "[base]") {
  REQUIRE(wb::startsWith("whiteboard", "white"));
  REQUIRE_FALSE(wb::startsWith("whiteboard", "board"));
  REQUIRE(wb::endsWith("whiteboard", "board"));
  REQUIRE_FALSE(wb::endsWith("whiteboard", "white"));
  REQUIRE(wb::toLower("AbC123") == "abc123");
}

TEST_CASE("Color hex round-trip", "[base]") {
  const wb::Color c = wb::Color::fromHex("#1A2B3C");
  REQUIRE(c.r == 0x1A);
  REQUIRE(c.g == 0x2B);
  REQUIRE(c.b == 0x3C);
  REQUIRE(c.a == 255);
  REQUIRE(c.toHex() == "#1A2B3CFF");

  const wb::Color ca = wb::Color::fromHex("1A2B3C80");
  REQUIRE(ca.a == 0x80);
  REQUIRE(ca.toHex() == "#1A2B3C80");

  const wb::Color bad = wb::Color::fromHex("zzz");
  REQUIRE(bad == wb::Color{0, 0, 0, 255});
}

TEST_CASE("Transform helpers", "[base]") {
  const wb::Transform t = wb::Transform::translation(10, 20);
  REQUIRE(t.m[4] == 10);
  REQUIRE(t.m[5] == 20);

  const wb::Transform r = wb::Transform::rotation(0.0f);
  REQUIRE(r.m[0] == 1.0f);
  REQUIRE(r.m[3] == 1.0f);
}

TEST_CASE("MemoryPool bump allocation", "[base]") {
  wb::MemoryPool pool(256);
  REQUIRE(pool.capacity() == 256);
  REQUIRE(pool.used() == 0);

  void* first = pool.allocate(64);
  REQUIRE(first != nullptr);
  REQUIRE(pool.used() >= 64);

  void* second = pool.allocate(64);
  REQUIRE(second != nullptr);
  REQUIRE(second != first);

  // LIFO reclaim of the last allocation.
  const std::size_t before = pool.used();
  REQUIRE(pool.deallocate(second));
  REQUIRE(pool.used() < before);

  // Oversized requests fail cleanly.
  REQUIRE(pool.allocate(1024) == nullptr);

  pool.reset();
  REQUIRE(pool.used() == 0);
  REQUIRE_FALSE(pool.deallocate(nullptr));
}

TEST_CASE("ObjectPool acquire/release", "[base]") {
  wb::ObjectPool<wb::Point> pool;
  wb::Point* a = pool.acquire();
  REQUIRE(a != nullptr);
  pool.release(a);
  wb::Point* b = pool.acquire();
  REQUIRE(b == a);  // recycled
  REQUIRE(pool.size() == 1);
  pool.reserve(4);
  REQUIRE(pool.size() == 4);
}

TEST_CASE("ThreadPool executes tasks", "[base]") {
  wb::ThreadPool pool(4);
  std::atomic<int> counter{0};
  std::vector<std::future<int>> futures;
  for (int i = 0; i < 8; ++i) {
    futures.push_back(pool.submit([&counter, i] {
      counter.fetch_add(1);
      return i * 2;
    }));
  }
  int expected = 0;
  for (int i = 0; i < 8; ++i) {
    REQUIRE(futures[static_cast<std::size_t>(i)].get() == i * 2);
    expected += 1;
  }
  REQUIRE(counter.load() == expected);

  pool.shutdown();
  REQUIRE_THROWS_AS(pool.submit([] { return 0; }), std::runtime_error);
}
