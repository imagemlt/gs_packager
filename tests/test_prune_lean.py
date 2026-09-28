#!/usr/bin/env python3
"""prune-lean.py 的单元测试。

重点是把两个坑固化成回归测试：
  1. glibc 的 libc.so 是链接脚本，引用的 libc_nonshared.a **不能删**（删了所有链接都挂）
  2. 只有「同目录有同名 .so」的 .a 才可删；没有同名 .so 的（如 libbar.a）必须留
"""

from __future__ import annotations

import importlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"
sys.path.insert(0, str(SCRIPTS))

prune_mod = importlib.import_module("prune-lean")

TRIPLET = "armv8a-libreelec-linux-gnueabihf"


class PruneUnitTest(unittest.TestCase):
    """纯函数级别的测试。"""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sysroot = Path(self.tmp.name)
        (self.sysroot / "usr/lib").mkdir(parents=True)

    def test_linker_script_references_are_detected(self) -> None:
        (self.sysroot / "usr/lib/libc.so.6").write_text("elf")
        (self.sysroot / "usr/lib/libc_nonshared.a").write_text("ar")
        (self.sysroot / "usr/lib/libc.so").write_text(
            "/* GNU ld script\n"
            "   Use the shared library, but some functions are only in\n"
            "   the static library, so try that secondarily.  */\n"
            "GROUP ( /usr/lib/libc.so.6 /usr/lib/libc_nonshared.a  "
            "AS_NEEDED ( /usr/lib/ld-linux-armhf.so.3 ) )\n"
        )
        # 普通二进制 .so 不应该被当成链接脚本
        (self.sysroot / "usr/lib/libz.so.1").write_text("elf binary")

        refs = prune_mod.scan_linker_scripts(str(self.sysroot))
        self.assertIn("libc_nonshared.a", refs)
        self.assertNotIn("libz.so.1", refs)

    def test_sibling_shared_object_detection(self) -> None:
        (self.sysroot / "usr/lib/libfoo.a").write_text("ar")
        (self.sysroot / "usr/lib/libfoo.so.1").write_text("elf")
        (self.sysroot / "usr/lib/libbar.a").write_text("ar")
        self.assertTrue(prune_mod.has_sibling_shared_object(str(self.sysroot / "usr/lib/libfoo.a")))
        self.assertFalse(prune_mod.has_sibling_shared_object(str(self.sysroot / "usr/lib/libbar.a")))


class PruneIntegrationTest(unittest.TestCase):
    """整体跑一遍脚本，检查删除结果与完整性校验。"""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "toolchain"
        sysroot = self.root / TRIPLET / "sysroot"
        for path in ("usr/lib", "usr/include", "usr/share/pkgconfig", "usr/share/kodi", "usr/bin", "usr/lib/kodi"):
            (sysroot / path).mkdir(parents=True)

        # 编译器本体 / host 侧库：prune 绝对不能碰
        (self.root / "bin").mkdir()
        (self.root / "bin" / f"{TRIPLET}-gcc-13.2.0").write_text("gcc")
        (self.root / "x86_64-linux-gnu" / TRIPLET / "lib").mkdir(parents=True)
        (self.root / "x86_64-linux-gnu" / TRIPLET / "lib" / "libbfd-2.41.so").write_text("bfd")

        # glibc 那套：libc.so 是链接脚本，引用 libc_nonshared.a
        (sysroot / "usr/lib/libc.so.6").write_text("elf")
        (sysroot / "usr/lib/libc_nonshared.a").write_text("ar")
        (sysroot / "usr/lib/libc.a").write_text("ar")           # 有同名 libc.so（脚本）→ 可删
        (sysroot / "usr/lib/libc.so").write_text(
            "/* GNU ld script */\nGROUP ( /usr/lib/libc.so.6 /usr/lib/libc_nonshared.a )\n"
        )
        # 有同名动态库的静态库 → 可删
        (sysroot / "usr/lib/libfoo.a").write_text("ar")
        (sysroot / "usr/lib/libfoo.so.1").write_text("elf")
        # 没有同名动态库的静态库 → 必须留
        (sysroot / "usr/lib/libbar.a").write_text("ar")
        # 黑名单 glob
        (sysroot / "usr/lib/libpython3.11.so.1.0").write_text("big")
        (sysroot / "usr/lib/libdovi.a").write_text("big")
        # 必须保留的编译所需内容
        (sysroot / "usr/include/stdio.h").write_text("h")
        (sysroot / "usr/share/pkgconfig/gstreamer-1.0.pc").write_text("pc")
        # 黑名单目录
        (sysroot / "usr/share/kodi/kodi.bin").write_text("kodi")
        (sysroot / "usr/bin/Xorg").write_text("xorg")
        (sysroot / "usr/lib/kodi/kodi.bin").write_text("kodi")

        self.sysroot = sysroot

    def run_prune(self, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "prune-lean.py"), str(self.root), "--triplet", TRIPLET, *extra],
            capture_output=True,
            text=True,
        )

    def test_prune_removes_blacklist_and_safe_archives(self) -> None:
        result = self.run_prune()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

        # 链接脚本引用的 .a 必须留下 —— 这是最容易踩的坑
        self.assertTrue((self.sysroot / "usr/lib/libc_nonshared.a").exists(), "libc_nonshared.a 被误删")
        # 有同名 .so 的 .a 删掉；没有同名 .so 的留下
        self.assertFalse((self.sysroot / "usr/lib/libfoo.a").exists())
        self.assertFalse((self.sysroot / "usr/lib/libc.a").exists())
        self.assertTrue((self.sysroot / "usr/lib/libbar.a").exists())
        # 黑名单
        self.assertFalse((self.sysroot / "usr/share/kodi").exists())
        self.assertFalse((self.sysroot / "usr/bin").exists())
        self.assertFalse((self.sysroot / "usr/lib/kodi").exists())
        self.assertFalse((self.sysroot / "usr/lib/libpython3.11.so.1.0").exists())
        self.assertFalse((self.sysroot / "usr/lib/libdovi.a").exists())
        # 必须保留
        self.assertTrue((self.sysroot / "usr/lib/libc.so.6").exists())
        self.assertTrue((self.sysroot / "usr/include/stdio.h").exists())
        self.assertTrue((self.sysroot / "usr/share/pkgconfig/gstreamer-1.0.pc").exists())
        # 编译器本体与 host 侧库不受影响
        self.assertTrue((self.root / "bin" / f"{TRIPLET}-gcc-13.2.0").exists())
        self.assertTrue((self.root / "x86_64-linux-gnu" / TRIPLET / "lib" / "libbfd-2.41.so").exists())

        # 报告里应当出现总量与静态库统计
        self.assertIn("精简前", result.stdout)
        self.assertIn("静态库", result.stdout)

    def test_dry_run_deletes_nothing(self) -> None:
        result = self.run_prune("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue((self.sysroot / "usr/share/kodi").exists())
        self.assertTrue((self.sysroot / "usr/lib/libfoo.a").exists())
        self.assertIn("dry-run", result.stdout)

    def test_missing_required_content_fails(self) -> None:
        # 少了 usr/include 的 sysroot 属于不可用，必须报错而不是悄悄出包
        import shutil

        shutil.rmtree(self.sysroot / "usr/include")
        result = self.run_prune()
        self.assertEqual(result.returncode, 1)
        self.assertIn("不要发布", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
