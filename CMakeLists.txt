cmake_minimum_required(VERSION 3.25)

# whiteboard monorepo — top-level CMake entry (contract, Wave 0).
# Configure with presets:  cmake --preset windows-x64

project(whiteboard VERSION 1.0.0 LANGUAGES CXX)

# CTest entry point must live in the top-level directory so
# `ctest --test-dir build/<preset>` discovers the tests registered in core/.
enable_testing()

# The C++ core engine builds standalone from core/ as well; when embedded in
# the monorepo we simply delegate.
add_subdirectory(core)
