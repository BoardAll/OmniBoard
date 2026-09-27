# ============================================================================
# copy_wb_core.cmake - deploy the whiteboard C++ core DLL next to the runner.
# ============================================================================
# Executed as a CMake *script* (cmake -P) by the `wb_core_dll_deploy` custom
# target at the bottom of the sibling windows/CMakeLists.txt, so that every
# `flutter build windows` run (which builds ALL_BUILD, and INSTALL depends on
# it) also deploys wb_core.dll next to whiteboard_desktop.exe.
#
# Why not the alternatives:
#   * add_custom_command(TARGET whiteboard_desktop ...) must be declared in
#     the directory that created the target (windows/runner/); CMake rejects
#     it anywhere else ("TARGET 'whiteboard_desktop' was not created in this
#     directory").
#   * install(CODE ...) cannot use the runner output path: the Flutter
#     template sets CMAKE_INSTALL_PREFIX to the genex
#     $<TARGET_FILE_DIR:whiteboard_desktop>, which stays unresolved inside
#     install(CODE) (file(COPY) then fails with "Invalid argument").
#   * A custom target COMMAND supports generator expressions: the caller
#     expands $<CONFIG> and $<TARGET_FILE_DIR:...> at build time and passes
#     concrete values here via -D arguments.
#
# Inputs (via -D arguments from the caller, see windows/CMakeLists.txt):
#   WB_CORE_DLL          Optional absolute source path override (CI / custom
#                        build layouts). May be empty or unset.
#   WB_CORE_DLL_DEFAULT  Default source path:
#                        <repo>/build/windows-x64/bin/<Config>/wb_core.dll -
#                        the output of the monorepo `windows-x64` CMake preset
#                        (Visual Studio multi-config layout: <binaryDir>/bin/
#                        <Config>). Build it with tools\scripts\build_cpp.ps1.
#   WB_CORE_DLL_DEST     Destination directory: the runner build output dir
#                        (next to whiteboard_desktop.exe).
#
# $ENV{WB_CORE_DLL} is also honored when no -D value is given, so the script
# can be run standalone:
#   cmake -DWB_CORE_DLL_DEST=<dir> -P copy_wb_core.cmake
#
# Safety: never fails the build and never deletes anything. A missing source
# only prints a warning - the desktop app stays buildable without the native
# core (the FFI loader in packages/core_dart then reports "library not found"
# at runtime and the app uses its coreless fallback).
# ============================================================================

set(_wb_core_dest "")
if(DEFINED WB_CORE_DLL_DEST AND NOT "${WB_CORE_DLL_DEST}" STREQUAL "")
  set(_wb_core_dest "${WB_CORE_DLL_DEST}")
endif()
if(_wb_core_dest STREQUAL "")
  message(WARNING "[wb_core] WB_CORE_DLL_DEST is empty; skipping deployment.")
  return()
endif()

set(_wb_core_source "")
if(DEFINED WB_CORE_DLL AND NOT "${WB_CORE_DLL}" STREQUAL "" AND EXISTS "${WB_CORE_DLL}")
  # 1. Explicit override via -DWB_CORE_DLL=...
  set(_wb_core_source "${WB_CORE_DLL}")
elseif(DEFINED ENV{WB_CORE_DLL} AND NOT "$ENV{WB_CORE_DLL}" STREQUAL "" AND EXISTS "$ENV{WB_CORE_DLL}")
  # 2. Override via the WB_CORE_DLL environment variable.
  set(_wb_core_source "$ENV{WB_CORE_DLL}")
elseif(DEFINED WB_CORE_DLL_DEFAULT AND NOT "${WB_CORE_DLL_DEFAULT}" STREQUAL "" AND EXISTS "${WB_CORE_DLL_DEFAULT}")
  # 3. Default: output of the `windows-x64` preset for the current config.
  set(_wb_core_source "${WB_CORE_DLL_DEFAULT}")
endif()

# The destination must be a directory (the runner output dir), not a file.
get_filename_component(_wb_core_dest_name "${_wb_core_dest}" NAME)
if("${_wb_core_dest_name}" STREQUAL "wb_core.dll")
  message(WARNING
    "[wb_core] WB_CORE_DLL_DEST '${_wb_core_dest}' looks like a file path; "
    "expected the runner output directory. Skipping deployment.")
  return()
endif()

if(_wb_core_source STREQUAL "")
  message(WARNING
    "[wb_core] wb_core.dll not found; skipping deployment (the app will build without the native core).\n"
    "  Checked: WB_CORE_DLL='${WB_CORE_DLL}' WB_CORE_DLL_DEFAULT='${WB_CORE_DLL_DEFAULT}'\n"
    "  Build the core first: tools\\scripts\\build_cpp.ps1  (or set the WB_CORE_DLL environment variable).")
  return()
endif()

file(COPY "${_wb_core_source}" DESTINATION "${_wb_core_dest}")
message(STATUS "[wb_core] Deployed: ${_wb_core_source} -> ${_wb_core_dest}\\wb_core.dll")
