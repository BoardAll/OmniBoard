#pragma once

// wb::base — generic object pool. Contract file (Wave 0).
// Per design doc《C++ 核心引擎接口设计》§16.1.

#include <memory>
#include <mutex>
#include <vector>

namespace wb {

template <typename T>
class ObjectPool {
 public:
  // Returns a recycled or newly created object.
  T* acquire() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!free_.empty()) {
      T* obj = free_.back();
      free_.pop_back();
      return obj;
    }
    owned_.push_back(std::make_unique<T>());
    return owned_.back().get();
  }

  // Returns the object to the pool.
  void release(T* obj) {
    if (obj == nullptr) return;
    std::lock_guard<std::mutex> lock(mutex_);
    free_.push_back(obj);
  }

  // Pre-creates `count` objects.
  void reserve(std::size_t count) {
    std::lock_guard<std::mutex> lock(mutex_);
    while (owned_.size() < count) {
      owned_.push_back(std::make_unique<T>());
      free_.push_back(owned_.back().get());
    }
  }

  std::size_t size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return owned_.size();
  }

 private:
  std::vector<std::unique_ptr<T>> owned_;
  std::vector<T*> free_;
  mutable std::mutex mutex_;
};

}  // namespace wb
