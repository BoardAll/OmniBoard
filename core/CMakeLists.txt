cmake_minimum_required(VERSION 3.20)

# core/ — whiteboard C++ core engine (contract, Wave 0).
# Build standalone:  cmake -S core -B build && cmake --build build
# Build as part of monorepo: see top-level CMakeLists.txt.

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(wb_core VERSION 1.0.0 LANGUAGES CXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(WB_BUILD_SHARED "Build shared library" ON)
option(WB_BUILD_STATIC "Build static library" OFF)
option(WB_BUILD_TESTS "Build tests" ON)
option(WB_BUILD_BENCHMARKS "Build benchmarks" OFF)
# 3D (bgfx) and PDF (PDFium) third-party integration are heavy; the modules
# compile with stub backends until these are enabled by their integration
# task packages.
option(WB_BUILD_3D "Build 3D renderer (requires bgfx)" OFF)
option(WB_BUILD_PDF "Build PDF support (requires PDFium)" OFF)
option(WB_BUILD_WASM "Build for WebAssembly" OFF)

# All compiled artifacts (DLL + test exe) land in one directory so tests can
# locate wb_core.dll on Windows without PATH tweaks.
if(NOT DEFINED CMAKE_RUNTIME_OUTPUT_DIRECTORY)
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
endif()

add_subdirectory(third_party)
add_subdirectory(src)

if(WB_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()

if(WB_BUILD_BENCHMARKS)
  add_subdirectory(benchmarks)
endif()
