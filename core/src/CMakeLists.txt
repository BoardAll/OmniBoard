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

# ---------------------------------------------------------------------------
# WebAssembly core (Emscripten) — wb_core.js + wb_core.wasm.
#
# Enabled by WB_BUILD_WASM (CMake `wasm` preset, see tools/scripts/
# build_wasm.ps1). The exported C ABI is derived from the contract header
# wb.h so new WB_API functions require no CMake change: every declaration is
# exported as `_wb_*`, plus `_malloc` / `_free` for the Dart bindings
# (platform/web accesses `malloc` / `free` aliases added by
# core/wasm/post_js.js).
#
# JS loader expectations (platform/web/wb_core_loader_web.dart): a global
# `WbCore` factory (MODULARIZE=1 + EXPORT_NAME=WbCore) exposing
# ccall / cwrap / UTF8ToString / HEAPU8.
# ---------------------------------------------------------------------------
if(WB_BUILD_WASM)
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/../include/wb/wb.h" WB_WASM_API_LINES
       REGEX "^WB_API ")
  set(WB_WASM_EXPORTS "_malloc" "_free")
  foreach(_line IN LISTS WB_WASM_API_LINES)
    if(_line MATCHES "(wb_[A-Za-z0-9_]+)[ \t]*\\(")
      list(APPEND WB_WASM_EXPORTS "_${CMAKE_MATCH_1}")
    endif()
  endforeach()
  list(JOIN WB_WASM_EXPORTS "," WB_WASM_EXPORTS_CSV)
  list(LENGTH WB_WASM_EXPORTS _wb_wasm_export_count)
  message(STATUS "wb_core_wasm: ${_wb_wasm_export_count} exported functions derived from wb.h")

  # Exceptions: Emscripten disables catching by default; the engine's parse
  # guards (domain_registry / mindmap / flowchart) rely on try/catch recovery.
  target_compile_options(wb_core PRIVATE -fexceptions)

  add_executable(wb_core_wasm
    "${CMAKE_CURRENT_SOURCE_DIR}/../wasm/wb_core_wasm_entry.cpp")
  # Whole-archive: domain handlers self-register via static WB_REGISTER_DOMAIN
  # registrars; wasm-ld only extracts objects with referenced symbols from a
  # static library, so without this every domain would be dropped (surfacing
  # as "unknown domain: board" at runtime).
  target_link_libraries(wb_core_wasm PRIVATE
    "-Wl,--whole-archive"
    "$<TARGET_FILE:wb_core>"
    "-Wl,--no-whole-archive")
  target_compile_options(wb_core_wasm PRIVATE -fexceptions)
  target_link_options(wb_core_wasm PRIVATE
    "--no-entry"
    "-fexceptions"
    "-sMODULARIZE=1"
    "-sEXPORT_NAME=WbCore"
    "-sALLOW_MEMORY_GROWTH=1"
    "-sEXPORTED_FUNCTIONS=${WB_WASM_EXPORTS_CSV}"
    "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,UTF8ToString,HEAPU8"
    "-sENVIRONMENT=web,node"
    "--post-js=${CMAKE_CURRENT_SOURCE_DIR}/../wasm/post_js.js")

  # wb_core.js (+ wb_core.wasm) lands in build/wasm/bin (RUNTIME_OUTPUT_DIRECTORY).
  set_target_properties(wb_core_wasm PROPERTIES
    SUFFIX ".js"
    OUTPUT_NAME "wb_core")
endif()
