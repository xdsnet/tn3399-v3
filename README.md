# TN3399_V3 定制 Armbian 固件（RK3399 / Vendor 6.1 + MPP）

本项目为天诺 TN3399_V3 主板（RK3399、4GB DDR3、16GB eMMC、RTL8211E、AP6255、JMS578 USB3-SATA、HDMI 2.0）生成一份可复现的定制刷机镜像。

## 技术路线（结论）

| 组件 | 选型 | 原因 |
|---|---|---|
| 根文件系统 | Armbian 26.8.1 trixie minimal（NanoPi M4v2 / RK3399 基础镜像） | Armbian 官方仍提供 RK3399 minimal 镜像，作为 rootfs 基线可靠；本项目替换其中的 U-Boot / 内核 / DTB |
| U-Boot | 主线 v2026.01 + retro98boy 的 `tn3399-v3-rk3399_defconfig` 和 binman 板级补丁 | 主线 SPL/TPL + rkbin DDR/BL31，支持 eMMC/SD，DTB 名一致 |
| 内核 | `armbian/linux-rockchip` `rk-6.1-rkr7.2`（Rockchip vendor 6.1） | 官方 6.x BSP 分支，含 `drivers/video/rockchip/mpp`、rkvdec/vdpu/vepu、Rockchip dma-heap；MPP 官方明确支持 6.1 |
| 设备树 | `rk3399-tn3399-v3.dts` → `rk3399-tn3399-v3.dtb`，compatible = `tiannuo,tn3399-v3` | 正确板级身份；包含 `rk3399-linux.dtsi`，自动启用 `mpp_srv`/`rkvdec`/`vdpu`/`vepu`；比“把 rock960 改名”更准确 |
| 多媒体 | vendor MPP 驱动 + `rockchip-linux/mpp` 用户态库 | 硬件编解码完整路径；主线 6.18 配置使用 Panfrost，不含 Rockchip MPP service |
| WiFi/BT | AP6255（BCM43455）用 vendor `bcmdhd` + `nvram_ap6255.txt`；蓝牙用 `hci_uart` BCM + `BCM4345C0.hcd` | 与 BSP DTS 的 `wireless-wlan` / `wireless-bluetooth` platdata 节点一致，避免和 brcmfmac 争用 SDIO |
| 音频 | ALC5640 + NS4258，安装 retro98boy 的 ALSA UCM 配置 | 扬声器/HDMI 音频开箱可用 |

> 重要：Armbian 当前 `rockchip64` 家族的 `current` 分支已是主线 **6.18**，不再提供 vendor 6.x 板级分支；因此本项目以 Armbian 镜像为 rootfs 基线，单独构建 vendor 6.1 内核。

## 目录结构

```text
/datas/codes/tn3399/
├── Makefile                    # 一键构建入口
├── config/
│   ├── project.env             # 固定版本与路径（make 与 shell 共用）
│   ├── project.mk
│   ├── kernel/
│   │   ├── rk3399-tn3399-v3.dts          # BSP 版板级 DTS（MPP 节点完整）
│   │   ├── rk3399-tn3399-v3-mainline.dts # 主线 6.18 备选 DTS
│   │   └── tn3399-v3.config              # WiFi/BT/PHY/UAS/MPP 补充内核选项
│   ├── rootfs/
│   │   ├── tn3399-firstboot-resize          # 首次启动根分区扩容脚本
│   │   ├── tn3399-firstboot-resize.service
│   │   ├── tn3399-firstboot-setup           # 首次启动交互式初始化脚本
│   │   └── tn3399-firstboot-setup.service
│   └── u-boot/
│       └── 0001-add-tn3399-v3.patch      # U-Boot v2026.01 板级补丁
├── scripts/                    # fetch / uboot / kernel / mpp / image / verify / kvm-vm 等
├── docs/                       # 调研、构建刷机、验证、KVM、版本跟踪、虚拟机构建
├── .gitignore                  # 排除所有可下载内容与构建产物
├── sources/                    # 【不入库】下载的源码与基础镜像（make fetch 生成）
├── output/                     # 【不入库】构建产物与最终镜像（make all 生成）
├── firmware/                   # 【不入库】AP6255 固件、USB loader、UCM（make fetch 生成）
└── .cache/                     # 【不入库】下载缓存与调试临时文件
```

> **Git 版本只跟踪可复现构建所需的源文件**（脚本 / 配置 / 板级 DTS 与补丁 / 文档）。`sources/`、`output/`、`firmware/`、`.cache/` 等均通过 `.gitignore` 排除，本地可保留以便复用，但不会提交到仓库。

## 快速开始

```bash
cd /datas/codes/tn3399
sudo apt install -y build-essential bison flex libssl-dev libncurses-dev bc \
                   device-tree-compiler git curl xz-utils cmake \
                   gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

make fetch        # 下载固定版本源码与基础镜像（默认走 gh-proxy 国内加速）
make uboot        # 生成 output/bootloader/u-boot-rockchip.bin
make kernel       # 生成 vendor 6.1 Image / dtb / modules
make mpp          # 生成 output/mpp（用户态 MPP 库与测试程序）
sudo make image   # 组装最终刷机镜像（需要 root）
make verify       # 校验 DTB、配置、产物
```

构建完成后可追加三层验证：

```bash
make verify-host          # 安装 dtc / qemu-user 等校验工具
make verify-artifacts     # DTB/Image/MPP/镜像结构深度检查
sudo make verify-rootfs   # qemu-aarch64-static chroot 冒烟验证 rootfs
make kvm-check            # 检查 KVM/QEMU/libvirt 环境
```

本机 KVM 环境实测：CPU 支持 VT-x，QEMU/libvirt 已安装，但当前会话中 `/dev/kvm` 不可见（自动回退 TCG）。若要在 x86_64 KVM 虚拟机内做隔离验证，见 [`docs/04-KVM验证方案.md`](docs/04-KVM验证方案.md)。

> 国内网络提示：`config/project.env` 中默认 `USE_GH_PROXY=1`、`GH_PROXY=https://gh-proxy.com`。源码下载使用 codeload tarball（非 `git clone`），固件 raw 文件也走代理（实测约 1.5 MB/s）。Armbian 基础镜像因 USTC/官方直连慢且 USTC 被 Anubis 拦截，实测用官方 `.torrent` 经 BT（aria2）下载最快（约 4.9 MB/s），下载流程见 `docs/02-构建与刷机.md`。

## 构建状态（已实测完成）

本项目已在 x86_64 KVM 虚拟机（Debian 13，4 核 / 6 GB 可用内存）内**完整构建并校验通过**：

| 产物 | 结果 |
|---|---|
| U-Boot | `u-boot-rockchip.bin`（9.1 MiB），DDR blob = 800MHz **v1.30**，BL31 = v1.36 |
| 内核 | `Image`（39 MiB，vendor 6.1.172），DTB 与模块（164 个 `.ko`）已生成 |
| DTB | `rk3399-tn3399-v3.dtb`（78 KiB），compatible = `tiannuo,tn3399-v3`，含 `mpp-srv`/`rkvdec` 节点 |
| MPP | 驱动（mpp_service/rkvdec/RGA）已编入内核 Image；用户态库与 `mpi_dec_test` 已构建 |
| 最终镜像 | `Armbian_TN3399_V3_vendor6.1_20261126.img`（1.7 GiB），U-Boot 已写入 32 KiB 偏移 |
| 校验 | `make verify` 与 `bash scripts/verify-artifacts.sh` 全部 `[OK]` |

> 构建依赖补充：U-Boot v2026.01 的 binman 需要 `swig`、`python3-setuptools`、`python3-pyelftools`、`libgnutls28-dev`、`python3-dev`，它们已加入 `docs/02` 的依赖清单。

详细说明见 [`docs/02-构建与刷机.md`](docs/02-构建与刷机.md)。

## DTB 匹配（本项目最容易出错的地方）

- U-Boot defconfig：`CONFIG_DEFAULT_DEVICE_TREE="rockchip/rk3399-tn3399-v3"`
- U-Boot 默认 FDT：`CONFIG_DEFAULT_FDT_FILE="rockchip/rk3399-tn3399-v3.dtb"`
- Armbian `armbianEnv.txt`：`fdtfile=rockchip/rk3399-tn3399-v3.dtb`
- 内核 DTB：`arch/arm64/boot/dts/rockchip/rk3399-tn3399-v3.dtb`
- rootfs：`/boot/dtb/rockchip/rk3399-tn3399-v3.dtb`

四者必须完全一致。`lanseyujie/tn3399_v3` 中把 `rk3399-rock960.dts` 当作板级设备树的做法可以作为早期参考，但会让内核认为自己是 Rock960，且缺少本板 DTS 中的 PMIC/音频/LED/风扇/AP6255 细节；本项目不使用该命名。

## 首次启动一次性初始化

最终镜像内置两个一次性服务，完成即自禁用；中途失败或中断不会写完成标记，下次启动会重试。

| 服务 | 触发阶段 | 作用 |
|---|---|---|
| `tn3399-firstboot-resize.service` | 早期启动（`basic.target.wants`） | 调用 Armbian `armbian-resize-filesystem`，把单一 ext4 根分区扩展到整盘并在线 `resize2fs` |
| `tn3399-firstboot-setup.service` | 首次成功进入多用户模式（`multi-user.target.wants`） | 交互式完成账号、镜像源、内核锁定与主机名配置 |

### 根分区自动扩容

- 日志：`/var/log/tn3399-firstboot-resize.log`
- 完成标记：`/var/lib/tn3399-firstboot-resize.done`
- 若内核无法在线刷新分区表，Armbian 脚本会写 `/var/run/resize2fs-reboot`；本服务保留启用状态，重启后再执行一次。
- 如需禁用：在 rootfs 放 `/root/.no_rootfs_resize` 后重新 `make image`，或启动后执行 `systemctl disable --now tn3399-firstboot-resize.service`。

### 交互式初始化

`tn3399-firstboot-setup.service` 会在 `target` 阶段接管 `ttyS2`（1500000），结束后自动恢复串口 getty。依次要求：

1. **强制设置 root 密码**（`passwd root`）。
2. **创建普通用户并设置密码**，加入 `sudo` 组（同时加入 `adm/cdrom/dip/plugdev`）。
3. **选择 APT 镜像源**：清华 TUNA / 中国科大 USTC / 上海交大 SJTU（教育网+公网，均已实测可达），或阿里云 / 华为云（公网）；每一项同时写入 Armbian 源、Debian 主源和 `trixie-security` 安全更新源。也可选择保留官方源。
4. **锁定定制内核**：对已安装的 `linux-image-current-rockchip64`、`linux-dtb-current-rockchip64`（及 headers，如存在）执行 `apt-mark hold`，防止 `apt upgrade` 覆盖 vendor 6.1 的 `/boot` 与模块。
5. **重命名主机**：更新 `/etc/hostname` 与 `/etc/hosts`。

状态与日志：

- `/var/log/tn3399-firstboot-setup.log`
- `/var/lib/tn3399-firstboot-setup.done`
- `/etc/tn3399-mirror.choice`（记录所选镜像）
- `/etc/tn3399-kernel-lock`（记录被 hold 的内核包）

相关文件在 `config/rootfs/`，安装与启用逻辑在 `scripts/assemble-image.sh`。`make verify` 与（root 权限下）`make verify-artifacts` 会校验两个服务的安装、启用、软链接目标及“未初始化”状态。

## 参考来源

- 官方 Rockchip BSP 内核：<https://github.com/rockchip-linux/kernel>（develop-6.1）
- Armbian vendor 内核分支：<https://github.com/armbian/linux-rockchip>（rk-6.1-rkr7.2）
- Armbian 构建框架：<https://github.com/armbian/build>
- MPP 与 6.1 支持说明：<https://github.com/rockchip-linux/mpp/blob/develop/doc/Rockchip_Developer_Guide_MPP_CN.md>
- TN3399_V3 折腾记录：<https://github.com/lanseyujie/tn3399_v3>
- TN3399_V3 主线/BSP DTS 与 U-Boot/固件：<https://github.com/retro98boy/tiannuo-tn3399-v3-linux>
- retro98boy 的 Armbian 板级配置：<https://github.com/retro98boy/armbian-build>
- Rockchip rkbin：<https://github.com/rockchip-linux/rkbin>

## 风险与已知限制

1. 完整构建需要约 20–25 GB 磁盘空间和可用的 aarch64 交叉工具链；本项目已在 Debian 13 KVM 虚拟机内完成一次完整构建，源码/镜像均从国内加速链路获取。
2. DDR3 初始化对 blob 敏感；本板 K4B8G16 DDR3 已默认使用 rkbin 自带的 `bin/rk33/rk3399_ddr_800MHz_v1.30.bin`（用户确认 800MHz 系列可用）。若仍卡在 DDR 阶段，可尝试 rkbin 中其他 800MHz 版本，修改 `config/project.env` 的 `DDR_BLOB` 后重建 U-Boot。
3. 串口必须使用 1500000 波特率；CH340G/PL2303HX 有只能读不能写的问题，建议 CP2104。
4. 板载 eMMC 16GB，基础镜像约 1.7 GiB；首次启动会自动扩容根分区到整盘，无需手动操作。
5. HDMI/LVDS 显示：本项目以 HDMI 为主要输出；LVDS 屏需额外应用 retro98boy 仓库中的 TC358775 面板补丁，本项目未默认启用。
6. 真机开机验证（DDR 初始化、串口、AP6255 扫描、HDMI、JMS578、VPU 硬解）仍必须在 TN3399_V3 板子上完成；KVM/静态校验无法替代。

## 鸣谢

本项目初始化完成借助 WorkBuddy，完全利用 Hy4-Flash 模型完成；人工只提出目标，并对部分走向进行了干预与确认。

同时感谢 Armbian、Rockchip、U-Boot、rockchip-linux/mpp 等上游项目，以及 retro98boy、lanseyujie 等 TN3399_V3 社区资料贡献者；本项目中的板级 DTS、U-Boot 补丁与固件参考了他们的公开工作。

## 开源协议

本项目仓库（脚本、配置、文档、DTS 与补丁）采用 **GPL-2.0-or-later** 协议，SPDX 标识为 `GPL-2.0-or-later`，许可证全文见 [`LICENSE`](LICENSE)。

选择理由：仓库中的 U-Boot 板级补丁派生自 GPL-2.0-or-later 的 U-Boot，内核 DTS 派生自 GPL-2.0 的 Rockchip/Armbian BSP；采用 GPL-2.0-or-later 可与这些上游代码兼容，并避免协议冲突。

> 说明：通过 `make fetch` 下载的上游源码、Armbian 基础镜像、Rockchip 二进制 blob 与固件，以及 `output/`、`sources/`、`firmware/` 下的构建产物不受本仓库协议约束，仍按其各自上游协议执行。

## 版本跟踪与更新

如何跟踪 Armbian vendor 内核新版本并安全升级配置/重建，见 [`docs/05-版本跟踪与更新.md`](docs/05-版本跟踪与更新.md)。

## 在虚拟机内构建（可选，脱敏/参数化）

若宿主机文件创建性能差或希望隔离构建环境，可把交叉编译放到 KVM 虚拟机内完成。该模式已参数化、脱敏：VM 名/IP/密钥路径全部来自被 gitignore 的 `config/vm.env`，仓库只保留模板。

```bash
cp config/vm.env.example config/vm.env   # 填写你的 VM 连接信息
make vm-check                            # 检查连接
make vm-all                              # VM 内构建并回拷产物
# 或分步：make vm-sync / make vm-run TARGET=kernel / make vm-pull
```

详见 [`docs/06-虚拟机构建.md`](docs/06-虚拟机构建.md)。
