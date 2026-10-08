# tests/CMakeLists.txt — Catch2 test harness (contract, Wave 0).
#
# Test sources are collected recursively from tests/unit and
# tests/integration; task packages only drop .cpp files there and never
# edit this file.

# Catch.cmake is located in the Catch2 sources (published by third_party).
if(CATCH2_EXTRAS_DIR)
  list(APPEND CMAKE_MODULE_PATH "${CATCH2_EXTRAS_DIR}")
endif()
include(Catch)

file(GLOB_RECURSE WB_TEST_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/unit/*.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/integration/*.cpp")

# Wave 0: keep the test run green before module tests exist.
if(NOT WB_TEST_SOURCES)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/smoke_test.cpp"
    "#include <catch2/catch_test_macros.hpp>\n\nTEST_CASE(\"wave0 smoke\", \"[wave0]\") {\n  REQUIRE(1 + 1 == 2);\n}\n")
  list(APPEND WB_TEST_SOURCES "${CMAKE_CURRENT_BINARY_DIR}/smoke_test.cpp")
  message(STATUS "wb_tests: no test sources yet, using smoke test")
endif()

add_executable(wb_tests ${WB_TEST_SOURCES})
target_link_libraries(wb_tests PRIVATE wb::core Catch2::Catch2WithMain)

# sioxx-backed integration tests (realtime POC). The library exists on desktop
# builds only; WASM builds do not fetch it (see third_party/CMakeLists.txt).
if(TARGET wb::sioxx)
  target_link_libraries(wb_tests PRIVATE wb::sioxx)
endif()

if(MSVC)
  target_compile_options(wb_tests PRIVATE /utf-8)
endif()

# The sioxx POC is env-gated (WB_SIOXX_POC_ENDPOINT) and is registered
# explicitly below, not via generic discovery, for two reasons:
#  1. When the variable is unset the case calls SKIP(); Catch2 3.5.2 then
#     exits with code 4 ("all selected tests skipped", catch_session.cpp
#     L345-348), which CTest would report as a failure. SKIP_RETURN_CODE maps
#     exit 4 to a Skipped result instead, so local/CI runs without a realtime
#     service stay green.
#  2. Its test name contains commas, which Catch2 parses as spec separators;
#     the [poc] tag filter sidesteps that. TEST_SPEC "~[poc]" keeps the case
#     out of the discovered set while the explicit entry below adds it back.
# PRE_TEST discovery: the list is refreshed by ctest before test execution
# whenever this file, the test executable, or the list itself changes; the
# POST_BUILD default is not refreshed for incremental builds that do not
# relink wb_tests and can silently drop tests.
catch_discover_tests(wb_tests
  TEST_SPEC "~[poc]"
  DISCOVERY_MODE PRE_TEST)

if(TARGET wb::sioxx)
  add_test(NAME "socketio POC (env-gated)"
           COMMAND wb_tests "[poc]")
  set_tests_properties("socketio POC (env-gated)" PROPERTIES SKIP_RETURN_CODE 4)
endif()
