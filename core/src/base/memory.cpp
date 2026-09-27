// base/memory.cpp — linear memory pool (task package 1.1).
// Owns: core/src/base. See wb/base/memory.h for the contract.

#include "wb/base/memory.h"

#include <cstddef>

namespace wb {

MemoryPool::MemoryPool(std::size_t capacity)
    : buffer_(std::make_unique<std::byte[]>(capacity == 0 ? 1 : capacity)),
      capacity_(capacity),
      offset_(0) {}

void* MemoryPool::allocate(std::size_t size, std::size_t alignment) {
  if (size == 0) {
    return nullptr;
  }
  if (alignment < 1) {
    alignment = 1;
  }
  const std::size_t aligned = (offset_ + alignment - 1) & ~(alignment - 1);
  if (aligned > capacity_ || size > capacity_ - aligned) {
    return nullptr;
  }
  void* ptr = buffer_.get() + aligned;
  offset_ = aligned + size;
  return ptr;
}

// Linear (LIFO) reclaim: releasing a pointer rewinds the bump offset to that
// pointer's position. Returns false for pointers this pool never handed out.
bool MemoryPool::deallocate(void* ptr) {
  if (ptr == nullptr) {
    return false;
  }
  auto* base = buffer_.get();
  auto* p = static_cast<std::byte*>(ptr);
  if (p < base || p > base + offset_) {
    return false;
  }
  offset_ = static_cast<std::size_t>(p - base);
  return true;
}

void MemoryPool::reset() { offset_ = 0; }

std::size_t MemoryPool::used() const { return offset_; }

std::size_t MemoryPool::capacity() const { return capacity_; }

}  // namespace wb
