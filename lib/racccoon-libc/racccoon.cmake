# CMake toolchain file: C/C++ for racccoon with the host clang, against
# racccoon-libc + the libc++ build_cxx.sh installs. Used by build_llvm.sh.
#
# Executables (including every configure-time try_compile) are linked for
# real with ld.lld + racccoon-libc.ld + crt0_mapped.o (8 MiB stack), so
# CMake's "does function X exist" checks see what racccoon-libc actually
# provides instead of passing on a declaration alone.
#
# Needs build/libc (lib/racccoon-libc/build.sh) and build/cxx
# (build_cxx.sh) to exist first.

# Our own platform (cmake/Platform/racccoon.cmake): sets UNIX, which a
# toolchain file can't (the platform step resets it) and which LLVM needs
# to pick its Support/Unix implementation.
set(CMAKE_SYSTEM_NAME racccoon)
set(CMAKE_SYSTEM_PROCESSOR riscv64)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/cmake")

get_filename_component(RC_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(RC_LIBC "${RC_ROOT}/build/libc")
set(RC_CXX  "${RC_ROOT}/build/cxx/install")

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_ASM_COMPILER clang)
set(CMAKE_C_COMPILER_TARGET riscv64-unknown-elf)
set(CMAKE_CXX_COMPILER_TARGET riscv64-unknown-elf)
set(CMAKE_ASM_COMPILER_TARGET riscv64-unknown-elf)
find_program(RC_AR llvm-ar REQUIRED)
find_program(RC_RANLIB llvm-ranlib REQUIRED)
set(CMAKE_AR "${RC_AR}")
set(CMAKE_RANLIB "${RC_RANLIB}")

execute_process(COMMAND clang -print-resource-dir
                OUTPUT_VARIABLE RC_RESDIR OUTPUT_STRIP_TRAILING_WHITESPACE)
execute_process(COMMAND riscv64-unknown-elf-gcc -print-libgcc-file-name
                OUTPUT_VARIABLE RC_LIBGCC OUTPUT_STRIP_TRAILING_WHITESPACE)

set(RC_ARCH "-march=rv64imafdc -mabi=lp64d -mcmodel=medany -fno-pic")
set(RC_COMMON "${RC_ARCH} -ffunction-sections -fdata-sections -fno-stack-protector")
set(RC_CINC "-nostdinc -isystem ${RC_ROOT}/lib/racccoon-libc/include -isystem ${RC_RESDIR}/include")
set(CMAKE_C_FLAGS_INIT "${RC_COMMON} ${RC_CINC}")
set(CMAKE_CXX_FLAGS_INIT "${RC_COMMON} -nostdinc++ -isystem ${RC_CXX}/include/c++/v1 ${RC_CINC}")
set(CMAKE_ASM_FLAGS_INIT "${RC_ARCH}")

set(RC_LINK "ld.lld --gc-sections -L ${RC_LIBC} -T ${RC_ROOT}/lib/racccoon-libc/racccoon-libc.ld ${RC_LIBC}/crt0_mapped.o")
set(RC_LINK_TAIL "${RC_CXX}/lib/libc++.a ${RC_LIBC}/libracccoon.a ${RC_LIBGCC}")
set(CMAKE_C_LINK_EXECUTABLE   "${RC_LINK} <OBJECTS> -o <TARGET> <LINK_LIBRARIES> ${RC_LINK_TAIL}")
set(CMAKE_CXX_LINK_EXECUTABLE "${RC_LINK} <OBJECTS> -o <TARGET> <LINK_LIBRARIES> ${RC_LINK_TAIL}")

# Never pick up the host's libraries or headers: only racccoon-libc and
# what's been built for racccoon under build/ (libc++, LLVM + lld for c3c).
set(CMAKE_FIND_ROOT_PATH "${RC_ROOT}/lib/racccoon-libc" "${RC_ROOT}/build")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
