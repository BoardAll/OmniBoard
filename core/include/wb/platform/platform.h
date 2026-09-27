#pragma once

// wb::platform — host platform abstraction (task package 1.1).
// Owns: core/src/platform + this header.
// Per《C++ 核心引擎接口设计》§17.

#include <cstdint>
#include <string>

namespace wb {

/// Monotonic-ish wall clock in milliseconds since the Unix epoch.
std::int64_t timeMillis();

/// Wall clock in microseconds since the Unix epoch.
std::int64_t timeMicros();

/// Logical processor count (>= 1).
int threadCount();

/// Per-user configuration directory for the whiteboard
/// (e.g. %APPDATA%/whiteboard). May not exist yet.
std::string configDir();

/// Per-user data directory (e.g. %LOCALAPPDATA%/whiteboard).
std::string dataDir();

/// Absolute path of the running executable; empty when unavailable.
std::string executablePath();

/// Creates `path` and parents when missing. Returns true on success or when
/// the directory already exists.
bool ensureDir(const std::string& path);

bool isWindows();
bool isMacOS();
bool isLinux();

}  // namespace wb
