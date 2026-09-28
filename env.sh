#!/usr/bin/env bash
# 交叉编译环境（供 AMLgsMenu / AMLDigitalFPV 等地面端项目使用）
#
# 用法：
#   export AML_TOOLCHAIN_DIR=/path/to/toolchain-snapshot
#   source env.sh
#   cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=/path/to/gs_packager/toolchain.cmake
#
# 说明：
#   - CoreELEC 在容器内生成的 bin/<triplet>-gcc 是 ccache 包装脚本，里面写死了
#     容器路径（/home/docker/...），容器外不可用；这里优先选用真实的 -gcc-<ver> 二进制。
#   - as/ld 依赖 host 侧 libbfd，必须把 x86_64-linux-gnu/<triplet>/lib 加进 LD_LIBRARY_PATH。
#   - 链接期需要 -Wl,-rpath-link，否则 libstdc++ 依赖的 libm/libc 解析不到。

AML_TOOLCHAIN_DIR="${AML_TOOLCHAIN_DIR:-${TOOLCHAIN_DIR:-${PWD}/toolchain}}"
TRIPLET="${TRIPLET:-armv8a-libreelec-linux-gnueabihf}"

if [ ! -d "${AML_TOOLCHAIN_DIR}/${TRIPLET}/sysroot" ]; then
    echo "[env.sh] 找不到 sysroot: ${AML_TOOLCHAIN_DIR}/${TRIPLET}/sysroot" >&2
    echo "[env.sh] 请先设置 AML_TOOLCHAIN_DIR 指向工具链快照根目录" >&2
    return 1 2>/dev/null || exit 1
fi

export AML_TOOLCHAIN_DIR
export TRIPLET
export SYSROOT="${AML_TOOLCHAIN_DIR}/${TRIPLET}/sysroot"

# host 侧库（binutils 的 libbfd 等）
export LD_LIBRARY_PATH="${AML_TOOLCHAIN_DIR}/x86_64-linux-gnu/${TRIPLET}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# 交叉工具（ar/ranlib/strip/ld 等）
export PATH="${AML_TOOLCHAIN_DIR}/bin:${PATH}"

# 解析出真实编译器：优先 <triplet>-gcc-<版本>，不存在才退回包装脚本
_aml_resolve() {
    local kind="$1" base real
    base="${AML_TOOLCHAIN_DIR}/bin/${TRIPLET}-${kind}"
    real="$(ls -1 "${base}"-[0-9]* 2>/dev/null | sort -V | tail -1)"
    printf '%s\n' "${real:-${base}}"
}

export CC="$(_aml_resolve gcc)"
export CXX="$(_aml_resolve g++)"
export AR="${AML_TOOLCHAIN_DIR}/bin/${TRIPLET}-ar"
export RANLIB="${AML_TOOLCHAIN_DIR}/bin/${TRIPLET}-ranlib"
export STRIP="${AML_TOOLCHAIN_DIR}/bin/${TRIPLET}-strip"
export NM="${AML_TOOLCHAIN_DIR}/bin/${TRIPLET}-nm"

export CFLAGS="--sysroot=${SYSROOT}${CFLAGS:+ ${CFLAGS}}"
export CXXFLAGS="--sysroot=${SYSROOT}${CXXFLAGS:+ ${CXXFLAGS}}"
export LDFLAGS="--sysroot=${SYSROOT} -Wl,-rpath-link,${SYSROOT}/usr/lib${LDFLAGS:+ ${LDFLAGS}}"

# pkg-config 也要限定在 sysroot 内
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig"

unset -f _aml_resolve

echo "[env.sh] toolchain : ${AML_TOOLCHAIN_DIR}"
echo "[env.sh] CC/CXX    : ${CC} / ${CXX}"
echo "[env.sh] sysroot   : ${SYSROOT}"
