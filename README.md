# gs_packager

给 Amlogic 地面端项目做 **可复现交叉编译** 的共享基础设施。

## 这个仓库是什么（定位）

**是**：`AMLgsMenu` / `AMLDigitalFPV` 的**编译基础设施** —— 交叉工具链快照的生成/校验/发布/消费，
加上两个项目共用的 CI workflow（`.github/workflows/build-project.yml`）。

**不是**：更新包（固件包）生成器。那是另一条线（在独立的 `upgradePackGen` 项目里，目前只有设计稿，未实现）——两者只是都属于“给地面端做交付”。

仓库名 `gs_packager` 是历史原因，和“打包”无关。如果你希望名字与用途一致，可选做法：把本仓库改名为
`build-infra`，或把工具链快照拆到单独的 `aml-toolchain` 仓库 —— 搬运成本很低，因为快照地址已经参数化
（`toolchain-owner` / `toolchain-url` / `toolchain-token` 都是 setup action 的输入项）。当前选择是**不改名**，只在此说明。

### 为什么 release 里放的是工具链快照

因为编译必须用 CoreELEC 那套交叉工具链（含 GStreamer / libamcodec / GLES 的 sysroot），而它是
**约 900 MB 的二进制集合**，git 托管不了：

| 通道 | 限制 | 结论 |
| --- | --- | --- |
| 仓库内的文件 | GitHub 硬限单文件 **100 MB**（超 50 MB 就告警） | 放不进去 |
| Git LFS | 免费额度 1 GB/月存储 + 1 GB/月流量，而 CI 每次构建都要下 219 MB | 跑几次就烧穿，**所有构建一起挂** |
| **release asset** | 单文件上限 2 GB | ✅ 唯一可行，且能按 sha256 长期缓存 |

所以 `releases/latest` 下挂的是工具链快照（由 `setup-aml-toolchain` 消费），仓库的 **tag 演的是工具链版本**，
不是本仓库的代码版本。想避免这种语义错位，可改用 ghcr.io 镜像层托管（需把 setup action 改成拉镜像）。

`releases/latest` 的另一个含义：**每发一个新快照，所有项目仓库就自动用新的**（因为默认从 latest 拉）。
如果不希望这种“静默升级”，可在项目侧固定 `toolchain-sha256`。

## 解决的问题

那套工具链：`armv8a-libreelec-linux-gnueabihf-`，外加含 GStreamer / libamcodec / GLES 的 sysroot。
它是在容器里（`/home/docker/CoreELEC/...`）长出来的，**不能直接打包给 CI 用**：
那套工具链是在容器里（`/home/docker/CoreELEC/...`）长出来的，**不能直接打包给 CI 用**：

| 坑 | 现象 | 本仓库的处理 |
| --- | --- | --- |
| `bin/<triplet>-gcc` 是 ccache 包装脚本，写死容器内绝对路径 | `ccache: not found` | `env.sh` / `toolchain.cmake` 自动改用真实的 `-gcc-<ver>` 二进制 |
| `as` / `ld` 需要 host 侧 `libbfd-2.41.so` | `error while loading shared libraries: libbfd-2.41.so` | 自动设置 `LD_LIBRARY_PATH=<toolchain>/x86_64-linux-gnu/<triplet>/lib` |
| `as` / `ld` 还依赖**构建机系统库**：`libsframe.so.1` / `libbfd-2.42-system.so` / `libctf.so.0` | Ubuntu 22.04 runner 上 `as ... cannot open shared object file`，报在 CMake 编译器测试里很难定位 | **runner 用 `ubuntu-24.04`**（24.04 才自带这些库）；setup action 增加预检步骤提前报错 |
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
tests/cleanroom-toolchain-test.sh 干净容器验证：这个快照能在哪个 runner 镜像上跑
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

把 `*.tar.zst` 和 `SHA256SUMS` 作为 release asset 上传（tag 任意，例如 `toolchain-2026.09`）。
`setup-aml-toolchain` 默认从 **latest release** 拉取，发布后所有项目仓库即可直接使用。

三种发布方式：

```bash
# a) 一条命令（需要 contents:write 的 PAT）
GH_TOKEN=github_pat_xxx scripts/publish-release.sh --tag toolchain-2026.09

# b) 装了 gh 的话
gh release create toolchain-2026.09 snapshots/*.tar.zst snapshots/SHA256SUMS snapshots/snapshot-info.txt

# c) 网页：新建 release，把 snapshots/ 里的文件拖进去
```

> 快照内含 `libEGL.so`、`libGLESv2.so`、`libamcodec.so` 这三个 Amlogic 供应商二进制（共约 68 MB），
> 其余部分为 gcc/binutils/glibc 与 CoreELEC 开源库。若要把快照放公开 release，属于再分发行为，
> 由仓库所有者判断；若不想公开发，可改发到私有 release 并传 `toolchain-url` + `toolchain-token`，
> 或参考上文拆包思路（公开 base + 私有 vendor）。

### 运行环境要求

| 项 | 要求 | 原因 |
| --- | --- | --- |
| runner 镜像 | **ubuntu-24.04 或更新** | 快照里的 `as`/`ld` 是 host 侧程序，依赖系统库 `libsframe.so.1` / `libbfd-2.42-system.so` / `libctf.so.0`，只有 24.04+ 自带（22.04 是 binutils 2.38） |
| 磁盘 | 解压后约 900 MB | 快照解压体积 |
| 网络 | 能访问本仓库 release | 首次拉快照（之后按 sha256 命中 cache） |

想确认某个镜像行不行，不用跑完整构建，用干净容器测试即可：

```bash
# 解一份快照出来，然后在只装了 build-essential 的容器里真编译 C/C++
zstd -d -c snapshots/aml-toolchain-*.tar.zst | tar -xf - -C /tmp/tc
tests/cleanroom-toolchain-test.sh /tmp/tc ubuntu:24.04 ubuntu:22.04
```

实测结果：`ubuntu:24.04` 全部通过；`ubuntu:22.04` 在第一步 `as --version` 就失败。
`snapshot.yml` 已把这一步接成发布前的固定关卡（runner 上有 docker 时生效）。

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
