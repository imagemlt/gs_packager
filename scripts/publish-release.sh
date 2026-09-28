#!/usr/bin/env bash
# 把工具链快照发布为 GitHub release asset。
#
# 需要一个有 contents:write 权限的 token（fine-grained PAT 或 classic PAT）：
#   GH_TOKEN=github_pat_xxx scripts/publish-release.sh --tag toolchain-2026.09
#
# 也可以用环境变量 GH_TOKEN / GITHUB_TOKEN，或用 --token 传入。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SELF_DIR}/.." && pwd)"

CIDR="${GH_REPO:-}"
TAG=""
TITLE=""
NOTES=""
ASSET_DIR="${REPO_DIR}/snapshots"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
DRY_RUN=0
CLOBBER=0

log() { printf '[publish] %s\n' "$*"; }
die() { printf '[publish] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: GH_TOKEN=<token> scripts/publish-release.sh --tag <tag> [选项]

  --tag TAG         release tag（必填，例如 toolchain-2026.09）
  --repo OWNER/NAME 默认取 git origin
  --dir DIR         资产目录（默认 ${ASSET_DIR}）
  --title TITLE     release 标题（默认 "toolchain <tag>"）
  --notes TEXT      release 说明
  --clobber         同名 asset 已存在时先删除再上传
  --dry-run         只打印将要执行的 API 调用
  -h, --help        显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        --repo) CIDR="$2"; shift 2 ;;
        --dir) ASSET_DIR="$2"; shift 2 ;;
        --title) TITLE="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --clobber) CLOBBER=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（--help 查看用法）" ;;
    esac
done

[ -n "$TAG" ] || die "缺少 --tag"
[ -d "$ASSET_DIR" ] || die "资产目录不存在: $ASSET_DIR"

if [ -z "$CIDR" ]; then
    origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
    case "$origin" in
        git@github.com:*) CIDR="${origin#git@github.com:}"; CIDR="${CIDR%.git}" ;;
        https://github.com/*) CIDR="${origin#https://github.com/}"; CIDR="${CIDR%.git}" ;;
        *) die "无法从 origin 推断仓库，请用 --repo owner/name" ;;
    esac
fi

command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v jq >/dev/null 2>&1 || die "需要 jq"

ASSETS=()
while IFS= read -r -d '' f; do ASSETS+=("$f"); done < <(find "$ASSET_DIR" -maxdepth 1 -type f \
    \( -name "*.tar.zst" -o -name "*.tar.gz" -o -name "SHA256SUMS" -o -name "snapshot-info.txt" \) -print0 | sort -z)
[ "${#ASSETS[@]}" -gt 0 ] || die "$ASSET_DIR 里没有可发布的文件（先跑 scripts/make-snapshot.sh）"

[ -n "$TITLE" ] || TITLE="toolchain ${TAG}"
if [ -z "$NOTES" ] && [ -f "$ASSET_DIR/snapshot-info.txt" ]; then
    NOTES="$(cat "$ASSET_DIR/snapshot-info.txt")"
fi

log "仓库:   $CIDR"
log "tag:    $TAG"
log "资产:"
for f in "${ASSETS[@]}"; do log "  - $(basename "$f") ($(du -h "$f" | cut -f1))"; done

API="https://api.github.com/repos/${CIDR}"
UPLOADS="https://uploads.github.com/repos/${CIDR}"

if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] POST ${API}/releases   {\"tag_name\":\"${TAG}\", ...}"
    for f in "${ASSETS[@]}"; do
        log "[dry-run] POST ${UPLOADS}/releases/<id>/assets?name=$(basename "$f")  ($(du -h "$f" | cut -f1))"
    done
    exit 0
fi

if [ -z "$TOKEN" ]; then
    die "缺少 token：GH_TOKEN=xxx（或 --token）；需要 contents:write 权限"
fi

api() { curl -fsSL -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

# 1. 取或建 release
release_json="$(api "${API}/releases/tags/${TAG}" 2>/dev/null || true)"
if [ -z "$release_json" ] || [ "$release_json" = "null" ]; then
    if [ -n "$NOTES" ]; then
        payload="$(jq -n --arg tag "$TAG" --arg name "$TITLE" --arg body "$NOTES" \
            '{tag_name:$tag, name:$name, body:$body}')"
    else
        payload="$(jq -n --arg tag "$TAG" --arg name "$TITLE" '{tag_name:$tag, name:$name}')"
    fi
    log "创建 release ${TAG}"
    release_json="$(api -X POST -d "$payload" "${API}/releases")" \
        || die "创建 release 失败（token 权限是否含 contents:write？）"
else
    log "release ${TAG} 已存在，复用"
fi

release_id="$(printf '%s' "$release_json" | jq -r '.id')"
[ -n "$release_id" ] && [ "$release_id" != "null" ] || die "无法获取 release id"

# 2. 上传资产（同名先删）
for f in "${ASSETS[@]}"; do
    name="$(basename "$f")"
    existing="$(printf '%s' "$release_json" | jq -r --arg n "$name" '.assets[]? | select(.name==$n) | .id' | head -1)"
    if [ -n "$existing" ]; then
        if [ "$CLOBBER" = 1 ]; then
            log "删除同名 asset ${name} (id=${existing})"
            api -X DELETE "${API}/releases/assets/${existing}" >/dev/null
        else
            log "跳过已存在的 asset ${name}（要覆盖请加 --clobber）"
            continue
        fi
    fi
    log "上传 ${name} ($(du -h "$f" | cut -f1))"
    curl -fsS -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/octet-stream" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        --data-binary "@${f}" \
        "${UPLOADS}/releases/${release_id}/assets?name=${name}" >/dev/null \
        || die "上传 ${name} 失败"
done

log "完成: https://github.com/${CIDR}/releases/tag/${TAG}"
