# KVM 虚拟机验证方案

## 先说清楚能验证什么

x86_64 KVM 虚拟机**不能**启动本项目为 RK3399 编译的 `Image`，也**不能**直接检验 eMMC/SPI 刷机偏移在真实板子上的行为（CPU 架构、设备树、DDR 初始化、PMIC、MIPI/HDMI 都不同）。但它可以承担三层有价值的检查：

| 层级 | 验证内容 | 是否需要 KVM 虚拟机 |
|---|---|---|
| L1 静态配置 | DTS compatible、内核 config、U-Boot defconfig、DTB 名称一致性 | 否，宿主机即可 |
| L2 产物结构 | DTB 可反编译与关键节点、Image 架构、MPP 库、镜像分区表与 U-Boot 偏移 | 推荐在虚拟机内做（隔离、可快照） |
| L3 rootfs 用户态 | 用 `qemu-aarch64-static + chroot` 运行 aarch64 用户程序，检查固件、模块、MPP 动态库 | 推荐在虚拟机内做 |

真正开机验证仍需在 TN3399_V3 板子上完成，见 `docs/03-验证清单.md`。

## 本机环境实测

| 项目 | 结果 |
|---|---|
| CPU | Intel i7-6700，支持 VT-x（vmx） |
| QEMU | 10.0.13（`qemu-system-x86_64` / `qemu-system-aarch64` / `qemu-img`） |
| libvirt | 11.3.0，已有多个虚拟机在运行 |
| `/dev/kvm` | **当前会话不可见**（宿主内核已加载 `kvm`/`kvm_intel`，但设备节点未映射到本会话） |
| 缺失工具 | `dtc`、`fdtdump`、aarch64 交叉工具链、`qemu-aarch64-static` |

因此：`kvm-check` 会报告当前会话为 TCG 模式；若要在硬件加速模式下创建虚拟机，请在能访问 `/dev/kvm` 的宿主机终端执行（或把 `/dev/kvm` 映射进容器）。

## 快速路径：宿主机直接校验（无需虚拟机）

```bash
cd /datas/codes/tn3399
make verify-host          # 安装 dtc / file / binutils / qemu-user-static
make verify               # L1 静态配置校验
make verify-artifacts     # L2 产物结构校验（构建完成后）
sudo make verify-rootfs   # L3 rootfs 用户态冒烟（镜像生成后）
```

## 完整路径：KVM 虚拟机内校验

### 1. 检查环境并创建虚拟机

```bash
cd /datas/codes/tn3399
make kvm-check
make kvm-create ISO=/path/to/debian-13.iso VM=tn3399-verify
```

脚本会根据 `/dev/kvm` 是否可用自动选择 KVM 硬件加速或 TCG 纯模拟。随后用 `virt-viewer` 连接虚拟机完成 Debian 安装。

### 2. 把构建成果放入虚拟机

任选其一：

- **SCP**：在虚拟机内启动 sshd，从宿主机执行 `scp -r output scripts config root@<vm-ip>:~/tn3399/`
- **ISO 数据盘**：`genisoimage -o tn3399-output.iso output/`，在虚拟机内 `mount /dev/sr0 /mnt`
- **libvirt 文件系统直通**：`virsh attach-device`，把宿主机 `/datas/codes/tn3399/output` 挂为 virtiofs/9p

### 3. 在虚拟机内运行检查

```bash
cd ~/tn3399
bash scripts/setup-verify-host.sh
bash scripts/verify.sh
bash scripts/verify-artifacts.sh
sudo bash scripts/verify-rootfs-qemu.sh output/Armbian_TN3399_V3_vendor6.1_*.img
```

### 4. （可选）把虚拟机当作隔离构建沙箱

虚拟机内安装交叉工具链后，可把整个项目复制进去，从 `make fetch` 开始完整重建：

```bash
sudo apt install -y gcc-aarch64-linux-gnu build-essential bc bison flex libssl-dev \
    libncurses-dev device-tree-compiler xz-utils curl git
make all
```

好处是构建过程可快照、可回滚，不污染宿主机；缺点是磁盘与时间开销更大。

## 预期结果

- `make verify`：静态配置全部 `[OK]`
- `make verify-artifacts`：构建完成后 DTB 反编译、Image 架构、MPP 库、镜像偏移全部 `[OK]`；未构建的项目显示 `[SKIP]` 而非失败
- `sudo make verify-rootfs`：镜像生成后 rootfs 内版本标记、DTB、固件、模块、MPP 库与 `mpi_dec_test` 启动检查通过

## 关键限制

1. `qemu-system-aarch64` 即使有 KVM 也不能加速 ARM64 guest（宿主机是 x86_64），且 QEMU 没有 RK3399 machine model，不能替代真机启动。
2. `qemu-aarch64-static` 只做用户态指令翻译，`uname`、驱动探测、DMA、VPU 编解码等硬件行为无法验证。
3. 刷机偏移、DDR 初始化、串口 1500000、AP6255 实际扫描、HDMI 输出必须在 TN3399_V3 板子上确认。
