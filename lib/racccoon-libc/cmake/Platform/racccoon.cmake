# CMake platform module for racccoon (CMAKE_SYSTEM_NAME racccoon, from
# racccoon.cmake). Statically linked, POSIX-shaped: UNIX is what makes
# projects like LLVM pick their Unix implementation.
set(UNIX 1)
set(CMAKE_STATIC_LIBRARY_PREFIX "lib")
set(CMAKE_STATIC_LIBRARY_SUFFIX ".a")
set(CMAKE_EXECUTABLE_SUFFIX "")
set_property(GLOBAL PROPERTY TARGET_SUPPORTS_SHARED_LIBS FALSE)
