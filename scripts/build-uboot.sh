#!/usr/bin/env bash
# 构建主线 U-Boot v2026.01（带 retro98boy 的 TN3399_V3 板级补丁，binman 场景）。
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_cmd make gcc "$CROSS_COMPILE"gcc dtc python3 patch
UBOOT_DIR="${SOURCES_DIR}/u-boot"
RKBIN_DIR="${SOURCES_DIR}/rkbin"
OUT_DIR="${OUTPUT_DIR}/bootloader"
PATCH="${CONFIG_DIR}/u-boot/0001-add-tn3399-v3.patch"

[[ -f "${UBOOT_DIR}/Makefile" ]] || die "未找到 U-Boot 源码，请先执行 make fetch"

# DDR blob：默认用 rkbin 源码树中的相对路径；若指向 firmware/ 中自带的旧版
# （如 v1.24 已从新版 rkbin 移除）则优先取项目自带文件。
DDR_PATH="${RKBIN_DIR}/${DDR_BLOB}"
if [[ ! -f "$DDR_PATH" ]]; then
    DDR_PATH="${FIRMWARE_DIR}/$(basename "$DDR_BLOB")"
fi
[[ -f "$DDR_PATH" ]] || die "未找到 DDR blob: ${DDR_BLOB}（rkbin 与 firmware/ 中均无）"
BL31_PATH="${RKBIN_DIR}/${BL31_BLOB}"
[[ -f "$BL31_PATH" ]] || die "未找到 BL31: ${BL31_PATH}"
info "DDR blob: ${DDR_PATH}"
info "BL31:     ${BL31_PATH}"

cd "$UBOOT_DIR"

if [[ ! -f .tn3399-patched ]]; then
    if [[ -f configs/tn3399-v3-rk3399_defconfig ]]; then
        warn "补丁似乎已应用，跳过"
        touch .tn3399-patched
    elif patch -p1 --dry-run < "$PATCH" >/dev/null 2>&1; then
        info "应用 TN3399_V3 U-Boot 补丁"
        patch -p1 < "$PATCH"
        touch .tn3399-patched
    else
        die "U-Boot 补丁无法应用，请检查源码版本是否为 ${UBOOT_REF}"
    fi
fi

info "U-Boot defconfig: tn3399-v3-rk3399_defconfig"
make distclean >/dev/null 2>&1 || true
make tn3399-v3-rk3399_defconfig

export BL31="${BL31_PATH}"
export ROCKCHIP_TPL="${DDR_PATH}"
export CROSS_COMPILE

info "编译 U-Boot（binman 输出 u-boot-rockchip.bin）"
make -j"$(nproc)"

ensure_dir "$OUT_DIR"
for f in u-boot-rockchip.bin idbloader.img u-boot.itb u-boot.dtb; do
    [[ -f "$f" ]] && cp -f "$f" "$OUT_DIR/"
done
[[ -f "${OUT_DIR}/u-boot-rockchip.bin" ]] || die "未生成 u-boot-rockchip.bin"

info "U-Boot 输出目录: ${OUT_DIR}"
ls -lh "$OUT_DIR"
