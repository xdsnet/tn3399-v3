#!/usr/bin/env bash
# 以 Armbian RK3399 镜像为根文件系统，替换为 TN3399_V3 的 U-Boot / 内核 / DTB / MPP / 固件，生成刷机镜像。
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root
require_cmd losetup mount umount partprobe cp dd sed xz depmod install

BASE_XZ="${SOURCES_DIR}/base/$(basename "$ARMBIAN_BASE_URL")"
BASE_IMG="${BASE_XZ%.xz}"
KVER="$(cat "${OUTPUT_DIR}/kernel-version.txt" 2>/dev/null || true)"
[[ -n "$KVER" ]] || die "未找到内核版本号，请先执行 make kernel"

[[ -f "${OUTPUT_DIR}/bootloader/u-boot-rockchip.bin" ]] || die "缺少 u-boot-rockchip.bin，请先执行 make uboot"
[[ -f "${OUTPUT_DIR}/kernel/Image" ]] || die "缺少内核 Image，请先执行 make kernel"
[[ -f "${OUTPUT_DIR}/kernel/${DTB_NAME}" ]] || die "缺少 ${DTB_NAME}，请先执行 make kernel"

if [[ ! -f "$BASE_IMG" ]]; then
    info "解压 Armbian 基础镜像: $BASE_XZ"
    xz -dk "$BASE_XZ"
fi

DATE_TAG="$(date -u +%Y%m%d)"
FINAL_IMG="${OUTPUT_DIR}/Armbian_TN3399_V3_vendor6.1_${DATE_TAG}.img"
info "生成最终镜像: $FINAL_IMG"
cp -f "$BASE_IMG" "$FINAL_IMG"

# 1. 写入 U-Boot（Armbian rockchip64 的 binman 写入方式：32 KiB 偏移）
dd if="${OUTPUT_DIR}/bootloader/u-boot-rockchip.bin" of="$FINAL_IMG" \
   bs=32k seek=1 conv=notrunc status=progress

LOOP=""
MNT="$(mktemp -d /tmp/tn3399-img.XXXXXX)"
cleanup() {
    set +e
    [[ -n "$LOOP" ]] && umount -R "$MNT/boot" "$MNT/root" >/dev/null 2>&1
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" >/dev/null 2>&1
    rm -rf "$MNT"
}
trap cleanup EXIT

LOOP="$(losetup -f --show -P "$FINAL_IMG")"
partprobe "$LOOP" || true
sleep 1

# 2. 识别 boot / root 分区
BOOT_PART=""
ROOT_PART=""
# 用 -p 输出绝对路径，避免 NAME 列带树形前缀（└─）导致路径判定失败。
# 再清理可能残留的树形字符，兼容不同 util-linux 版本。
while read -r name fstype label; do
    [[ -n "$name" ]] || continue
    name="${name//└─/}"; name="${name//├─/}"; name="${name//│/}"
    name="$(printf '%s' "$name" | tr -d ' ')"
    [[ "$name" == /* ]] || name="/dev/${name}"
    [[ -b "$name" ]] || continue
    case "${fstype,,}" in
        vfat|fat*) [[ -z "$BOOT_PART" ]] && BOOT_PART="$name" ;;
        ext4|ext3|ext2|btrfs|f2fs) [[ -z "$ROOT_PART" ]] && ROOT_PART="$name" ;;
    esac
done < <(lsblk -pn -o NAME,FSTYPE,LABEL "$LOOP")

[[ -n "$ROOT_PART" ]] || die "无法识别 rootfs 分区（请用 fdisk -l $FINAL_IMG 检查）"
info "boot=${BOOT_PART:-<内嵌于 rootfs>} root=${ROOT_PART}"

mkdir -p "$MNT/root" "$MNT/boot"
mount "$ROOT_PART" "$MNT/root"
if [[ -n "$BOOT_PART" ]]; then
    mount "$BOOT_PART" "$MNT/boot"
    BOOTDIR="$MNT/boot"
else
    BOOTDIR="$MNT/root/boot"
fi
ensure_dir "$BOOTDIR"

# 3. 安装内核、DTB、模块
info "安装内核 ${KVER}"
find "$BOOTDIR" -maxdepth 1 -type f \( -name 'vmlinuz-*' -o -name 'initrd.img-*' -o -name 'System.map-*' \) -delete
cp -f "${OUTPUT_DIR}/kernel/Image" "${BOOTDIR}/vmlinuz-${KVER}"
[[ -f "${OUTPUT_DIR}/kernel/System.map" ]] && cp -f "${OUTPUT_DIR}/kernel/System.map" "${BOOTDIR}/System.map-${KVER}"
ensure_dir "${BOOTDIR}/dtb/rockchip"
cp -f "${OUTPUT_DIR}/kernel/${DTB_NAME}" "${BOOTDIR}/dtb/rockchip/${DTB_NAME}"

rm -rf "${MNT}/root/usr/lib/modules/${KVER}"
mkdir -p "${MNT}/root/usr/lib/modules"
cp -a "${OUTPUT_DIR}/modules/lib/modules/${KVER}" "${MNT}/root/usr/lib/modules/"
# 删除旧内核模块目录，避免误加载 nanopim4v2 的 6.18 模块
for d in "${MNT}/root/usr/lib/modules"/*; do
    [[ "$(basename "$d")" == "$KVER" ]] || rm -rf "$d"
done
depmod -b "${MNT}/root/usr" "$KVER" || warn "depmod 失败，首次启动时请手动执行 depmod -a"

# 4. 安装 AP6255 固件与 ALSA UCM
info "安装 AP6255 固件 / UCM"
ensure_dir "${MNT}/root/lib/firmware/brcm"
cp -f "${FIRMWARE_DIR}"/brcm/* "${MNT}/root/lib/firmware/brcm/"
ensure_dir "${MNT}/root/usr/share/alsa/ucm2/conf.d/simple-card"
cp -f "${FIRMWARE_DIR}"/ucm/tn3399-v3*.conf "${MNT}/root/usr/share/alsa/ucm2/conf.d/simple-card/"

# 5. 安装 MPP 用户态库
if [[ -d "${OUTPUT_DIR}/mpp/usr" ]]; then
    info "安装 MPP 用户态库"
    cp -a "${OUTPUT_DIR}/mpp/usr/." "${MNT}/root/usr/"
    printf '/usr/lib/aarch64-linux-gnu\n' > "${MNT}/root/etc/ld.so.conf.d/zz-tn3399-mpp.conf"
    # 刷新镜像内的动态链接缓存，避免 MPP 程序首次启动提示找不到 librockchip_mpp.so
    chroot "${MNT}/root" /sbin/ldconfig 2>/dev/null || warn "ldconfig 失败，首次启动时请手动执行 ldconfig"
fi

# 6. 修改 Armbian 启动配置，确保 dtb 名完全匹配
ENV_FILE="${BOOTDIR}/armbianEnv.txt"
[[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"
set_env_key() {
    local key="$1" value="$2" file="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}
set_env_key "fdtfile" "$FDT_FILE" "$ENV_FILE"
set_env_key "console" "serial" "$ENV_FILE"
set_env_key "console_serial" "${CONSOLE},${BAUDRATE}" "$ENV_FILE"
set_env_key "overlay_prefix" "rockchip" "$ENV_FILE"

# 兼容部分镜像直接提供 extlinux.conf 的情况
EXTLINUX="${BOOTDIR}/extlinux/extlinux.conf"
if [[ -f "$EXTLINUX" ]]; then
    sed -i -E "s|^[[:space:]]*LINUX[[:space:]]+.*|    LINUX /vmlinuz-${KVER}|" "$EXTLINUX" || true
    sed -i -E "s|^[[:space:]]*FDT[[:space:]]+.*|    FDT /dtb/${FDT_FILE}|" "$EXTLINUX" || true
    sed -i -E "s|console=ttyS2,[0-9]+|console=${CONSOLE},${BAUDRATE}|g" "$EXTLINUX" || true
fi

# 7. 主机名与版本标记
echo "tn3399-v3" > "${MNT}/root/etc/hostname"
sed -i 's|127\.0\.1\.1[[:space:]].*|127.0.1.1\ttn3399-v3|' "${MNT}/root/etc/hosts" || true
if [[ -f "${MNT}/root/etc/armbian-release" ]]; then
    sed -i 's|^BOARD=.*|BOARD=tn3399-v3|' "${MNT}/root/etc/armbian-release" || true
    sed -i 's|^BOARD_NAME=.*|BOARD_NAME="TN3399_V3"|' "${MNT}/root/etc/armbian-release" || true
    sed -i 's|^BOARDFAMILY=.*|BOARDFAMILY=rockchip64|' "${MNT}/root/etc/armbian-release" || true
fi
cat > "${MNT}/root/etc/tn3399-v3-release" <<EOF
BOARD=TN3399_V3
SOC=RK3399
VENDOR_KERNEL=${KVER}
KERNEL_BRANCH=${KERNEL_REF}
DTB=${FDT_FILE}
MPP_COMMIT=${MPP_COMMIT}
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# 8. 首次启动一次性服务：根分区扩容 + 交互式初始化
# Armbian 镜像自带 armbian-resize-filesystem，但项目需要显式接管：
# 安装自有的一次性 service（复用 Armbian 脚本），并移除原服务的 wants 软链接，
# 避免两个服务同时修改 MBR 分区表。
info "安装首次启动一次性服务"
ensure_dir "${MNT}/root/usr/local/sbin"
ensure_dir "${MNT}/root/usr/lib/systemd/system"
for UNIT in tn3399-firstboot-resize tn3399-firstboot-setup; do
    install -m 0755 "${ROOTFS_DIR}/${UNIT}" "${MNT}/root/usr/local/sbin/${UNIT}"
    install -m 0644 "${ROOTFS_DIR}/${UNIT}.service" \
        "${MNT}/root/usr/lib/systemd/system/${UNIT}.service"
done

# 扩容：early boot，挂在 basic.target.wants
ensure_dir "${MNT}/root/etc/systemd/system/basic.target.wants"
rm -f "${MNT}/root/etc/systemd/system/basic.target.wants/armbian-resize-filesystem.service"
ln -sfn /usr/lib/systemd/system/tn3399-firstboot-resize.service \
    "${MNT}/root/etc/systemd/system/basic.target.wants/tn3399-firstboot-resize.service"

# 交互式初始化：首次成功进入多用户模式后，挂在 multi-user.target.wants
ensure_dir "${MNT}/root/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/tn3399-firstboot-setup.service \
    "${MNT}/root/etc/systemd/system/multi-user.target.wants/tn3399-firstboot-setup.service"

# 新镜像必须处于“未初始化”状态；清理可能从基础镜像带入的旧标记。
rm -f "${MNT}/root/root/.no_rootfs_resize"
rm -f "${MNT}/root/var/lib/tn3399-firstboot-resize.done"
rm -f "${MNT}/root/var/lib/tn3399-firstboot-setup.done"
rm -f "${MNT}/root/etc/tn3399-mirror.choice" "${MNT}/root/etc/tn3399-kernel-lock"

info "同步文件系统"
sync

info "最终镜像已生成: ${FINAL_IMG}"
ls -lh "$FINAL_IMG"
