# src/CMakeLists.txt — whiteboard core engine library (contract, Wave 0).
#
# Source files are collected with a single recursive glob, so the Wave-1 task
# packages never need to touch any CMake file: dropping a .cpp under
# src/<module>/ is enough for it to be picked up on the next build
# (CONFIGURE_DEPENDS makes the glob re-run automatically).

file(GLOB_RECURSE WB_CORE_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

# Wave 0: keep the build green before module sources exist.
if(NOT WB_CORE_SOURCES)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/wb_placeholder.cpp"
    "namespace wb {\nvoid wb_wave0_placeholder() {}\n}  // namespace wb\n")
  list(APPEND WB_CORE_SOURCES "${CMAKE_CURRENT_BINARY_DIR}/wb_placeholder.cpp")
  message(STATUS "wb_core: no sources yet, using placeholder object")
endif()

if(WB_BUILD_WASM)
  set(WB_LIB_TYPE STATIC)
elseif(WB_BUILD_SHARED)
  set(WB_LIB_TYPE SHARED)
else()
  set(WB_LIB_TYPE STATIC)
endif()

add_library(wb_core ${WB_LIB_TYPE} ${WB_CORE_SOURCES})
add_library(wb::core ALIAS wb_core)

target_include_directories(wb_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/../include")

target_compile_definitions(wb_core PRIVATE WB_CORE_EXPORTS)
if(WB_LIB_TYPE STREQUAL "STATIC")
  target_compile_definitions(wb_core PUBLIC WB_STATIC)
endif()

target_link_libraries(wb_core PRIVATE wb_third_party)

if(MSVC)
  target_compile_options(wb_core PRIVATE /utf-8 /W4 /permissive-)
  target_compile_definitions(wb_core PRIVATE
    _CRT_SECURE_NO_WARNINGS
    NOMINMAX
    WIN32_LEAN_AND_MEAN)
else()
  target_compile_options(wb_core PRIVATE -Wall -Wextra)
endif()

set_target_properties(wb_core PROPERTIES
  OUTPUT_NAME "wb_core"
  VERSION ${PROJECT_VERSION}
  # C++ unit tests link against the DLL; export all non-inline symbols so
  # internal C++ types are testable without annotating every class.
  WINDOWS_EXPORT_ALL_SYMBOLS ON)
