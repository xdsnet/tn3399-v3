include config/project.mk

export CROSS_COMPILE BAUDRATE CONSOLE DTB_NAME FDT_FILE
export ARMBIAN_BASE_URL ARMBIAN_BASE_SHA UBOOT_REPO UBOOT_REF UBOOT_COMMIT
export RKBIN_REPO RKBIN_COMMIT KERNEL_REPO KERNEL_REF KERNEL_COMMIT
export MPP_REPO MPP_REF MPP_COMMIT DDR_BLOB BL31_BLOB USB_LOADER TN3399_FIRMWARE_BASE

SHELL := /bin/bash
# 已是 root 时跳过 sudo（部分容器环境中 sudo 不可用）；普通用户仍通过 sudo 提权。
SUDO := $(shell test "$$(id -u)" -eq 0 || echo sudo)

.PHONY: all fetch uboot kernel mpp image verify verify-host verify-artifacts verify-rootfs kvm-check kvm-create vm-check vm-sync vm-run vm-pull vm-all clean help

all: fetch uboot kernel mpp image verify

fetch:
	bash scripts/fetch-sources.sh

uboot:
	bash scripts/build-uboot.sh

kernel:
	bash scripts/build-kernel.sh

mpp:
	bash scripts/build-mpp.sh

image:
	$(SUDO) bash scripts/assemble-image.sh

verify:
	bash scripts/verify.sh

verify-host:
	$(SUDO) bash scripts/setup-verify-host.sh

verify-artifacts:
	bash scripts/verify-artifacts.sh

verify-rootfs:
	$(SUDO) bash scripts/verify-rootfs-qemu.sh

kvm-check:
	bash scripts/kvm-vm.sh check

kvm-create:
	@test -n "$(ISO)" || { echo "用法: make kvm-create ISO=/path/to/debian.iso [VM=tn3399-verify]"; exit 1; }
	bash scripts/kvm-vm.sh create "$(ISO)" "$(or $(VM),tn3399-verify)"

# ---- 在 KVM 虚拟机内构建（脱敏/参数化；配置见 config/vm.env.example）----
vm-check:
	bash scripts/build-in-vm.sh check

vm-sync:
	bash scripts/build-in-vm.sh sync

# 用法: make vm-run TARGET=kernel   或   make vm-run TARGET="kernel mpp"
vm-run:
	@test -n "$(TARGET)" || { echo "用法: make vm-run TARGET=kernel  （或 TARGET='kernel mpp'）"; exit 1; }
	bash scripts/build-in-vm.sh run $(TARGET)

vm-pull:
	bash scripts/build-in-vm.sh pull

vm-all:
	bash scripts/build-in-vm.sh all

clean:
	rm -rf output/*
	rm -f sources/u-boot/.tn3399-patched

help:
	@printf '%s\n' \
	  'TN3399_V3 定制固件构建' \
	  '' \
	  '  make fetch   下载固定版本的源码、Armbian 基础镜像、固件' \
	  '  make uboot   构建主线 U-Boot v2026.01（TN3399_V3 补丁 + binman）' \
	  '  make kernel  构建 Rockchip vendor 6.1 内核（MPP + BSP DTB）' \
	  '  make mpp     交叉编译 rockchip-linux/mpp' \
	  '  make image   组装最终刷机镜像（含首次启动扩容与初始化，需要 root）' \
	  '  make verify           离线校验 DTB/配置/产物' \
	  '  make verify-host      安装静态校验与 qemu-user 工具（需 sudo）' \
	  '  make verify-artifacts 深度校验构建产物（file/dtc/readelf/dfdump）' \
	  '  make verify-rootfs    用 qemu-aarch64-static 冒烟验证 rootfs（需 sudo）' \
	  '  make kvm-check        检查本机 KVM/QEMU/libvirt 环境' \
	  '  make kvm-create ISO=… 创建 x86_64 KVM 验证虚拟机' \
	  '  make all              顺序执行构建与静态校验' \
	  '' \
	  '【在 KVM 虚拟机内构建，脱敏/参数化】先复制 config/vm.env.example -> config/vm.env 并填写：' \
	  '  make vm-check         检查 VM 连接与配置' \
	  '  make vm-sync          同步项目源文件到 VM' \
	  '  make vm-run TARGET=kernel  在 VM 内执行指定 make 目标' \
	  '  make vm-pull          回拷 VM 产物到宿主机 output/' \
	  '  make vm-all           VM 内一键构建并回拷' \
	  '' \
	  '提示：完整构建需要约 20-25 GB 磁盘空间与 aarch64 交叉工具链。' \
	  'KVM 虚拟机可用于隔离构建与验证成果，但不能启动 RK3399 内核或直接刷写板子镜像。'
