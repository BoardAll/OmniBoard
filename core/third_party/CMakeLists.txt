# third_party/CMakeLists.txt — third-party dependencies (contract, Wave 0).
#
# All deps are fetched with FetchContent using release tarballs (CMake uses
# libcurl, so the broken global git proxy on the dev machine is bypassed).
# A pre-installed package found via find_package() is preferred.

include(FetchContent)
set(FETCHCONTENT_QUIET OFF)

# --- glm (math) -------------------------------------------------------------
find_package(glm QUIET)
if(NOT glm_FOUND AND NOT TARGET glm::glm)
  FetchContent_Declare(glm
    URL https://github.com/g-truc/glm/archive/refs/tags/1.0.1.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    TIMEOUT 600)
  set(GLM_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(glm)
endif()

# --- nlohmann_json ----------------------------------------------------------
find_package(nlohmann_json QUIET)
if(NOT nlohmann_json_FOUND AND NOT TARGET nlohmann_json::nlohmann_json)
  FetchContent_Declare(nlohmann_json
    URL https://github.com/nlohmann/json/archive/refs/tags/v3.11.3.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    TIMEOUT 600)
  set(JSON_BuildTests OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(nlohmann_json)
endif()

# --- fmt --------------------------------------------------------------------
find_package(fmt QUIET)
if(NOT fmt_FOUND AND NOT TARGET fmt::fmt)
  FetchContent_Declare(fmt
    URL https://github.com/fmtlib/fmt/archive/refs/tags/10.2.1.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    TIMEOUT 600)
  set(FMT_INSTALL OFF CACHE BOOL "" FORCE)
  set(FMT_TEST OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(fmt)
endif()

# --- spdlog -----------------------------------------------------------------
find_package(spdlog QUIET)
if(NOT spdlog_FOUND AND NOT TARGET spdlog::spdlog)
  FetchContent_Declare(spdlog
    URL https://github.com/gabime/spdlog/archive/refs/tags/v1.13.0.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    TIMEOUT 600)
  set(SPDLOG_FMT_EXTERNAL ON CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(spdlog)
endif()

# --- Catch2 (tests/benchmarks only) ----------------------------------------
if((WB_BUILD_TESTS OR WB_BUILD_BENCHMARKS) AND NOT TARGET Catch2::Catch2WithMain)
  find_package(Catch2 3 QUIET)
  if(NOT Catch2_FOUND)
    FetchContent_Declare(Catch2
      URL https://github.com/catchorg/Catch2/archive/refs/tags/v3.5.2.tar.gz
      DOWNLOAD_EXTRACT_TIMESTAMP TRUE
      TIMEOUT 600)
    FetchContent_MakeAvailable(Catch2)
  endif()
endif()

# Catch.cmake (provides catch_discover_tests) ships inside the Catch2 sources
# when Catch2 is fetched. Publish its location as a cache variable so sibling
# directories (tests/, benchmarks/) can include it — directory-scope variable
# changes in this file do not propagate to the parent scope.
if(DEFINED catch2_SOURCE_DIR)
  set(CATCH2_EXTRAS_DIR "${catch2_SOURCE_DIR}/extras" CACHE INTERNAL "Catch2 extra CMake modules")
endif()

# Convenience umbrella every core target links against.
add_library(wb_third_party INTERFACE)
target_link_libraries(wb_third_party INTERFACE
  glm::glm
  nlohmann_json::nlohmann_json
  fmt::fmt
  spdlog::spdlog)
