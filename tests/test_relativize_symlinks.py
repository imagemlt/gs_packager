#!/usr/bin/env python3
"""relativize-symlinks.py 的单元测试。"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import importlib

relativize_mod = importlib.import_module("relativize-symlinks")
relativize = relativize_mod.relativize

FAKE_BUILD_PREFIX = "/home/docker/CoreELEC/build.CoreELEC-Amlogic-ng.arm-21/toolchain"


class RelativizeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "sysroot"
        (self.root / "usr/lib").mkdir(parents=True)
        (self.root / "etc/fonts/conf.d").mkdir(parents=True)
        # 真实文件
        (self.root / "usr/lib/libm.so.6").write_text("m")
        (self.root / "usr/lib/libc.so.6").write_text("c")
        (self.root / "etc/fonts/conf.d/50-user.conf").write_text("f")

        # 悬空的绝对链接（模拟容器内构建产物）
        os.symlink(f"{FAKE_BUILD_PREFIX}/sysroot/usr/lib/libm.so.6", self.root / "usr/lib/libm.so")
        # 深一层目录：相对路径计算必须基于链接所在目录
        os.symlink(
            f"{FAKE_BUILD_PREFIX}/sysroot/usr/lib/libc.so.6",
            self.root / "etc/fonts/conf.d/10-c.conf",
        )
        # 正常的相对链接：不能被动
        os.symlink("libm.so.6", self.root / "usr/lib/libm_ok.so")
        # 无法解析的链接
        os.symlink("/nowhere/at/all/missing.so", self.root / "usr/lib/libbroken.so")

    def test_suffix_strategy_fixes_dangling_links(self) -> None:
        result = relativize(str(self.root))
        self.assertEqual(result["fixed"], 2)
        self.assertEqual(len(result["unresolved"]), 1)
        self.assertEqual(result["unresolved"][0][1], "/nowhere/at/all/missing.so")

        link = self.root / "usr/lib/libm.so"
        self.assertFalse(os.path.isabs(os.readlink(link)))
        self.assertTrue(os.path.exists(link), "修复后的链接必须能解析")
        self.assertEqual(os.path.realpath(link), str(self.root / "usr/lib/libm.so.6"))

        deep = self.root / "etc/fonts/conf.d/10-c.conf"
        self.assertTrue(os.path.exists(deep))
        self.assertEqual(os.path.realpath(deep), str(self.root / "usr/lib/libc.so.6"))

    def test_valid_relative_link_untouched(self) -> None:
        before = os.readlink(self.root / "usr/lib/libm_ok.so")
        relativize(str(self.root))
        self.assertEqual(os.readlink(self.root / "usr/lib/libm_ok.so"), before)

    def test_prefix_strategy(self) -> None:
        # root 就对应原始构建机的 <prefix>/sysroot
        result = relativize(str(self.root), strategy="prefix", prefix=f"{FAKE_BUILD_PREFIX}/sysroot")
        self.assertEqual(result["fixed"], 2)
        self.assertTrue(os.path.exists(self.root / "usr/lib/libm.so"))

    def test_dry_run_does_not_touch_files(self) -> None:
        result = relativize(str(self.root), dry_run=True)
        self.assertEqual(result["fixed"], 2)
        link = self.root / "usr/lib/libm.so"
        self.assertTrue(os.path.isabs(os.readlink(link)), "dry-run 不应修改链接")

    def test_prefix_strategy_without_prefix_changes_nothing(self) -> None:
        # 参数校验在 main() 层；函数层面在没有 prefix 时必须什么都不改
        result = relativize(str(self.root), strategy="prefix", prefix=None)
        self.assertEqual(result["fixed"], 0)
        self.assertEqual(len(result["unresolved"]), 3)
        self.assertTrue(os.path.isabs(os.readlink(self.root / "usr/lib/libm.so")))


if __name__ == "__main__":
    unittest.main()
