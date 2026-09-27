// platform/platform.cpp — host platform abstraction (task package 1.1).
// Owns: core/src/platform. See wb/platform/platform.h for the contract.

#include "wb/platform/platform.h"

#include <filesystem>
#include <thread>

#if defined(_WIN32)
#include <cstdlib>
#include <windows.h>
#else
#include <chrono>
#include <cstdlib>
#include <limits.h>
#include <unistd.h>
#endif

namespace wb {

std::int64_t timeMillis() { return timeMicros() / 1000; }

std::int64_t timeMicros() {
#if defined(_WIN32)
  FILETIME fileTime;
  GetSystemTimeAsFileTime(&fileTime);
  ULARGE_INTEGER value;
  value.LowPart = fileTime.dwLowDateTime;
  value.HighPart = fileTime.dwHighDateTime;
  // 100ns intervals since 1601-01-01 -> microseconds since Unix epoch.
  return static_cast<std::int64_t>(value.QuadPart / 10 - 11644473600000000LL);
#else
  const auto now = std::chrono::system_clock::now().time_since_epoch();
  return std::chrono::duration_cast<std::chrono::microseconds>(now).count();
#endif
}

int threadCount() {
  const unsigned int count = std::thread::hardware_concurrency();
  return count > 0 ? static_cast<int>(count) : 1;
}

#if defined(_WIN32)

namespace {

std::string EnvOrEmpty(const char* name) {
  char buffer[MAX_PATH];
  const DWORD length = GetEnvironmentVariableA(name, buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::string();
  }
  return std::string(buffer, length);
}

std::string JoinPath(const std::string& base, const char* leaf) {
  if (base.empty()) {
    return std::string();
  }
  return (std::filesystem::path(base) / leaf).string();
}

}  // namespace

std::string configDir() { return JoinPath(EnvOrEmpty("APPDATA"), "whiteboard"); }

std::string dataDir() { return JoinPath(EnvOrEmpty("LOCALAPPDATA"), "whiteboard"); }

std::string executablePath() {
  char buffer[MAX_PATH];
  const DWORD length = GetModuleFileNameA(nullptr, buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::string();
  }
  return std::string(buffer, length);
}

#else

namespace {

std::string EnvOrEmpty(const char* name) {
  const char* value = std::getenv(name);
  return value != nullptr ? std::string(value) : std::string();
}

std::string HomeDir() { return EnvOrEmpty("HOME"); }

std::string JoinPath(const std::string& base, const char* leaf) {
  if (base.empty()) {
    return std::string();
  }
  return (std::filesystem::path(base) / leaf).string();
}

}  // namespace

std::string configDir() {
  std::string base = EnvOrEmpty("XDG_CONFIG_HOME");
  if (base.empty()) {
    base = JoinPath(HomeDir(), ".config");
  }
  return JoinPath(base, "whiteboard");
}

std::string dataDir() {
  std::string base = EnvOrEmpty("XDG_DATA_HOME");
  if (base.empty()) {
    base = JoinPath(HomeDir(), ".local/share");
  }
  return JoinPath(base, "whiteboard");
}

std::string executablePath() {
#if defined(__linux__)
  char buffer[PATH_MAX];
  const ssize_t length = readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
  if (length <= 0) {
    return std::string();
  }
  buffer[length] = '\0';
  return std::string(buffer);
#else
  return std::string();
#endif
}

#endif  // _WIN32

bool ensureDir(const std::string& path) {
  if (path.empty()) {
    return false;
  }
  std::error_code ec;
  if (std::filesystem::exists(path, ec)) {
    return std::filesystem::is_directory(path, ec);
  }
  return std::filesystem::create_directories(path, ec) && !ec;
}

bool isWindows() {
#if defined(_WIN32)
  return true;
#else
  return false;
#endif
}

bool isMacOS() {
#if defined(__APPLE__)
  return true;
#else
  return false;
#endif
}

bool isLinux() {
#if defined(__linux__)
  return true;
#else
  return false;
#endif
}

}  // namespace wb
