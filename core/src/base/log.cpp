// base/log.cpp — Logger implementation (task package 1.1).
// Owns: core/src/base. See wb/base/log.h for the contract.

#include "wb/base/log.h"

#include <atomic>
#include <cstdio>
#include <mutex>

namespace wb {
namespace {

const char* LevelName(LogLevel level) {
  switch (level) {
    case LogLevel::Trace:
      return "TRACE";
    case LogLevel::Debug:
      return "DEBUG";
    case LogLevel::Info:
      return "INFO";
    case LogLevel::Warn:
      return "WARN";
    case LogLevel::Error:
      return "ERROR";
    case LogLevel::Fatal:
      return "FATAL";
  }
  return "?";
}

void DefaultSink(LogLevel level, const char* tag, const char* msg) {
  std::fprintf(stderr, "[%s] [%s] %s\n", LevelName(level), tag != nullptr ? tag : "",
               msg != nullptr ? msg : "");
}

std::atomic<int>& LevelValue() {
  static std::atomic<int> value{static_cast<int>(LogLevel::Info)};
  return value;
}

Logger::Sink& SinkValue() {
  static Logger::Sink sink = nullptr;
  return sink;
}

std::mutex& LogMutex() {
  static std::mutex mutex;
  return mutex;
}

}  // namespace

Logger& Logger::instance() {
  static Logger logger;
  return logger;
}

void Logger::setLevel(LogLevel level) { LevelValue().store(static_cast<int>(level)); }

LogLevel Logger::level() const { return static_cast<LogLevel>(LevelValue().load()); }

void Logger::setSink(Sink sink) {
  std::lock_guard<std::mutex> lock(LogMutex());
  SinkValue() = sink;
}

void Logger::log(LogLevel level, const std::string& tag, const std::string& msg) {
  if (static_cast<int>(level) < LevelValue().load()) {
    return;
  }
  std::lock_guard<std::mutex> lock(LogMutex());
  Sink sink = SinkValue();
  if (sink == nullptr) {
    sink = &DefaultSink;
  }
  sink(level, tag.c_str(), msg.c_str());
}

void Logger::trace(const std::string& tag, const std::string& msg) {
  log(LogLevel::Trace, tag, msg);
}

void Logger::debug(const std::string& tag, const std::string& msg) {
  log(LogLevel::Debug, tag, msg);
}

void Logger::info(const std::string& tag, const std::string& msg) {
  log(LogLevel::Info, tag, msg);
}

void Logger::warn(const std::string& tag, const std::string& msg) {
  log(LogLevel::Warn, tag, msg);
}

void Logger::error(const std::string& tag, const std::string& msg) {
  log(LogLevel::Error, tag, msg);
}

}  // namespace wb
