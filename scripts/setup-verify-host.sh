#!/usr/bin/env bash
# 准备静态校验 / aarch64 用户态模拟所需工具（仅 Debian/Ubuntu，需要 root）。
# 注意：本脚本不负责创建 KVM 虚拟机；KVM 虚拟机创建见 docs/04-KVM验证方案.md。
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "此脚本仅支持 Debian/Ubuntu，当前系统: ${ID:-unknown}" ;;
    esac
fi

info "安装校验工具: device-tree-compiler, file, binutils, qemu-user-static, binfmt-support"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    device-tree-compiler \
    file \
    binutils \
    fdisk \
    parted \
    qemu-user-static \
    binfmt-support

# 部分系统需要手动注册 binfmt_misc，使 aarch64 程序可透明运行
if [[ -d /proc/sys/fs/binfmt_misc ]] && [[ -f /usr/bin/qemu-aarch64-static ]]; then
    if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
        mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    fi
    if [[ -f /proc/sys/fs/binfmt_misc/register ]]; then
        echo ':aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:' \
            > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
    fi
fi

info "已安装工具:"
for c in dtc fdtdump file readelf objdump qemu-aarch64-static; do
    printf '  %-24s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo MISSING)"
done
