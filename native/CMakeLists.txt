cmake_minimum_required(VERSION 3.20)
project(NeutrinoCEF VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Configure the CEF directory (we look inside deps/cef)
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../deps/cef/cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_windows64_minimal")

if(NOT IS_DIRECTORY "${CEF_ROOT}")
    message(FATAL_ERROR "CEF not found at ${CEF_ROOT}. Run tools/get-deps.ps1 first.")
endif()

# Find CEF via the cmake module
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

# Use MT/MTd for static runtime linking on Windows (Standard for CEF apps to avoid missing VCRUNTIME dlls)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# Include the libcef_dll_wrapper subdirectory directly
add_subdirectory("${CEF_ROOT}/libcef_dll" libcef_dll_wrapper)

# ═══════════════════════════════════════════════════════════════════════════════
# Target 1: neutrinocef.dll — Main DLL loaded by LuaJIT
# ═══════════════════════════════════════════════════════════════════════════════

add_library(neutrinocef SHARED
    src/main.cpp
    src/neutrino_api.h
    src/neutrino_ipc.h
    src/neutrino_json.h
    src/neutrino_state.cpp
    src/neutrino_state.h
    src/app.cpp
    src/app.h
    src/client.cpp
    src/client.h
    src/window_delegate.cpp
    src/window_delegate.h
    src/scheme_handler.cpp
    src/scheme_handler.h
    src/session.cpp
    src/session.h
    src/shell.cpp
    src/shell.h
    src/resource_interceptor.cpp
    src/resource_interceptor.h
    src/timers.cpp
    src/timers.h
    src/renderer_app.cpp
    src/renderer_app.h
)

target_include_directories(neutrinocef PRIVATE "${CEF_ROOT}")
target_link_directories(neutrinocef PRIVATE "${CEF_ROOT}/Release")

target_link_libraries(neutrinocef PRIVATE libcef.lib libcef_dll_wrapper Comctl32.lib Shell32.lib Ole32.lib User32.lib)

target_compile_definitions(neutrinocef PRIVATE NOMINMAX)
target_compile_definitions(neutrinocef PRIVATE NEUTRINO_CEF_EXPORTS)

# ═══════════════════════════════════════════════════════════════════════════════
# Target 2: neutrinocef_helper.exe — CEF Subprocess (renderer/GPU/utility)
# ═══════════════════════════════════════════════════════════════════════════════

# Builds only the renderer-side sources: the helper must stay free of anything
# that touches the window registry or the Lua callback table.
add_executable(neutrinocef_helper WIN32
    src/helper_main.cpp
    src/neutrino_ipc.h
    src/renderer_app.cpp
    src/renderer_app.h
)

target_include_directories(neutrinocef_helper PRIVATE "${CEF_ROOT}")
target_link_directories(neutrinocef_helper PRIVATE "${CEF_ROOT}/Release")

target_link_libraries(neutrinocef_helper PRIVATE libcef.lib libcef_dll_wrapper)

target_compile_definitions(neutrinocef_helper PRIVATE NOMINMAX)

# Use MT/MTd for the helper too
set_target_properties(neutrinocef_helper PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
)

# ═══════════════════════════════════════════════════════════════════════════════
# Target 3: neutrino_host.exe — the executable a packaged application ships as
# ═══════════════════════════════════════════════════════════════════════════════

# Development runs luajit.exe against a script; a shipped tool is one named
# executable that a user double clicks. This host is that executable: it points
# Lua at the folders beside itself and runs app/main.lua.
#
# WIN32 (GUI subsystem) so launching it does not flash a console window.

set(LUAJIT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../deps/luajit")

add_executable(neutrino_host WIN32 src/host_main.cpp)

target_include_directories(neutrino_host PRIVATE "${LUAJIT_DIR}/include/luajit-2.1")
target_link_directories(neutrino_host PRIVATE "${LUAJIT_DIR}/lib")
target_link_libraries(neutrino_host PRIVATE lua51.lib Shell32.lib User32.lib)

# Dynamic CRT here, unlike the CEF targets: this one links LuaJIT's import
# library, and lua51.dll was built against the shared runtime.
set_target_properties(neutrino_host PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL"
)

# ═══════════════════════════════════════════════════════════════════════════════
# Post-build: Copy artifacts to deps/cef/ for the build script to pick up
# ═══════════════════════════════════════════════════════════════════════════════

add_custom_command(TARGET neutrinocef POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    $<TARGET_FILE:neutrinocef>
    "${CMAKE_CURRENT_SOURCE_DIR}/../deps/cef/neutrinocef.dll"
    COMMENT "Copying neutrinocef.dll to deps/cef/"
)

add_custom_command(TARGET neutrinocef_helper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    $<TARGET_FILE:neutrinocef_helper>
    "${CMAKE_CURRENT_SOURCE_DIR}/../deps/cef/neutrinocef_helper.exe"
    COMMENT "Copying neutrinocef_helper.exe to deps/cef/"
)