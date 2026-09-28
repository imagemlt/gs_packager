#!/usr/bin/env bash
# 干净容器验证：在「只有发行版基础环境」的容器里，用工具链快照真编译 C/C++。
#
# 为什么需要它：快照里的 binutils 是 host 侧程序（as/ld 在你机器上跑，不是目标机上跑），
# 它们会依赖构建机的系统库（如 libsframe.so.1 / libbfd-2.42-system.so）。
# 在生成快照的那台机器上这些库天然存在，所以本地冒烟通过 ≠ 换个环境也能用。
# 本脚本就是用来回答「这个快照能在哪个 runner 镜像上跑」。
#
# 用法:
#   tests/cleanroom-toolchain-test.sh /path/to/toolchain-dir [镜像...]
# 例:
#   tests/cleanroom-toolchain-test.sh /tmp/rc-tc ubuntu:24.04 ubuntu:22.04
#
# 退出码: 全部镜像通过为 0；有失败为 1。

set -euo pipefail

TOOLCHAIN_DIR="${1:-}"
shift || true

if [ -z "$TOOLCHAIN_DIR" ] || [ ! -d "$TOOLCHAIN_DIR" ]; then
  echo "用法: $0 /path/to/toolchain-dir [镜像...]" >&2
  exit 2
fi

TRIPLET="${TRIPLET:-armv8a-libreelec-linux-gnueabihf}"
IMAGES=("$@")
if [ "${#IMAGES[@]}" -eq 0 ]; then
  IMAGES=(ubuntu:24.04 ubuntu:22.04)
fi

command -v docker >/dev/null || { echo "需要 docker" >&2; exit 2; }

# 容器内脚本：装最小构建环境（apt 装出来的 binutils/gcc 会带齐 host 侧依赖库），
# 然后逐个调用工具链的 host 程序，任一失败即以该步骤命名报错。
read -r -d '' INNER <<'INNER_EOF' || true
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
# build-essential: cmake 之外的最小集合；binutils/gcc 会带来 libsframe/libbfd-system/gmp/mpc/isl
apt-get install -y -qq build-essential >/dev/null 2>&1
step() { echo "    -- $*"; }
# 失败时把工具的真实 stderr 一并打出，让"缺哪个库"自解释
fail() {
  echo "    !! FAIL: $*"
  [ -n "${LAST_OUT:-}" ] && printf '%s\n' "$LAST_OUT" | head -6 | sed 's/^/       | /'
  exit 1
}
run_tool() { LAST_OUT="$("$@" 2>&1)"; return $?; }

step "as --version"
run_tool "$TC/bin/$TB-as" --version || fail "as 无法启动（缺 host 侧库，如 libsframe.so.1）"

step "ld --version"
run_tool "$TC/bin/$TB-ld" --version || fail "ld 无法启动（缺 host 侧库，如 libbfd-2.42-system.so）"

# 用工具链自带的 readelf 断言目标架构，避免依赖容器里的 file 命令
is_arm() { "$TC/bin/$TB-readelf" -h "$1" 2>/dev/null | grep -q 'Machine:.*ARM'; }

step "gcc 编译 C"
printf 'int main(void){return 0;}\n' > /tmp/h.c
"$TC/bin/$TB-gcc-13.2.0" -c /tmp/h.c -o /tmp/h.o || fail "C 编译失败"
"$TC/bin/$TB-gcc-13.2.0" /tmp/h.c -o /tmp/h || fail "C 链接失败"
is_arm /tmp/h || fail "C 产物不是 ARM: $("$TC/bin/$TB-readelf" -h /tmp/h | grep Machine)"

step "g++ 编译 C++（cc1plus）"
printf 'int main(){return 0;}\n' > /tmp/h.cpp
"$TC/bin/$TB-g++-13.2.0" /tmp/h.cpp -o /tmp/hpp || fail "C++ 编译失败"
is_arm /tmp/hpp || fail "C++ 产物不是 ARM: $("$TC/bin/$TB-readelf" -h /tmp/hpp | grep Machine)"

step "ar / strip / nm / readelf"
"$TC/bin/$TB-ar" rc /tmp/libh.a /tmp/h.o || fail "ar 失败"
"$TC/bin/$TB-strip" /tmp/h || fail "strip 失败"
"$TC/bin/$TB-nm" /tmp/h >/dev/null 2>&1 || fail "nm 失败"
"$TC/bin/$TB-readelf" -h /tmp/h >/dev/null 2>&1 || fail "readelf 失败"

echo "    OK"
INNER_EOF

echo "##### 快照: $TOOLCHAIN_DIR  (三元组: $TRIPLET)"
echo

failed=0
for image in "${IMAGES[@]}"; do
  printf '##### 镜像 %s\n' "$image"
  if docker run --rm \
      -v "$(cd "$TOOLCHAIN_DIR" && pwd)":/tc:ro \
      -e TC=/tc -e TB="$TRIPLET" \
      -e LD_LIBRARY_PATH="/tc/x86_64-linux-gnu/$TRIPLET/lib" \
      "$image" bash -c "$INNER"; then
    echo "  => 通过"
  else
    echo "  => 失败（该镜像缺少工具链所需的 host 侧库）"
    failed=1
  fi
  echo
done

if [ "$failed" -eq 0 ]; then
  echo "全部镜像通过。"
else
  echo "有镜像未通过 —— 说明快照的环境要求比该镜像更严。"
fi
exit "$failed"
