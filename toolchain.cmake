# 通用 CoreELEC / Amlogic 交叉编译工具链文件
#
# 用法：
#   cmake -S <src> -B <build> \
#     -DCMAKE_TOOLCHAIN_FILE=/path/to/gs_packager/toolchain.cmake \
#     -DAML_TOOLCHAIN_DIR=/path/to/toolchain-snapshot
#   或先 export AML_TOOLCHAIN_DIR=...
#
# 已处理的三个必需项：
#   1. 绕过 CoreELEC 的 ccache 包装脚本（里面写死容器内路径）
#   2. -Wl,-rpath-link 指向 sysroot，否则 libstdc++ 依赖的 libm/libc 链接期解析不到
#   3. CMAKE_SYSROOT / FIND_ROOT_PATH 限定查找范围

if(NOT DEFINED AML_TOOLCHAIN_DIR OR AML_TOOLCHAIN_DIR STREQUAL "")
    if(DEFINED ENV{AML_TOOLCHAIN_DIR})
        set(AML_TOOLCHAIN_DIR "$ENV{AML_TOOLCHAIN_DIR}")
    else()
        message(FATAL_ERROR "请通过 -DAML_TOOLCHAIN_DIR=<快照根目录> 或环境变量 AML_TOOLCHAIN_DIR 指定工具链")
    endif()
endif()

set(AML_TARGET_TRIPLET "armv8a-libreelec-linux-gnueabihf" CACHE STRING "目标三元组")

set(_aml_bin "${AML_TOOLCHAIN_DIR}/bin/${AML_TARGET_TRIPLET}")

# 优先真实编译器 <triplet>-gcc-<ver>（ccache 包装脚本在容器外不可用）
file(GLOB _aml_gcc_versions "${_aml_bin}-gcc-[0-9]*")
if(_aml_gcc_versions)
    list(SORT _aml_gcc_versions COMPARE NATURAL ORDER ASCENDING)
    list(GET _aml_gcc_versions -1 _aml_gcc)
    string(REPLACE "-gcc-" "-g++-" _aml_gxx "${_aml_gcc}")
else()
    set(_aml_gcc "${_aml_bin}-gcc")
    set(_aml_gxx "${_aml_bin}-g++")
endif()

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   "${_aml_gcc}")
set(CMAKE_CXX_COMPILER "${_aml_gxx}")
set(CMAKE_AR           "${_aml_bin}-ar")
set(CMAKE_RANLIB       "${_aml_bin}-ranlib")
set(CMAKE_STRIP        "${_aml_bin}-strip")
set(CMAKE_NM           "${_aml_bin}-nm")
set(CMAKE_OBJCOPY      "${_aml_bin}-objcopy")
set(CMAKE_OBJDUMP      "${_aml_bin}-objdump")
set(CMAKE_READELF      "${_aml_bin}-readelf")

set(CMAKE_SYSROOT "${AML_TOOLCHAIN_DIR}/${AML_TARGET_TRIPLET}/sysroot")
set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_EXE_LINKER_FLAGS_INIT    "-Wl,-rpath-link,${CMAKE_SYSROOT}/usr/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-Wl,-rpath-link,${CMAKE_SYSROOT}/usr/lib")

message(STATUS "[gs_packager] 工具链: ${AML_TOOLCHAIN_DIR}")
message(STATUS "[gs_packager] CC/CXX: ${CMAKE_C_COMPILER} / ${CMAKE_CXX_COMPILER}")
message(STATUS "[gs_packager] sysroot: ${CMAKE_SYSROOT}")
