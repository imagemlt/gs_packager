#!/usr/bin/env bash
# 用一份工具链快照真编译 AMLgsMenu / AMLDigitalFPV，验证快照可用。
#
# 用法:
#   scripts/verify-snapshot.sh --snapshot snapshots/aml-toolchain-<triplet>.tar.zst \
#       --projects-dir ~/projects        # 目录下需有 AMLgsMenu/ 与 AMLDigitalFPV/
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SELF_DIR}/.." && pwd)"

SNAPSHOT=""
PROJECTS_DIR=""
PROJECTS="AMLgsMenu AMLDigitalFPV"
ARTIFACTS_DIR=""
BUILD_TYPE="${BUILD_TYPE:-Release}"
WORK_DIR=""
TRIPLET="${TRIPLET:-armv8a-libreelec-linux-gnueabihf}"
JOBS="$(nproc 2>/dev/null || echo 4)"
KEEP_WORK=0

log() { printf '[verify] %s\n' "$*"; }
die() { printf '[verify] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: scripts/verify-snapshot.sh --snapshot FILE [选项]

  --snapshot FILE       工具链快照（.tar.zst / .tar.gz）
  --projects-dir DIR    项目源码目录（默认 \${HOME}/projects）
  --projects "..."      要编译的项目名（默认 "AMLgsMenu AMLDigitalFPV"）
  --artifacts-dir DIR   把产物与 sha256 留档到该目录（用于两次快照的产物对比）
  --build-type TYPE     CMAKE_BUILD_TYPE（默认 ${BUILD_TYPE}，与 build workflow 一致）
  --work DIR            工作目录（默认 mktemp）
  --triplet NAME        目标三元组（默认 ${TRIPLET}）
  --jobs N              并行度（默认 ${JOBS}）
  --keep-work           保留工作目录
  -h, --help            显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --snapshot) SNAPSHOT="$2"; shift 2 ;;
        --projects-dir) PROJECTS_DIR="$2"; shift 2 ;;
        --projects) PROJECTS="$2"; shift 2 ;;
        --artifacts-dir) ARTIFACTS_DIR="$2"; shift 2 ;;
        --build-type) BUILD_TYPE="$2"; shift 2 ;;
        --work) WORK_DIR="$2"; shift 2 ;;
        --triplet) TRIPLET="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --keep-work) KEEP_WORK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（--help 查看用法）" ;;
    esac
done

[ -n "$SNAPSHOT" ] || die "缺少 --snapshot"
[ -f "$SNAPSHOT" ] || die "快照不存在: $SNAPSHOT"
if [ -z "$PROJECTS_DIR" ]; then PROJECTS_DIR="${HOME}/projects"; fi
[ -d "$PROJECTS_DIR" ] || die "项目目录不存在: $PROJECTS_DIR"

if [ -z "$WORK_DIR" ]; then WORK_DIR="$(mktemp -d)"; else rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"; fi
cleanup() { if [ "$KEEP_WORK" = 0 ]; then rm -rf "$WORK_DIR"; fi; }
trap cleanup EXIT

TOOLCHAIN_DIR="$WORK_DIR/toolchain"
mkdir -p "$TOOLCHAIN_DIR"
log "解压快照到 $TOOLCHAIN_DIR"
case "$SNAPSHOT" in
    *.zst) command -v zstd >/dev/null 2>&1 || die "需要 zstd 才能解压 $SNAPSHOT"
           zstd -d -c "$SNAPSHOT" | tar -xf - -C "$TOOLCHAIN_DIR" ;;
    *)     tar -xf "$SNAPSHOT" -C "$TOOLCHAIN_DIR" ;;
esac

[ -d "$TOOLCHAIN_DIR/$TRIPLET/sysroot" ] || die "快照解压后缺少 sysroot，文件可能不完整"

# 环境（与 env.sh 等价，这里不 source 以免污染调用者）
export AML_TOOLCHAIN_DIR="$TOOLCHAIN_DIR"
export LD_LIBRARY_PATH="$TOOLCHAIN_DIR/x86_64-linux-gnu/$TRIPLET/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
REAL_GCC="$(ls -1 "$TOOLCHAIN_DIR/bin/${TRIPLET}-gcc"-[0-9]* 2>/dev/null | sort -V | tail -1)"
REAL_GXX="$(ls -1 "$TOOLCHAIN_DIR/bin/${TRIPLET}-g++"-[0-9]* 2>/dev/null | sort -V | tail -1)"
REAL_GCC="${REAL_GCC:-$TOOLCHAIN_DIR/bin/${TRIPLET}-gcc}"
REAL_GXX="${REAL_GXX:-$TOOLCHAIN_DIR/bin/${TRIPLET}-g++}"
log "编译器: $REAL_GCC"

FAILED=0
if [ -n "$ARTIFACTS_DIR" ]; then
    rm -rf "$ARTIFACTS_DIR"
    mkdir -p "$ARTIFACTS_DIR"
fi

for project in $PROJECTS; do
    SRC="$PROJECTS_DIR/$project"
    if [ ! -d "$SRC" ]; then
        log "跳过 $project：找不到 $SRC"
        FAILED=1
        continue
    fi

    # 子模块提醒（AMLgsMenu 需要 third_party/imgui 与 third_party/mavlink）
    if [ -f "$SRC/.gitmodules" ] && [ ! -f "$SRC/third_party/imgui/imgui.h" ]; then
        log "警告: $project 的子模块看起来没初始化"
        log "      git -C $SRC submodule update --init --recursive"
    fi

    EXTRA_ARGS=()
    if [ "$project" = "AMLgsMenu" ]; then
        EXTRA_ARGS+=("-DIMGUI_ROOT=$SRC/third_party/imgui" "-DAML_ENABLE_GLES=ON")
    fi

    BUILD_DIR="$WORK_DIR/build-$project"
    log "配置 $project …"
    cmake -S "$SRC" -B "$BUILD_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="$REPO_DIR/toolchain.cmake" \
        -DAML_TOOLCHAIN_DIR="$TOOLCHAIN_DIR" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        "${EXTRA_ARGS[@]}" > "$WORK_DIR/$project-configure.log" 2>&1 || {
            tail -20 "$WORK_DIR/$project-configure.log" >&2
            die "$project 配置失败（完整日志: $WORK_DIR/$project-configure.log）"
        }

    log "编译 $project …"
    cmake --build "$BUILD_DIR" -j"$JOBS" > "$WORK_DIR/$project-build.log" 2>&1 || {
        tail -30 "$WORK_DIR/$project-build.log" >&2
        die "$project 编译失败"
    }

    BIN="$BUILD_DIR/$project"
    [ -f "$BIN" ] || die "$project 编译产物不存在: $BIN"
    FILE_INFO="$(file -b "$BIN")"
    case "$FILE_INFO" in
        *ARM*) ;;
        *) die "$project 产物不是 ARM 可执行文件: $FILE_INFO" ;;
    esac
    log "OK  $project → $BIN ($(du -h "$BIN" | cut -f1))  $FILE_INFO"

    # 留档：两次快照（如精简版 vs 全量版）的产物 sha256 应当完全相同
    if [ -n "$ARTIFACTS_DIR" ]; then
        cp "$BIN" "$ARTIFACTS_DIR/$project"
        ( cd "$ARTIFACTS_DIR" && sha256sum "$project" > "$project.sha256" )
    fi
done

[ "$FAILED" = 0 ] || die "有项目未能验证"

if [ -n "$ARTIFACTS_DIR" ]; then
    ( cd "$ARTIFACTS_DIR" && cat ./*.sha256 | sort > ALL.sha256 )
    log "产物 sha256 已留档: $ARTIFACTS_DIR/ALL.sha256"
fi

log "全部通过：快照可用"
