# gs_packager

给 Amlogic 地面端项目做 **可复现交叉编译** 的共享基础设施。

解决的问题：`AMLgsMenu` / `AMLDigitalFPV` 都依赖 CoreELEC 的交叉工具链
（`armv8a-libreelec-linux-gnueabihf-` + 含 GStreamer / libamcodec / GLES 的 sysroot）。
那套工具链是在容器里（`/home/docker/CoreELEC/...`）长出来的，**不能直接打包给 CI 用**：

| 坑 | 现象 | 本仓库的处理 |
| --- | --- | --- |
| `bin/<triplet>-gcc` 是 ccache 包装脚本，写死容器内绝对路径 | `ccache: not found` | `env.sh` / `toolchain.cmake` 自动改用真实的 `-gcc-<ver>` 二进制 |
| `as` / `ld` 需要 host 侧 `libbfd-2.41.so` | `error while loading shared libraries: libbfd-2.41.so` | 自动设置 `LD_LIBRARY_PATH=<toolchain>/x86_64-linux-gnu/<triplet>/lib` |
| sysroot 内有数百个指向 `/home/docker/...` 的绝对符号链接 | `libm.so.6, needed by libstdc++.so, not found`、`cannot find -lglib-2.0` | `scripts/relativize-symlinks.py` 改写成相对链接，整棵树可搬迁 |
| 链接期不解析 sysroot 内的 `DT_NEEDED` | 同上（`-lm` 之类解析不到） | 加 `-Wl,-rpath-link,<sysroot>/usr/lib` |
| 全量工具链 3.6 GB | 不适合当 CI 依赖 | 裁剪到只留两个项目所需，实测 **895 MB / tar.zst 223 MB** |

## 目录

```
env.sh                              直接 source 即可用的编译环境（参数化，无写死路径）
toolchain.cmake                     通用 CMake 工具链文件
scripts/make-snapshot.sh            生成可搬迁快照（裁剪 + 修链接 + 打包 + 自检）
scripts/relativize-symlinks.py      绝对符号链接 → 相对链接
scripts/verify-snapshot.sh          用快照真编译两个项目，验证快照可用
tests/                              假工具链 fixture + 链接修复的单元测试
.github/actions/setup-aml-toolchain 复合 action：下载/缓存快照并导出环境
.github/workflows/build-project.yml 可复用 workflow：编译一个项目
.github/workflows/build.yml         一键编译 AMLgsMenu + AMLDigitalFPV
.github/workflows/snapshot.yml      手动：生成并发布工具链快照
.github/workflows/ci.yml            本仓库自检
examples/                           项目仓库侧接的示例 workflow
```

## 用法

### 1. 生成快照（在能访问 CoreELEC 工具链的机器 / 容器里跑一次）

```bash
TOOLCHAIN_DIR=/path/to/coreelec/build.CoreELEC-Amlogic-ng.arm-21/toolchain \
  scripts/make-snapshot.sh --out snapshots
```

产物：`snapshots/aml-toolchain-armv8a-libreelec-linux-gnueabihf.tar.zst` + `.sha256` + `SHA256SUMS` + `snapshot-info.txt`。
脚本自带冒烟编译（用快照里的 gcc 编译一个 ARM 小程序），快照自身不可用时会直接失败，不会推坏包。

也可以用 workflow：`Actions → snapshot → Run workflow`（见 `.github/workflows/snapshot.yml`，支持在 CoreELEC 容器里跑）。

### 2. 发布快照

把 `*.tar.zst` 和 `SHA256SUMS` 作为 release asset 上传（tag 随意，例如 `toolchain-2026.09`）。
`setup-aml-toolchain` 默认从 **latest release** 拉取，因此发布后所有项目仓库即可直接使用。

> ⚠️ 快照内含 `libGLESv2.so`、`libEGL.so`、`libamcodec.so` 等 Amlogic 专有二进制。
> 如果本仓库是公开仓库，请不要把快照发到公开 release，改用私有 release / 私有 OCI registry，
> 并在调用时传 `toolchain-url` + `toolchain-token`。

### 3. 编译两个项目

```bash
scripts/verify-snapshot.sh \
  --snapshot snapshots/aml-toolchain-armv8a-libreelec-linux-gnueabihf.tar.zst \
  --projects-dir ~/projects          # 目录下需有 AMLgsMenu/ 与 AMLDigitalFPV/
```

CI 侧：`.github/workflows/build.yml` 直接编译 `imagemlt/AMLgsMenu` 与 `imagemlt/AMLDigitalFPV`，
产物以 artifact 形式上传；项目仓库也可以用 `build-project.yml` 作为可复用 workflow 自行调用。

## 实测数据（2026-09，GCC 13.2.0 / binutils 2.41）

| 版本 | 解压后 | tar.zst(-19) | tar.gz(-9) |
| --- | --- | --- | --- |
| 全量工具链 | 3.6 GB | 671 MB | — |
| 仅本项目所需（默认） | 1.3 GB | 317 MB | 428 MB |
| `--minimal`（默认开启，去掉 gold/dwp/lto-dump/静态 libpython） | 895 MB | **223 MB** | — |

编译耗时（12 核）：AMLgsMenu ≈ 13 s，AMLDigitalFPV ≈ 4.5 s。

## 注意事项

- **`liblto_plugin.so` 必须保留**（约 100 KB）。GCC 默认启用 `-fuse-linker-plugin`，
  删掉后所有链接都会失败：`fatal error: '-fuse-linker-plugin', but liblto_plugin.so not found`。
- `--minimal` 会删掉 `lto1`，因此**不适合 LTO 构建**；如需 `-flto` 请用 `--no-minimal`。
- 快照的编译器默认参数为 `armv8-a` + hard-float，与设备端一致；如需与 CoreELEC 完全对齐，
  可在项目侧把 CoreELEC 的 `TARGET_CFLAGS` 通过 `-DCMAKE_C_FLAGS=...` 传进去。
- 快照只是构建环境；**真机运行仍需自行验证**。
