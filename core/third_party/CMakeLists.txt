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

# --- sioxx (Socket.IO client for the realtime transport, desktop only) ------
# The desktop C++ SocketIOTransport wraps sioxx v0.3.0
# (https://github.com/jfayot/sioxx). WASM builds must not pull Boost/OpenSSL,
# so everything below is guarded by WB_BUILD_WASM.
#
# Integration notes (keep in sync with docs/modules/17-build-release.md):
#  * sioxx itself calls find_package(OpenSSL/Threads/nlohmann_json) and links
#    OpenSSL/Threads PRIVATE; all three targets are pre-created here so its
#    find_package calls resolve to cheap cache hits.
#  * nlohmann_json: SIOXX_USE_SYSTEM_JSON=ON reuses the target fetched above;
#    the Findnlohmann_json.cmake shim in cmake/ satisfies the version lookup
#    inside sioxx.
#  * Boost: sioxx's built-in fetch of boost-1.90.0-cmake.tar.xz (GitHub
#    releases) measured 75 KB/s (~22 min) on the dev machine, so we fetch the
#    official boost_1_90_0.tar.gz from archives.boost.io instead and point
#    sioxx's own fetch at the extracted tree via FETCHCONTENT_SOURCE_DIR_BOOST
#    (keeps SIOXX_USE_SYSTEM_BOOST=OFF: no Boost installation required).
#  * OpenSSL: none is installed on the dev machine; fetch the 3.5.9 source
#    tarball and build a private static prefix with cmake/build_openssl.ps1
#    (needs Perl + MSVC; one-time per build dir, skipped once the prefix
#    exists). OPENSSL_USE_STATIC_LIBS=TRUE is required on Windows so that
#    FindOpenSSL adds the ws2_32/crypt32 interface dependencies of the
#    static libraries.
if(NOT WB_BUILD_WASM)
  find_package(sioxx QUIET)

  if(NOT TARGET sioxx::sioxx)
    # sioxx requires CMake >= 3.28; fail early and clearly if we must build it.
    if(CMAKE_VERSION VERSION_LESS 3.28)
      message(FATAL_ERROR
        "sioxx requires CMake >= 3.28 (found ${CMAKE_VERSION}). "
        "Upgrade CMake or provide a system sioxx package.")
    endif()

    # Boost tarball for sioxx (fetched once, then reused by sioxx's helper).
    FetchContent_Declare(wb_boost
      URL https://archives.boost.io/release/1.90.0/source/boost_1_90_0.tar.gz
          https://master.dl.sourceforge.net/project/boost/boost/1.90.0/boost_1_90_0.tar.gz?viasf=1
      URL_HASH SHA256=5e93d582aff26868d581a52ae78c7d8edf3f3064742c6e77901a1f18a437eea9
      SOURCE_SUBDIR __wb_no_cmake_subdir__
      DOWNLOAD_EXTRACT_TIMESTAMP TRUE
      TIMEOUT 1800)
    FetchContent_MakeAvailable(wb_boost)
    set(FETCHCONTENT_SOURCE_DIR_BOOST "${wb_boost_SOURCE_DIR}"
        CACHE PATH "redirect sioxx's Boost fetch to the wb_boost tree" FORCE)

    # OpenSSL: prefer a system install, otherwise build a private static prefix.
    set(OPENSSL_USE_STATIC_LIBS TRUE)
    find_package(OpenSSL QUIET)
    if(NOT OpenSSL_FOUND)
      set(_wb_openssl_prefix "${CMAKE_BINARY_DIR}/third_party/openssl-install")
      if(NOT EXISTS "${_wb_openssl_prefix}/include/openssl/ssl.h" OR
         NOT EXISTS "${_wb_openssl_prefix}/lib/libssl.lib")
        FetchContent_Declare(wb_openssl
          URL https://gh-proxy.com/https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
              https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
          URL_HASH SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
          SOURCE_SUBDIR __wb_no_cmake_subdir__
          DOWNLOAD_EXTRACT_TIMESTAMP TRUE
          TIMEOUT 1800)
        FetchContent_MakeAvailable(wb_openssl)
        execute_process(
          COMMAND powershell -NoProfile -ExecutionPolicy Bypass
                  -File "${CMAKE_CURRENT_SOURCE_DIR}/cmake/build_openssl.ps1"
                  -SourceDir "${wb_openssl_SOURCE_DIR}"
                  -InstallDir "${_wb_openssl_prefix}"
                  -LogDir "${CMAKE_CURRENT_BINARY_DIR}/openssl-build-logs"
          RESULT_VARIABLE _wb_openssl_result)
        if(NOT _wb_openssl_result EQUAL 0)
          message(FATAL_ERROR
            "OpenSSL build failed (rc=${_wb_openssl_result}); "
            "see logs in ${CMAKE_CURRENT_BINARY_DIR}/openssl-build-logs")
        endif()
      endif()
      set(OPENSSL_ROOT_DIR "${_wb_openssl_prefix}" CACHE PATH "private OpenSSL prefix" FORCE)
      unset(OPENSSL_INCLUDE_DIR CACHE)
      unset(OPENSSL_SSL_LIBRARY CACHE)
      unset(OPENSSL_CRYPTO_LIBRARY CACHE)
      find_package(OpenSSL REQUIRED)
    endif()

    # sioxx links Threads::Threads; create it before its CMakeLists runs.
    find_package(Threads REQUIRED)

    # sioxx source (v0.3.0). The cmake/ shim dir must be on MODULE_PATH for
    # the nlohmann_json version lookup performed inside sioxx.
    list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
    set(SIOXX_USE_SYSTEM_JSON ON CACHE BOOL "" FORCE)
    FetchContent_Declare(sioxx
      URL https://codeload.github.com/jfayot/sioxx/tar.gz/refs/tags/v0.3.0
          https://github.com/jfayot/sioxx/archive/refs/tags/v0.3.0.tar.gz
      URL_HASH SHA256=f41e084fd16c4d59ea8669173c5276f99d2d20be9a78c097e5568fac15352fdf
      DOWNLOAD_EXTRACT_TIMESTAMP TRUE
      TIMEOUT 600)
    FetchContent_MakeAvailable(sioxx)
  endif()

  # Stable alias for the rest of the repo (tests link wb::sioxx).
  if(TARGET sioxx AND NOT TARGET wb::sioxx)
    add_library(wb::sioxx ALIAS sioxx)
  elseif(TARGET sioxx::sioxx AND NOT TARGET wb::sioxx)
    add_library(wb_sioxx_forward INTERFACE)
    target_link_libraries(wb_sioxx_forward INTERFACE sioxx::sioxx)
    add_library(wb::sioxx ALIAS wb_sioxx_forward)
  endif()
endif()

# Convenience umbrella every core target links against.
add_library(wb_third_party INTERFACE)
target_link_libraries(wb_third_party INTERFACE
  glm::glm
  nlohmann_json::nlohmann_json
  fmt::fmt
  spdlog::spdlog)

# sioxx is desktop-only (the fetch above is guarded by WB_BUILD_WASM).
if(TARGET wb::sioxx)
  target_link_libraries(wb_third_party INTERFACE wb::sioxx)
endif()
