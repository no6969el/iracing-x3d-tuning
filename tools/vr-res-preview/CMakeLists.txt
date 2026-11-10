cmake_minimum_required(VERSION 3.24)
project(vr-res-preview LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "vr-res-preview is a Windows OpenXR + D3D11 app.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# Static loader so the download is one exe. It still binds whichever OpenXR
# runtime is active on the machine.
set(BUILD_LOADER ON CACHE BOOL "" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_CONFORMANCE_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_API_LAYERS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(DYNAMIC_LOADER OFF CACHE BOOL "" FORCE)
set(BUILD_FORCE_GENERATION OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(
  OpenXR
  GIT_REPOSITORY https://github.com/KhronosGroup/OpenXR-SDK.git
  GIT_TAG release-1.1.47
)
FetchContent_MakeAvailable(OpenXR)

add_executable(vr-res-preview
  src/app.cpp
  src/renderer.cpp
)
set_target_properties(vr-res-preview PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED YES)
target_include_directories(vr-res-preview PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/src
  ${CMAKE_CURRENT_SOURCE_DIR}/third_party
)
target_compile_definitions(vr-res-preview PRIVATE
  UNICODE
  _UNICODE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  XR_USE_PLATFORM_WIN32
  XR_USE_GRAPHICS_API_D3D11
)

if(TARGET openxr_loader)
  target_link_libraries(vr-res-preview PRIVATE openxr_loader)
elseif(TARGET OpenXR::openxr_loader)
  target_link_libraries(vr-res-preview PRIVATE OpenXR::openxr_loader)
else()
  message(FATAL_ERROR "OpenXR loader target was not created")
endif()

target_link_libraries(vr-res-preview PRIVATE
  d3d11
  dxgi
  d3dcompiler
  d2d1
  dwrite
  windowscodecs
  winhttp
  ole32
  uuid
  advapi32
)

if(MSVC)
  target_compile_options(vr-res-preview PRIVATE /W4 /permissive- /utf-8)
endif()
