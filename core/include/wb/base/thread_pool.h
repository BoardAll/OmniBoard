#pragma once

// wb::base — worker thread pool. Contract file (Wave 0).
// Per design doc《C++ 核心引擎接口设计》§15.1.

#include <condition_variable>
#include <functional>
#include <future>
#include <mutex>
#include <queue>
#include <thread>
#include <type_traits>
#include <vector>

namespace wb {

class ThreadPool {
 public:
  explicit ThreadPool(int numThreads);
  ~ThreadPool();

  ThreadPool(const ThreadPool&) = delete;
  ThreadPool& operator=(const ThreadPool&) = delete;

  template <typename F, typename... Args>
  auto submit(F&& f, Args&&... args) -> std::future<std::invoke_result_t<F, Args...>> {
    using Return = std::invoke_result_t<F, Args...>;
    auto task = std::make_shared<std::packaged_task<Return()>>(
        std::bind(std::forward<F>(f), std::forward<Args>(args)...));
    std::future<Return> future = task->get_future();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stop_) {
        throw std::runtime_error("ThreadPool is stopped");
      }
      tasks_.emplace([task]() { (*task)(); });
    }
    cv_.notify_one();
    return future;
  }

  void shutdown();

 private:
  std::vector<std::thread> workers_;
  std::queue<std::function<void()>> tasks_;
  std::mutex mutex_;
  std::condition_variable cv_;
  bool stop_ = false;
};

}  // namespace wb
