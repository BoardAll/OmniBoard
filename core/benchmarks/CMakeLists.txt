# benchmarks/CMakeLists.txt — performance benchmarks (contract, Wave 0).
# Built only when WB_BUILD_BENCHMARKS=ON (Wave 4.1 fills this directory).

file(GLOB_RECURSE WB_BENCH_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

if(NOT WB_BENCH_SOURCES)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/bench_placeholder.cpp"
    "#include <catch2/catch_test_macros.hpp>\n\nTEST_CASE(\"bench placeholder\", \"[bench]\") {\n  SUCCEED();\n}\n")
  list(APPEND WB_BENCH_SOURCES "${CMAKE_CURRENT_BINARY_DIR}/bench_placeholder.cpp")
endif()

add_executable(wb_benchmarks ${WB_BENCH_SOURCES})
target_link_libraries(wb_benchmarks PRIVATE wb::core Catch2::Catch2WithMain)

if(MSVC)
  target_compile_options(wb_benchmarks PRIVATE /utf-8)
endif()
