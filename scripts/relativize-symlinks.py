#!/usr/bin/env python3
"""把工具链快照里指向绝对路径的符号链接改写成相对路径，使整棵树可以搬到任意目录。

背景
----
CoreELEC 的交叉工具链是在容器内 ` /home/docker/CoreELEC/... ` 下构建的，sysroot 里存在数百个
形如下面的绝对符号链接::

    sysroot/usr/lib/libm.so      -> /home/docker/CoreELEC/build.../sysroot/usr/lib/libm.so.6
    sysroot/usr/lib/libinput.so  -> /home/docker/CoreELEC/build.../sysroot/usr/lib/libinput.so.10.13.0

一旦整棵树被复制到别的路径（CI runner、发布用的 tar 快照），这些链接全部悬空，编译时表现为::

    ld: libm.so.6, needed by .../libstdc++.so, not found
    ld: cannot find -lglib-2.0
    CMake Error: libinput/udev not found

修复策略
--------
默认 ``suffix``：对每个悬空的绝对链接，在目标路径里从长到短找「最长的、在树内真实存在的后缀」，
再改写成相对该链接所在目录的相对路径。好处是不关心构建机的前缀长什么样，换机器/换布局都能修。

``prefix``：如果明确知道根目录在原始构建机上的绝对路径（``--prefix``），也可以按前缀直接映射。
"""

from __future__ import annotations

import argparse
import json
import os
import sys


def iter_symlinks(root: str):
    for dirpath, dirnames, filenames in os.walk(root, onerror=lambda _err: None):
        for name in list(dirnames) + list(filenames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                yield path


def longest_existing_suffix(root: str, target: str) -> str | None:
    """在 root 内查找 target 的最长已存在后缀，返回树内绝对路径。"""
    segments = [seg for seg in target.split("/") if seg not in ("", ".")]
    for start in range(len(segments)):
        candidate = os.path.join(root, *segments[start:])
        if os.path.exists(candidate):
            return candidate
    return None


def relativize(
    root: str,
    strategy: str = "suffix",
    prefix: str | None = None,
    dry_run: bool = False,
) -> dict:
    root = os.path.abspath(root)
    prefix = prefix.rstrip("/") if prefix else None
    fixed = 0
    unresolved: list[list[str]] = []

    for path in iter_symlinks(root):
        if os.path.exists(path):  # 未悬空（含正常的相对链接）→ 不动
            continue
        target = os.readlink(path)
        source = None

        if strategy == "prefix":
            if prefix and target.startswith(prefix + "/"):
                source = os.path.join(root, target[len(prefix) + 1 :])
                if not os.path.exists(source):
                    source = None
        else:
            if target.startswith("/"):
                source = longest_existing_suffix(root, target)

        if source is None:
            unresolved.append([os.path.relpath(path, root), target])
            continue

        relative = os.path.relpath(source, os.path.dirname(path))
        if not dry_run:
            os.unlink(path)
            os.symlink(relative, path)
        fixed += 1

    return {"root": root, "strategy": strategy, "fixed": fixed, "unresolved": unresolved}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="把悬空的绝对符号链接改写为相对链接")
    parser.add_argument("root", help="要处理的树根目录（例如工具链快照根）")
    parser.add_argument(
        "--strategy",
        choices=("suffix", "prefix"),
        default="suffix",
        help="suffix: 按最长存在后缀映射（默认，推荐）；prefix: 按 --prefix 前缀映射",
    )
    parser.add_argument("--prefix", help="root 在原始构建机上的绝对路径（strategy=prefix 时必填）")
    parser.add_argument("--dry-run", action="store_true", help="只报告不修改")
    parser.add_argument("--json", action="store_true", help="以 JSON 输出汇总")
    parser.add_argument("--fail-on-unresolved", action="store_true", help="存在无法解析的链接时退出码为 1")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    if not os.path.isdir(args.root):
        print(f"错误: 目录不存在: {args.root}", file=sys.stderr)
        return 2
    if args.strategy == "prefix" and not args.prefix:
        print("错误: --strategy prefix 需要同时给出 --prefix", file=sys.stderr)
        return 2

    result = relativize(args.root, args.strategy, args.prefix, args.dry_run)

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif not args.quiet:
        action = "将修复" if args.dry_run else "已修复"
        print(
            f"[relativize] {result['root']}: {action} {result['fixed']} 个悬空链接，"
            f"无法解析 {len(result['unresolved'])} 个"
        )
        for relative, target in result["unresolved"][:10]:
            print(f"  未解析: {relative} -> {target}")
        if len(result["unresolved"]) > 10:
            print(f"  ... 其余 {len(result['unresolved']) - 10} 个略")

    if args.fail_on_unresolved and result["unresolved"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
