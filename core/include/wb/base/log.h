#pragma once

// wb::base — logging facade. Contract file (Wave 0).
// Per design doc《C++ 核心引擎接口设计》§4.3.

#include <string>

namespace wb {

enum class LogLevel { Trace, Debug, Info, Warn, Error, Fatal };

class Logger {
 public:
  static Logger& instance();

  void setLevel(LogLevel level);
  LogLevel level() const;

  void log(LogLevel level, const std::string& tag, const std::string& msg);

  void trace(const std::string& tag, const std::string& msg);
  void debug(const std::string& tag, const std::string& msg);
  void info(const std::string& tag, const std::string& msg);
  void warn(const std::string& tag, const std::string& msg);
  void error(const std::string& tag, const std::string& msg);

  // Optional sink override for tests / host integration. Pass nullptr to
  // restore the default stderr sink.
  using Sink = void (*)(LogLevel level, const char* tag, const char* msg);
  void setSink(Sink sink);

 private:
  Logger() = default;
};

}  // namespace wb
