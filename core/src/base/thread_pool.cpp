// base/thread_pool.cpp — worker thread pool (task package 1.1).
// Owns: core/src/base. See wb/base/thread_pool.h for the contract.

#include "wb/base/thread_pool.h"

namespace wb {

ThreadPool::ThreadPool(int numThreads) {
  if (numThreads <= 0) {
    numThreads = 1;
  }
  workers_.reserve(static_cast<std::size_t>(numThreads));
  for (int i = 0; i < numThreads; ++i) {
    workers_.emplace_back([this] {
      for (;;) {
        std::function<void()> task;
        {
          std::unique_lock<std::mutex> lock(mutex_);
          cv_.wait(lock, [this] { return stop_ || !tasks_.empty(); });
          if (stop_ && tasks_.empty()) {
            return;
          }
          task = std::move(tasks_.front());
          tasks_.pop();
        }
        task();
      }
    });
  }
}

ThreadPool::~ThreadPool() { shutdown(); }

void ThreadPool::shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stop_) {
      return;
    }
    stop_ = true;
  }
  cv_.notify_all();
  for (auto& worker : workers_) {
    if (worker.joinable()) {
      worker.join();
    }
  }
  workers_.clear();
}

}  // namespace wb
