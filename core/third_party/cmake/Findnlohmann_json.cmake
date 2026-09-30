# Findnlohmann_json.cmake — module-mode shim for the nlohmann_json target
# provisioned by FetchContent in this directory.
#
# Why this file exists:
#   sioxx (fetched by CMakeLists.txt in this directory) calls
#   `find_package(nlohmann_json <version> REQUIRED)`. CMake tries module mode
#   first, so without a Find module that lookup can only succeed against a
#   system installation. On clean machines that fails even though
#   `nlohmann_json::nlohmann_json` already exists (created by FetchContent).
#
# Behavior:
#   - Target present  -> report found (version advertised: keep in sync with
#     the FetchContent tag in ../CMakeLists.txt).
#   - Target absent   -> leave `nlohmann_json_FOUND` unset; CMake then falls
#     back to config mode / a real system installation as usual.

if(TARGET nlohmann_json::nlohmann_json)
  set(nlohmann_json_FOUND TRUE)
  if(NOT nlohmann_json_VERSION)
    set(nlohmann_json_VERSION "3.11.3")
  endif()
endif()
