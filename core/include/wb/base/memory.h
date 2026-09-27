#pragma once

// wb::base — linear memory pool. Contract file (Wave 0).
// Per design doc《C++ 核心引擎接口设计》§16.2.

#include <cstddef>
#include <memory>
#include <vector>

namespace wb {

class MemoryPool {
 public:
  explicit MemoryPool(std::size_t capacity = 1024 * 1024);

  // Returns nullptr when the pool cannot satisfy the request.
  void* allocate(std::size_t size, std::size_t alignment = alignof(std::max_align_t));

  // Returns true when ptr was the last allocation and was reclaimed.
  bool deallocate(void* ptr);

  void reset();

  std::size_t used() const;
  std::size_t capacity() const;

 private:
  std::unique_ptr<std::byte[]> buffer_;
  std::size_t capacity_ = 0;
  std::size_t offset_ = 0;
};

}  // namespace wb
