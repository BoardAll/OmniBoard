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

if(MSVC)
  target_compile_options(wb_tests PRIVATE /utf-8)
endif()

catch_discover_tests(wb_tests)
