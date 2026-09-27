# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(whiteboard_desktop LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "whiteboard_desktop")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# ============================================================================
# Whiteboard: deploy the C++ core DLL (wb_core.dll) next to the runner
# ============================================================================
# The C++ core engine lives in the monorepo `core/` tree and is built
# out-of-band with the `windows-x64` CMake preset (see CMakePresets.json at
# the repo root and tools/scripts/build_cpp.ps1). This custom target copies
# the freshly built wb_core.dll next to whiteboard_desktop.exe so that the
# packaged application can load it at runtime (FFI loader in
# packages/core_dart; docs/构建打包与发布设计.md §6.2/§7.1).
#
# Source resolution order (implemented in windows/copy_wb_core.cmake):
#   1. Environment variable WB_CORE_DLL — absolute path override (CI / custom
#      build layouts). May be unset.
#   2. <repo-root>/build/windows-x64/bin/$<CONFIG>/wb_core.dll — the default
#      output of the `windows-x64` preset (Visual Studio multi-config
#      layout: <binaryDir>/bin/<Config>).
#
# Why a custom target and not ...
#   * add_custom_command(TARGET whiteboard_desktop ...): CMake requires the
#     TARGET form to be declared in the directory that created the target
#     (windows/runner/), so it cannot live here ("TARGET 'whiteboard_desktop'
#     was not created in this directory").
#   * install(CODE ...): the Flutter template sets CMAKE_INSTALL_PREFIX to
#     the generator expression $<TARGET_FILE_DIR:whiteboard_desktop>, which
#     stays unresolved inside install(CODE) — file(COPY) would then fail
#     with an invalid destination path.
#   * add_custom_target(... ALL ...): a target COMMAND supports generator
#     expressions, and ALL targets run during ALL_BUILD, which the INSTALL
#     target depends on (see CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD
#     above). The copy therefore happens during `flutter build windows`
#     before the install step, and a missing DLL only produces a warning
#     instead of failing the build.
add_custom_target(wb_core_dll_deploy ALL
  COMMAND "${CMAKE_COMMAND}"
          "-DWB_CORE_DLL=$ENV{WB_CORE_DLL}"
          "-DWB_CORE_DLL_DEFAULT=${CMAKE_CURRENT_SOURCE_DIR}/../../../build/windows-x64/bin/$<CONFIG>/wb_core.dll"
          "-DWB_CORE_DLL_DEST=$<TARGET_FILE_DIR:${BINARY_NAME}>"
          -P "${CMAKE_CURRENT_SOURCE_DIR}/copy_wb_core.cmake"
  COMMENT "Deploying wb_core.dll next to ${BINARY_NAME}.exe (skipped when not built)"
  VERBATIM)
