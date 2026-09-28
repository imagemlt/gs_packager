#!/usr/bin/env bash
# 造一个最小的「假工具链」，用于在 CI 里验证 make-snapshot.sh 的
# 裁剪 / 链接修复 / 打包逻辑（不需要真的 CoreELEC 工具链）。
#
# 用法: tests/make-fixture-toolchain.sh <目标目录>
set -euo pipefail

DEST="${1:?用法: make-fixture-toolchain.sh <目录>}"
TRIPLET="armv8a-libreelec-linux-gnueabihf"
# 故意使用容器内路径：快照必须能把它修成相对链接
FAKE_BUILD_PREFIX="/home/docker/CoreELEC/build.CoreELEC-Amlogic-ng.arm-21/toolchain"

rm -rf "$DEST"
mkdir -p \
    "$DEST/bin" \
    "$DEST/lib/gcc/$TRIPLET/13.2.0" \
    "$DEST/$TRIPLET/bin" \
    "$DEST/$TRIPLET/sysroot/usr/lib" \
    "$DEST/x86_64-linux-gnu/$TRIPLET/lib"

# 交叉工具（内容无所谓，只要存在）
for f in gcc-13.2.0 g++-13.2.0 ar ranlib strip nm objcopy ld ld.gold dwp lto-dump; do
    : > "$DEST/bin/${TRIPLET}-${f}"
done
: > "$DEST/$TRIPLET/bin/as"

# GCC 支持文件：liblto_plugin.so 必须保留，lto1 会被精简掉
: > "$DEST/lib/gcc/$TRIPLET/13.2.0/liblto_plugin.so"
: > "$DEST/lib/gcc/$TRIPLET/13.2.0/lto1"
# host 侧库（libbfd）
: > "$DEST/x86_64-linux-gnu/$TRIPLET/lib/libbfd-2.41.so"

# sysroot：含可以解析的目标文件 + 指向构建机绝对路径的悬空链接
: > "$DEST/$TRIPLET/sysroot/usr/lib/libc.so.6"
: > "$DEST/$TRIPLET/sysroot/usr/lib/libm.so.6"
: > "$DEST/$TRIPLET/sysroot/usr/lib/libinput.so.10.13.0"
ln -s "$FAKE_BUILD_PREFIX/$TRIPLET/sysroot/usr/lib/libm.so.6" "$DEST/$TRIPLET/sysroot/usr/lib/libm.so"
ln -s "$FAKE_BUILD_PREFIX/$TRIPLET/sysroot/usr/lib/libinput.so.10.13.0" "$DEST/$TRIPLET/sysroot/usr/lib/libinput.so"

# --- 供 --lean 精简测试用的内容 ---------------------------------------------
mkdir -p \
    "$DEST/$TRIPLET/sysroot/usr/include" \
    "$DEST/$TRIPLET/sysroot/usr/share/pkgconfig" \
    "$DEST/$TRIPLET/sysroot/usr/share/kodi" \
    "$DEST/$TRIPLET/sysroot/usr/bin" \
    "$DEST/$TRIPLET/sysroot/usr/lib/kodi"
# 必须保留的编译所需内容
: > "$DEST/$TRIPLET/sysroot/usr/include/stdio.h"
: > "$DEST/$TRIPLET/sysroot/usr/share/pkgconfig/gstreamer-1.0.pc"
# 应当被精简掉的
: > "$DEST/$TRIPLET/sysroot/usr/share/kodi/kodi.bin"
: > "$DEST/$TRIPLET/sysroot/usr/lib/kodi/kodi.bin"
: > "$DEST/$TRIPLET/sysroot/usr/bin/Xorg"
# 链接脚本引用的 .a：绝不能删（glibc 就是这么干的）
printf '/* GNU ld script */\nGROUP ( /usr/lib/libc.so.6 /usr/lib/libc_nonshared.a )\n' \
    > "$DEST/$TRIPLET/sysroot/usr/lib/libc.so"
: > "$DEST/$TRIPLET/sysroot/usr/lib/libc_nonshared.a"
# 有同名 .so → 可删；没有同名 .so → 必须留
: > "$DEST/$TRIPLET/sysroot/usr/lib/libfoo.a"
: > "$DEST/$TRIPLET/sysroot/usr/lib/libfoo.so.1"
: > "$DEST/$TRIPLET/sysroot/usr/lib/libbar.a"

echo "fixture 工具链已生成: $DEST"
