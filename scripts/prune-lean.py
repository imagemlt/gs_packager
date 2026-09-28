#!/usr/bin/env python3
"""精简一份工具链快照：删掉 AMLgsMenu / AMLDigitalFPV 编译用不到的内容。

实测收益：解压后 895 MB → 540 MB，tar.zst 218 MB → 139 MB（约 -36%）。

只在 <triplet>/sysroot 内动手，**绝不碰** bin/、lib/gcc/、libexec/gcc/、x86_64-linux-gnu/
—— 那些是编译器本体和 host 侧库，删任何东西都会让工具链直接不可用。

两类操作：

1. 黑名单目录/文件：文档、locale、Kodi、目标端可执行文件、Python 运行时…
   这些只对「在设备上运行」有意义，交叉编译用不到。

2. 静态库（.a）规则：只删「同目录有同名 .so」**且**「没被任何链接脚本引用」的 .a。

   为什么不能整类删 .a：glibc 的 libc.so 不是二进制而是个链接脚本
       GROUP ( /usr/lib/libc.so.6 /usr/lib/libc_nonshared.a AS_NEEDED ( /usr/lib/ld-linux...so.1 ) )
   删掉 libc_nonshared.a 后**所有**链接都会失败：
       ld: cannot find /usr/lib/libc_nonshared.a inside <sysroot>
   这和 liblto_plugin.so 属于同一类坑：文件很小，但缺了整个构建就挂。

用法:
    scripts/prune-lean.py <工具链根目录> [--triplet NAME] [--dry-run]

退出码: 0 成功；非 0 表示精简后校验不通过（缺关键文件），此时**不要**发布这份快照。
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import re
import shutil
import sys

# sysroot 内要整目录删掉的内容（相对 sysroot）
BLACKLIST_DIRS = [
    # 文档 / 本地化 / man / info：运行时用
    "usr/share/kodi",
    "usr/share/locale",
    "usr/share/man",
    "usr/share/doc",
    "usr/share/i18n",
    "usr/share/info",
    "usr/share/gir-1.0",
    "usr/share/X11",
    "usr/share/sounds",
    "usr/share/vala",
    "usr/share/gobject-introspection-1.0",
    "usr/share/gdbus-2.0",
    "usr/data",  # 若存在
    "usr/man",
    # autotools 运行时（cmake 构建用不到；aclocal/libtool 保留以防以后引入 autotools 依赖）
    "usr/share/autoconf",
    "usr/share/automake-1.16",
    # 目标端可执行文件：交叉编译不执行它们
    "usr/bin",
    "usr/sbin",
    # Kodi / Python 运行时 / 字符集转换模块
    "usr/lib/kodi",
    "usr/lib/python3.11",
    "usr/lib/gconv",
    "usr/lib/girepository-1.0",
]

# sysroot 内要删的文件通配（相对 sysroot，fnmatch 语法）
BLACKLIST_GLOBS = [
    "usr/lib/libpython3.*.so*",
    "usr/lib/libdovi.a",
]

# 精简后必须仍然存在的文件/目录（相对 sysroot）
MUST_EXIST = [
    "usr/lib/libc.so.6",
    "usr/include",
    "usr/share/pkgconfig",  # pkg-config 模块目录：AMDigitalFPV 靠它找 GStreamer
]

LINKER_SCRIPT_RE = re.compile(rb"^\s*(GROUP|INPUT|OUTPUT_FORMAT|/\* GNU ld script)", re.M)
ARCHIVE_REF_RE = re.compile(r"[\w./+-]+\.a\b")


def human(num: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if num < 1024 or unit == "GB":
            return f"{num:.0f} {unit}" if unit == "B" else f"{num:.1f} {unit}"
        num /= 1024.0
    return f"{num:.1f} GB"


def tree_size(path: str) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            p = os.path.join(root, name)
            try:
                total += os.lstat(p).st_size
            except OSError:
                pass
    return total


def scan_linker_scripts(sysroot: str) -> set[str]:
    """找出被链接脚本引用的 .a 的名字（这些不能删）。"""
    referenced: set[str] = set()
    for root, _dirs, files in os.walk(sysroot):
        for name in files:
            if ".so" not in name:
                continue
            path = os.path.join(root, name)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as handle:
                    head = handle.read(8192)
            except OSError:
                continue
            if LINKER_SCRIPT_RE.search(head):
                text = head.decode("utf-8", "replace")
                for match in ARCHIVE_REF_RE.findall(text):
                    referenced.add(os.path.basename(match))
    return referenced


def remove_path(path: str, dry_run: bool) -> int:
    """删除文件或目录，返回释放的字节数。"""
    if not os.path.exists(path) and not os.path.islink(path):
        return 0
    freed = tree_size(path) if os.path.isdir(path) and not os.path.islink(path) else os.lstat(path).st_size
    if not dry_run:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
    return freed


def has_sibling_shared_object(archive: str) -> bool:
    """同目录下是否存在同名 .so / .so.N（存在说明可以动态链接，静态库可删）。"""
    directory = os.path.dirname(archive)
    stem = os.path.basename(archive)[:-2]  # 去掉 .a
    if not os.path.isdir(directory):
        return False
    prefix = stem + ".so"
    try:
        return any(name == prefix or name.startswith(prefix + ".") for name in os.listdir(directory))
    except OSError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="精简工具链快照（删除编译无关内容）")
    parser.add_argument("toolchain_dir", help="工具链根目录（含 <triplet>/sysroot）")
    parser.add_argument(
        "--triplet",
        default=os.environ.get("TRIPLET", "armv8a-libreelec-linux-gnueabihf"),
        help="目标三元组（默认 armv8a-libreelec-linux-gnueabihf）",
    )
    parser.add_argument("--dry-run", action="store_true", help="只报告要删什么，不实际删除")
    args = parser.parse_args()

    sysroot = os.path.join(args.toolchain_dir, args.triplet, "sysroot")
    if not os.path.isdir(sysroot):
        print(f"[prune] 错误: 找不到 sysroot: {sysroot}", file=sys.stderr)
        return 2

    before = tree_size(sysroot)
    print(f"[prune] sysroot: {sysroot}")
    print(f"[prune] 精简前: {human(before)}")

    removed = 0
    removed_items = 0

    # --- 1. 黑名单目录 -------------------------------------------------------
    for rel in BLACKLIST_DIRS:
        path = os.path.join(sysroot, rel)
        freed = remove_path(path, args.dry_run)
        if freed:
            removed += freed
            removed_items += 1
            print(f"[prune]   删除 {rel:<42} {human(freed):>9}")

    # --- 2. 黑名单文件 -------------------------------------------------------
    for glob in BLACKLIST_GLOBS:
        parent, pattern = os.path.split(glob)
        directory = os.path.join(sysroot, parent)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            if not fnmatch.fnmatch(name, pattern):
                continue
            freed = remove_path(os.path.join(directory, name), args.dry_run)
            if freed:
                removed += freed
                removed_items += 1
                print(f"[prune]   删除 {os.path.join(parent, name):<42} {human(freed):>9}")

    # --- 3. 静态库规则 -------------------------------------------------------
    protected = scan_linker_scripts(sysroot)
    print(f"[prune] 被链接脚本引用的静态库（必须保留）: {', '.join(sorted(protected)) or '（无）'}")

    archives = []
    for root, _dirs, files in os.walk(sysroot):
        for name in files:
            if name.endswith(".a"):
                archives.append(os.path.join(root, name))

    kept_no_so = 0
    skipped_protected = 0
    for archive in sorted(archives):
        name = os.path.basename(archive)
        if name in protected:
            skipped_protected += 1
            continue
        if not has_sibling_shared_object(archive):
            kept_no_so += 1
            continue
        freed = remove_path(archive, args.dry_run)
        if freed:
            removed += freed
            removed_items += 1

    deleted_archives = len(archives) - kept_no_so - skipped_protected
    print(
        f"[prune]   静态库: 共 {len(archives)} 个 → 删 {deleted_archives} 个"
        f"（有同名 .so 且未被链接脚本引用），保留 {kept_no_so} 个（无同名 .so）"
        f" + {skipped_protected} 个（被链接脚本引用）"
    )

    after = before - removed
    print(f"[prune] 精简后: {human(after)}   （共删 {removed_items} 项，{human(removed)}，{removed * 100.0 / before:.1f}%）")

    # --- 4. 完整性校验（不通过就别发布） -------------------------------------
    problems = [
        rel for rel in MUST_EXIST if not os.path.exists(os.path.join(sysroot, rel))
    ]
    # 被链接脚本引用的 .a 必须都还在
    for archive in archives:
        name = os.path.basename(archive)
        if name in protected and not os.path.exists(archive):
            problems.append(name)
    if problems:
        print("[prune] 错误: 精简后缺少关键内容，不要发布这份快照:", file=sys.stderr)
        for rel in problems:
            print(f"[prune]   - {rel}", file=sys.stderr)
        return 1

    if args.dry_run:
        print("[prune] （dry-run：未实际删除）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
