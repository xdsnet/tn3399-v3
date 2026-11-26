#!/usr/bin/env bash
# 下载所有固定版本的源码、基础镜像与板级固件。
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_cmd git curl xz sha256sum file tar

info "===== 1/6 U-Boot ====="
fetch_repo "u-boot/u-boot" "$UBOOT_COMMIT" "${SOURCES_DIR}/u-boot" u-boot

info "===== 2/6 rkbin ====="
fetch_repo "rockchip-linux/rkbin" "$RKBIN_COMMIT" "${SOURCES_DIR}/rkbin" rkbin

info "===== 3/6 Vendor 内核 6.1 ====="
fetch_repo "armbian/linux-rockchip" "$KERNEL_COMMIT" "${SOURCES_DIR}/linux-rockchip" linux-rockchip

info "===== 4/6 MPP 用户态库 ====="
fetch_repo "rockchip-linux/mpp" "$MPP_COMMIT" "${SOURCES_DIR}/mpp" mpp

info "===== 5/6 Armbian 基础镜像 ====="
base_name="$(basename "$ARMBIAN_BASE_URL")"
fetch_file "$ARMBIAN_BASE_URL" "${SOURCES_DIR}/base/${base_name}" "$ARMBIAN_BASE_SHA"

info "===== 6/6 AP6255 固件 / Loader / UCM ====="
fetch_file "${TN3399_FIRMWARE_BASE}/ap6255-firmware/bsp/fw_bcm43455c0_ag.bin" \
    "${FIRMWARE_DIR}/brcm/fw_bcm43455c0_ag.bin"
fetch_file "${TN3399_FIRMWARE_BASE}/ap6255-firmware/bsp/fw_bcm43455c0_ag_apsta.bin" \
    "${FIRMWARE_DIR}/brcm/fw_bcm43455c0_ag_apsta.bin"
fetch_file "${TN3399_FIRMWARE_BASE}/ap6255-firmware/bsp/fw_bcm43455c0_ag_p2p.bin" \
    "${FIRMWARE_DIR}/brcm/fw_bcm43455c0_ag_p2p.bin"
fetch_file "${TN3399_FIRMWARE_BASE}/ap6255-firmware/bsp/nvram_ap6255.txt" \
    "${FIRMWARE_DIR}/brcm/nvram_ap6255.txt"
fetch_file "${TN3399_FIRMWARE_BASE}/ap6255-firmware/bsp/BCM4345C0.hcd" \
    "${FIRMWARE_DIR}/brcm/BCM4345C0.hcd"
fetch_file "${TN3399_FIRMWARE_BASE}/tools/${USB_LOADER}" \
    "${FIRMWARE_DIR}/${USB_LOADER}"

ucm_base="https://raw.githubusercontent.com/retro98boy/armbian-build/main/packages/bsp/tiannuo-tn3399-v3"
fetch_file "${ucm_base}/tn3399-v3.conf" "${FIRMWARE_DIR}/ucm/tn3399-v3.conf"
fetch_file "${ucm_base}/tn3399-v3-HiFi.conf" "${FIRMWARE_DIR}/ucm/tn3399-v3-HiFi.conf"

info "全部源码与固件已就绪。"
