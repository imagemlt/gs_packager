#!/usr/bin/env bash
# 生成可搬迁的 CoreELEC 交叉工具链快照，供 CI 下载使用。
#
# 做四件事：
#   1. 裁剪：只保留 AMLgsMenu / AMLDigitalFPV 编译所需的部分（全量 3.6G → ~895M）
#   2. 修链接：把 sysroot 里指向构建机绝对路径的悬空链接改成相对链接
#   3. 冒烟：用快照自己的 gcc 编译一个 ARM 小程序，编译不过就不出包
#   4. 打包：确定性 tar（排序、固定 mtime/属主）+ zstd，附 sha256 与 info
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SELF_DIR}/.." && pwd)"

TRIPLET="${TRIPLET:-armv8a-libreelec-linux-gnueabihf}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${COREELEC_TOOLCHAIN:-}}"
OUT_DIR="${REPO_DIR}/snapshots"
NAME=""
MINIMAL=1
LEAN=0
COMPRESS="auto"
JOBS="$(nproc 2>/dev/null || echo 4)"
EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"
SKIP_SMOKE=0
VERIFY=0
PROJECTS_DIR=""
KEEP_WORK=0

log() { printf '[snapshot] %s\n' "$*"; }
die() { printf '[snapshot] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: scripts/make-snapshot.sh [选项]

  --toolchain-dir DIR   源工具链根目录（也可用 COREELEC_TOOLCHAIN 环境变量）
  --triplet NAME        目标三元组（默认 ${TRIPLET}）
  --out DIR             输出目录（默认 ${OUT_DIR}）
  --name NAME           快照名（默认 aml-toolchain-<triplet>）
  --no-minimal          保守裁剪：只剔目录，不剔 gold/dwp/lto-dump/lto1
  --lean                精简版：再剔除 sysroot 内编译无关内容（895M → 540M）
                        详见 scripts/prune-lean.py；发布前必须用 --verify 验收
  --no-lean             不精简（默认）
  --compress zstd|gzip|auto   默认 auto（有 zstd 用 zstd，否则 gzip）
  --jobs N              压缩线程数（默认 ${JOBS}）
  --epoch SECONDS       确定性打包用的 mtime（默认 ${EPOCH}）
  --skip-smoke          跳过冒烟编译（仅供测试用，正式出包不要跳）
  --verify              出包后调用 verify-snapshot.sh 真编译项目
  --projects-dir DIR    --verify 时项目目录（需含 AMLgsMenu/ 与 AMLDigitalFPV/）
  --keep-work           保留中间目录（默认删除）
  -h, --help            显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --toolchain-dir) TOOLCHAIN_DIR="$2"; shift 2 ;;
        --triplet) TRIPLET="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --no-minimal) MINIMAL=0; shift ;;
        --lean) LEAN=1; shift ;;
        --no-lean) LEAN=0; shift ;;
        --compress) COMPRESS="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --epoch) EPOCH="$2"; shift 2 ;;
        --skip-smoke) SKIP_SMOKE=1; shift ;;
        --verify) VERIFY=1; shift ;;
        --projects-dir) PROJECTS_DIR="$2"; shift 2 ;;
        --keep-work) KEEP_WORK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（--help 查看用法）" ;;
    esac
done

[ -n "$TOOLCHAIN_DIR" ] || die "未指定工具链：用 --toolchain-dir 或 COREELEC_TOOLCHAIN"
[ -d "$TOOLCHAIN_DIR" ] || die "工具链目录不存在: $TOOLCHAIN_DIR"
[ -d "$TOOLCHAIN_DIR/bin" ] || die "工具链缺少 bin/: $TOOLCHAIN_DIR"
[ -d "$TOOLCHAIN_DIR/$TRIPLET" ] || die "工具链缺少 $TRIPLET/: $TOOLCHAIN_DIR"
[ -d "$TOOLCHAIN_DIR/$TRIPLET/sysroot" ] || die "工具链缺少 sysroot: $TOOLCHAIN_DIR/$TRIPLET/sysroot"

[ -n "$NAME" ] || NAME="aml-toolchain-${TRIPLET}"

if [ "$COMPRESS" = "auto" ]; then
    if command -v zstd >/dev/null 2>&1; then COMPRESS=zstd; else COMPRESS=gzip; fi
fi
if [ "$COMPRESS" = "zstd" ]; then
    command -v zstd >/dev/null 2>&1 || die "找不到 zstd；请安装，或改用 --compress gzip"
    EXT="tar.zst"
else
    EXT="tar.gz"
fi

WORK_DIR="${OUT_DIR}/.work"
STAGE="${WORK_DIR}/stage"
mkdir -p "$OUT_DIR"

cleanup() {
    if [ "$KEEP_WORK" = 0 ]; then rm -rf "$WORK_DIR"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- 1. 裁剪复制

# 同一文件系统时用硬链接复制（快且省空间）；跨设备则退化为普通复制
copy_tree() {
    local src="$1" dst="$2"
    [ -e "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    if [ "$(stat -c %d "$src" 2>/dev/null || echo 0)" = "$(stat -c %d "$(dirname "$dst")" 2>/dev/null || echo 1)" ]; then
        cp -al "$src" "$dst" 2>/dev/null || cp -a "$src" "$dst"
    else
        cp -a "$src" "$dst"
    fi
}

log "源工具链: $TOOLCHAIN_DIR"
log "目标三元组: $TRIPLET"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin"

# 交叉工具本身（一条 cp 命令保证互相之间的硬链接不丢）
cp -a "$TOOLCHAIN_DIR"/bin/"$TRIPLET"-* "$STAGE/bin/" 2>/dev/null || die "复制 bin/ 失败"
# 目标三元组目录（含 sysroot / bin / lib / include）
copy_tree "$TOOLCHAIN_DIR/$TRIPLET" "$STAGE/$TRIPLET"
# GCC 自身支持文件（cc1 / cc1plus / libstdc++ / specs 等）
copy_tree "$TOOLCHAIN_DIR/lib/gcc/$TRIPLET" "$STAGE/lib/gcc/$TRIPLET"
# 链接器相关 libexec（部分发行版放这里）
copy_tree "$TOOLCHAIN_DIR/libexec/gcc" "$STAGE/libexec/gcc"
# host 侧库：as/ld 需要的 libbfd-*.so
copy_tree "$TOOLCHAIN_DIR/x86_64-linux-gnu/$TRIPLET" "$STAGE/x86_64-linux-gnu/$TRIPLET"

# ---------------------------------------------------------------- 2. 剔除无用大件

if [ "$MINIMAL" = 1 ]; then
    log "精简模式：剔除 gold linker / dwp / lto-dump / lto1 / 静态 libpython"
    rm -f \
        "$STAGE/bin/${TRIPLET}-ld.gold" \
        "$STAGE/bin/${TRIPLET}-dwp" \
        "$STAGE/bin/${TRIPLET}-lto-dump" \
        "$STAGE/$TRIPLET/bin/ld.gold" \
        "$STAGE/lib/gcc/$TRIPLET"/*/lto1 \
        "$STAGE/lib/gcc/$TRIPLET"/*/liblto_plugin.la 2>/dev/null || true
    rm -f "$STAGE/$TRIPLET/sysroot/usr/lib/python3."*/config-*/libpython3.*.a 2>/dev/null || true
fi

# liblto_plugin.so 绝不能删：gcc 默认 -fuse-linker-plugin，缺了会直接链接失败
if ! compgen -G "$STAGE/lib/gcc/$TRIPLET/*/liblto_plugin.so" >/dev/null; then
    die "裁剪后找不到 liblto_plugin.so（gcc 默认 -fuse-linker-plugin 需要它）"
fi
if [ ! -e "$STAGE/$TRIPLET/sysroot/usr/lib/libc.so.6" ]; then
    die "裁剪后 sysroot 里找不到 libc.so.6，快照不完整"
fi

# ---------------------------------------------------------------- 3. 修链接

log "修复悬空的绝对符号链接"
python3 "$SELF_DIR/relativize-symlinks.py" "$STAGE"

REMAINING="$(find "$STAGE" -xtype l 2>/dev/null | wc -l | tr -d ' ')"
if [ "$REMAINING" != "0" ]; then
    log "警告: 仍有 ${REMAINING} 个悬空链接（多为 sysroot 内本就缺失的可选文件）"
    find "$STAGE" -xtype l 2>/dev/null | head -5 | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 3.5 精简（可选）

if [ "$LEAN" = 1 ]; then
    log "精简模式：剔除 sysroot 内与编译无关的内容（文档/locale/Kodi/目标端可执行文件/静态库）"
    TRIPLET="$TRIPLET" python3 "$SELF_DIR/prune-lean.py" "$STAGE"
    # 精简删错了东西的话，下面的冒烟与 --verify 会暴露；这里只挡住最致命的缺失
    [ -e "$STAGE/$TRIPLET/sysroot/usr/lib/libc.so.6" ] || die "精简后缺少 libc.so.6"
    [ -d "$STAGE/$TRIPLET/sysroot/usr/include" ] || die "精简后缺少 sysroot/usr/include"
fi

# ---------------------------------------------------------------- 4. 冒烟编译

pick_gcc() {
    local candidate
    candidate="$(ls -1 "$STAGE/bin/${TRIPLET}-gcc"-[0-9]* 2>/dev/null | sort -V | tail -1)"
    printf '%s\n' "${candidate:-$STAGE/bin/${TRIPLET}-gcc}"
}

if [ "$SKIP_SMOKE" = 0 ]; then
    log "冒烟编译（用快照自己的 gcc 编译一个 ARM 小程序）"
    SMOKE_DIR="$(mktemp -d)"
    cat > "$SMOKE_DIR/smoke.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("ok\n"); return 0; }
EOF
    if ! LD_LIBRARY_PATH="$STAGE/x86_64-linux-gnu/$TRIPLET/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$(pick_gcc)" --sysroot="$STAGE/$TRIPLET/sysroot" \
        -Wl,-rpath-link,"$STAGE/$TRIPLET/sysroot/usr/lib" \
        "$SMOKE_DIR/smoke.c" -o "$SMOKE_DIR/smoke" 2>"$SMOKE_DIR/err.log"; then
        cat "$SMOKE_DIR/err.log" >&2
        rm -rf "$SMOKE_DIR"
        die "冒烟编译失败，快照不可用（常见原因：libbfd 缺失 / 链接未修复）"
    fi
    if ! file -b "$SMOKE_DIR/smoke" | grep -q "ARM"; then
        file -b "$SMOKE_DIR/smoke" >&2
        rm -rf "$SMOKE_DIR"
        die "冒烟产物不是 ARM 可执行文件，工具链配置有问题"
    fi
    rm -rf "$SMOKE_DIR"
fi

# ---------------------------------------------------------------- 5. 打包

GCC_VERSION="$("$(pick_gcc)" -dumpfullversion -dumpversion 2>/dev/null || echo unknown)"
# ld 需要 host 侧 libbfd，跑之前必须补上 LD_LIBRARY_PATH
BINUTILS_VERSION="$(LD_LIBRARY_PATH="$STAGE/x86_64-linux-gnu/$TRIPLET/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$STAGE/bin/${TRIPLET}-ld" --version 2>/dev/null | head -1 || echo unknown)"

cat > "$OUT_DIR/snapshot-info.txt" <<EOF
name=${NAME}
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# 只记目录名，不写构建机上的绝对路径（该文件会随快照一起分发）
source_toolchain=$(basename "$TOOLCHAIN_DIR")
target_triplet=${TRIPLET}
gcc_version=${GCC_VERSION}
binutils_version=${BINUTILS_VERSION}
minimal=${MINIMAL}
lean=${LEAN}
unpacked_bytes=$(du -sb "$STAGE" | cut -f1)
file_count=$(find "$STAGE" | wc -l | tr -d ' ')
EOF

ARCHIVE="$OUT_DIR/${NAME}.${EXT}"
log "打包: $(basename "$ARCHIVE")（压缩: $COMPRESS）"
TAR_ARGS=(--sort=name --owner=0 --group=0 --numeric-owner --mtime="@${EPOCH}")
if [ "$COMPRESS" = "zstd" ]; then
    tar "${TAR_ARGS[@]}" -C "$STAGE" -cf - . | zstd -19 -T"$JOBS" -q -f -o "$ARCHIVE"
else
    tar "${TAR_ARGS[@]}" -C "$STAGE" -cf - . | gzip -9 > "$ARCHIVE"
fi

# ---------------------------------------------------------------- 6. 校验和

if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$OUT_DIR" && sha256sum "$(basename "$ARCHIVE")" > "${NAME}.${EXT}.sha256" )
    ( cd "$OUT_DIR" && sha256sum "$(basename "$ARCHIVE")" > "SHA256SUMS" )
else
    ( cd "$OUT_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "${NAME}.${EXT}.sha256" )
    ( cd "$OUT_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "SHA256SUMS" )
fi

log "完成:"
log "  快照     : $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
log "  解压后   : $(du -sh "$STAGE" | cut -f1)"
log "  校验和   : $OUT_DIR/SHA256SUMS"
log "  信息     : $OUT_DIR/snapshot-info.txt"

if [ "$VERIFY" = 1 ]; then
    [ -n "$PROJECTS_DIR" ] || die "--verify 需要同时给出 --projects-dir"
    "$SELF_DIR/verify-snapshot.sh" --snapshot "$ARCHIVE" --projects-dir "$PROJECTS_DIR"
fi
