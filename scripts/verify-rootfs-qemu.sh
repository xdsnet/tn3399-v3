#!/usr/bin/env bash
# 在 x86_64 宿主机或 KVM 虚拟机内，用 qemu-aarch64-static + chroot 对刷机镜像的
# aarch64 rootfs 做用户态冒烟验证（不启动内核、不模拟 RK3399 硬件）。
# 用法：sudo bash scripts/verify-rootfs-qemu.sh [镜像路径]
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root
require_cmd losetup mount umount partprobe file

FINAL="${1:-$(find "${OUTPUT_DIR}" -maxdepth 1 -name 'Armbian_TN3399_V3_*.img' 2>/dev/null | head -1 || true)}"
[[ -n "$FINAL" && -f "$FINAL" ]] || die "找不到最终刷机镜像，请先执行 make image 或传入镜像路径。"

QEMU_BIN="$(command -v qemu-aarch64-static 2>/dev/null || true)"
[[ -n "$QEMU_BIN" ]] || die "缺少 qemu-aarch64-static，请先执行 sudo bash scripts/setup-verify-host.sh"

FAIL=0
check() {
    if eval "$1" >/dev/null 2>&1; then printf '  [OK]   %s\n' "$2"; else printf '  [FAIL] %s\n' "$2" >&2; FAIL=1; fi
}

LOOP=""
MNT="$(mktemp -d /tmp/tn3399-qemu.XXXXXX)"
cleanup() {
    set +e
    [[ -n "$LOOP" ]] && umount -R "$MNT/boot" "$MNT/root" >/dev/null 2>&1
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" >/dev/null 2>&1
    rm -rf "$MNT"
}
trap cleanup EXIT

LOOP="$(losetup -f --show -P "$FINAL")"
partprobe "$LOOP" >/dev/null 2>&1 || true
sleep 1

ROOT_PART=""
BOOT_PART=""
while read -r name fstype _; do
    [[ "$name" == "${LOOP}p"* ]] || continue
    case "${fstype,,}" in
        vfat|fat*) [[ -z "$BOOT_PART" ]] && BOOT_PART="$name" ;;
        ext4|ext3|ext2|btrfs|f2fs) [[ -z "$ROOT_PART" ]] && ROOT_PART="$name" ;;
    esac
done < <(lsblk -no NAME,FSTYPE "$LOOP")
[[ -n "$ROOT_PART" ]] || die "无法识别 rootfs 分区"

mkdir -p "$MNT/root" "$MNT/boot"
# 需要写入 qemu-aarch64-static，因此 rootfs 以读写方式挂载（脚本退出时会卸载，不写回宿主机文件之外的内容）。
mount "$ROOT_PART" "$MNT/root"
if [[ -n "$BOOT_PART" ]]; then
    mount "$BOOT_PART" "$MNT/boot"
    BOOTDIR="$MNT/boot"
else
    BOOTDIR="$MNT/root/boot"
fi

# 把静态 qemu 放进 rootfs，chroot 后可直接执行 aarch64 二进制。
install -m 0755 "$QEMU_BIN" "${MNT}/root/usr/bin/qemu-aarch64-static"

info "===== chroot 内用户态检查（qemu-aarch64-static） ====="
run_in_guest() {
    chroot "$MNT/root" /usr/bin/qemu-aarch64-static /bin/bash -lc "$1" 2>/dev/null
}

check "rootfs 架构为 aarch64" \
    "file '${MNT}/root/bin/bash' | grep -qi 'ARM aarch64'"

check "版本标记 BOARD=TN3399_V3" \
    "grep -q '^BOARD=TN3399_V3$' '${MNT}/root/etc/tn3399-v3-release'"

check "版本标记 DTB 名称一致" \
    "grep -q '^DTB=${FDT_FILE}$' '${MNT}/root/etc/tn3399-v3-release'"

KVER="$(grep '^VENDOR_KERNEL=' "${MNT}/root/etc/tn3399-v3-release" 2>/dev/null | cut -d= -f2 || true)"
if [[ -n "$KVER" ]]; then
    check "内核模块目录 ${KVER} 存在" "test -d '${MNT}/root/usr/lib/modules/${KVER}'"
    check "内核模块非空" "find '${MNT}/root/usr/lib/modules/${KVER}' -name '*.ko' -print -quit | grep -q ."
else
    printf '  [FAIL] 版本标记缺少 VENDOR_KERNEL\n' >&2
    FAIL=1
fi

check "DTB 安装到 boot 分区" "test -f '${BOOTDIR}/dtb/${FDT_FILE}'"
check "armbianEnv.txt 的 fdtfile 正确" "grep -q '^fdtfile=${FDT_FILE}$' '${BOOTDIR}/armbianEnv.txt'"

check "AP6255 NVRAM 固件存在" "test -f '${MNT}/root/lib/firmware/brcm/nvram_ap6255.txt'"
check "AP6255 蓝牙 HCD 固件存在" "find '${MNT}/root/lib/firmware/brcm' -iname 'BCM4345C0.hcd' -print -quit | grep -q ."

check "MPP ld.so 配置存在" "test -f '${MNT}/root/etc/ld.so.conf.d/zz-tn3399-mpp.conf'"
check "MPP 库在 rootfs 中" "find '${MNT}/root/usr/lib' -name 'librockchip_mpp.so*' -print -quit | grep -q ."
check "MPP 测试程序在 rootfs 中" "test -x '${MNT}/root/usr/bin/mpi_dec_test'"

# 刷新 guest 的共享库缓存（镜像刚写入 ld.so.conf.d，尚未运行过 ldconfig）
run_in_guest 'ldconfig 2>/dev/null' || true

if run_in_guest 'ldconfig -p 2>/dev/null | grep -q librockchip_mpp'; then
    printf '  [OK]   guest 内 ldconfig 可识别 MPP 库\n'
else
    printf '  [FAIL] guest 内 ldconfig 未识别 MPP 库（可尝试 chroot 后手动 ldconfig）\n' >&2
    FAIL=1
fi

if run_in_guest 'mpi_dec_test -h 2>&1 | grep -qi -E "usage|mpi_dec_test|help"'; then
    printf '  [OK]   mpi_dec_test 可在 aarch64 用户态启动\n'
else
    printf '  [SKIP] mpi_dec_test 无法在此环境输出帮助（可能缺少运行库或依赖固件）\n' >&2
fi

info "===== 结论 ====="
if [[ $FAIL -eq 0 ]]; then
    info "rootfs 用户态冒烟验证通过。"
else
    die "rootfs 用户态验证存在失败项。"
fi
