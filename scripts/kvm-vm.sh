#!/usr/bin/env bash
# KVM 验证虚拟机辅助脚本。
# 作用：在 x86_64 KVM 虚拟机内建立一个隔离沙箱，用于检查构建成果（静态验证 + aarch64 用户态模拟）。
# 注意：本虚拟机**不能**启动我们为 RK3399 编译的内核，也不能直接刷写 eMMC 镜像。
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
    cat <<EOF
用法: bash scripts/kvm-vm.sh <子命令> [参数]

子命令:
  check                       检查 KVM/QEMU/libvirt 环境
  create <安装ISO> [虚拟机名]  创建并启动 x86_64 验证虚拟机（默认名 tn3399-verify）
  start  [虚拟机名]            启动已存在的验证虚拟机
  stop   [虚拟机名]            关闭验证虚拟机
  list                        列出 libvirt 虚拟机

说明:
  验证虚拟机建议安装 Debian 13，然后在其中运行:
    bash scripts/setup-verify-host.sh
    bash scripts/verify-artifacts.sh
    sudo bash scripts/verify-rootfs-qemu.sh <镜像路径>
EOF
}

KVM_OK=0
[[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] && KVM_OK=1
VIRT_TYPE="qemu"
[[ $KVM_OK -eq 1 ]] && VIRT_TYPE="kvm"

case "${1:-help}" in
    check)
        info "===== KVM 环境检查 ====="
        printf '  CPU 虚拟化标志: %s\n' "$(lscpu 2>/dev/null | grep -qi 'vmx\|svm' && echo 支持 || echo 未检测到)"
        printf '  /dev/kvm:        %s\n' "$([[ $KVM_OK -eq 1 ]] && echo 可用 || echo 不可用)"
        printf '  加速模式:        %s\n' "$([[ $KVM_OK -eq 1 ]] && echo 'KVM (硬件加速)' || echo 'TCG (纯模拟，较慢)')"
        for c in qemu-system-x86_64 qemu-img virsh virt-install; do
            printf '  %-22s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo MISSING)"
        done
        info "===== 已存在的 libvirt 虚拟机 ====="
        virsh list --all 2>&1 | sed 's/^/  /' || true
        ;;
    create)
        ISO="${2:-}"
        VMNAME="${3:-tn3399-verify}"
        [[ -n "$ISO" && -f "$ISO" ]] || die "请提供 Debian/Ubuntu 安装 ISO 路径。"
        require_cmd virt-install virsh qemu-img
        DISK="${OUTPUT_DIR}/${VMNAME}.qcow2"
        ensure_dir "$OUTPUT_DIR"
        [[ ! -e "$DISK" ]] || die "磁盘已存在: ${DISK}，请先删除或换名字。"
        info "创建验证虚拟机 ${VMNAME}（加速模式: ${VIRT_TYPE}）"
        virt-install \
            --name "$VMNAME" \
            --virt-type "$VIRT_TYPE" \
            --arch x86_64 \
            --vcpus 2 \
            --memory 4096 \
            --disk "path=${DISK},size=40,format=qcow2,bus=virtio" \
            --network network=default,model=virtio \
            --graphics vnc,listen=0.0.0.0 \
            --cdrom "$ISO" \
            --os-variant debian13 \
            --boot hd,cdrom \
            --noautoconsole
        info "虚拟机已启动。请用 virt-viewer 连接 ${VMNAME} 完成系统安装。"
        info "安装后把本项目（至少 output/ 与 scripts/）复制到虚拟机内，运行 docs/04-KVM验证方案.md 中的检查命令。"
        ;;
    start)
        VMNAME="${2:-tn3399-verify}"
        virsh start "$VMNAME"
        ;;
    stop)
        VMNAME="${2:-tn3399-verify}"
        virsh shutdown "$VMNAME"
        ;;
    list)
        virsh list --all
        ;;
    *)
        usage
        ;;
esac
