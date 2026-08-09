cmake_minimum_required(VERSION 3.16)
project(lanmp_server CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_executable(lanmp_server
  src/main.cpp
  src/Server.cpp
  src/Auth.cpp
  src/Logger.cpp
)

target_include_directories(lanmp_server PRIVATE src)

if(WIN32)
  target_link_libraries(lanmp_server PRIVATE ws2_32)
  target_compile_definitions(lanmp_server PRIVATE NOMINMAX)
endif()

if(MSVC)
  target_compile_options(lanmp_server PRIVATE /W4)
else()
  target_compile_options(lanmp_server PRIVATE -Wall -Wextra)
endif()

# Ship a single self contained binary so players do not need a toolchain runtime.
if(MINGW)
  target_link_options(lanmp_server PRIVATE -static -static-libgcc -static-libstdc++)
endif()

install(TARGETS lanmp_server RUNTIME DESTINATION bin)
