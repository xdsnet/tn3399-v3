#!/usr/bin/env bash
# 构建 Rockchip vendor 6.1 内核，集成 TN3399_V3 BSP 设备树与 MPP 驱动。
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_cmd make gcc "$CROSS_COMPILE"gcc bison flex dtc
KDIR="${SOURCES_DIR}/linux-rockchip"
OUT_DIR="${OUTPUT_DIR}/kernel"
MOD_DIR="${OUTPUT_DIR}/modules"
ensure_dir "$OUTPUT_DIR"

[[ -f "${KDIR}/Makefile" && -f "${KDIR}/arch/arm64/configs/rockchip_linux_defconfig" ]] \
    || die "未找到内核源码，请先执行 make fetch"

cd "$KDIR"

# 1. 安装板级 DTS（BSP 版本：include rk3399-linux.dtsi，自动启用 mpp_srv/rkvdec/vdpu/vepu）
cp -f "${CONFIG_DIR}/kernel/rk3399-tn3399-v3.dts" arch/arm64/boot/dts/rockchip/
DTS_MAKEFILE="arch/arm64/boot/dts/rockchip/Makefile"
# 不同内核版本的目标变量前缀不同（主线用 dt-，vendor BSP 用 dtb-）。
# 探测实际前缀，避免 DTB 被加入无效目标导致静默不编译。
if grep -q '^dtb-' "$DTS_MAKEFILE"; then
    DT_VAR='dtb'
elif grep -q '^dt-' "$DTS_MAKEFILE"; then
    DT_VAR='dt'
else
    DT_VAR='dtb'
fi
if ! grep -q 'rk3399-tn3399-v3.dtb' "$DTS_MAKEFILE"; then
    printf '\n%s-$(CONFIG_ARCH_ROCKCHIP) += rk3399-tn3399-v3.dtb\n' "$DT_VAR" >> "$DTS_MAKEFILE"
fi

# 2. 生成板级 defconfig（原厂 defconfig + 本板补充选项）
DEFCONFIG="arch/arm64/configs/tn3399_v3_defconfig"
cat arch/arm64/configs/rockchip_linux_defconfig \
    "${CONFIG_DIR}/kernel/tn3399-v3.config" > "$DEFCONFIG"

export ARCH=arm64
export CROSS_COMPILE

info "内核 defconfig: ${DEFCONFIG}"
make "$(basename "$DEFCONFIG")"

KVER="$(make -s kernelrelease)"
info "内核版本: ${KVER}"
echo "$KVER" > "${OUTPUT_DIR}/kernel-version.txt"

info "编译 Image / dtbs / modules"
make -j"$(nproc)" Image dtbs modules

ensure_dir "$OUT_DIR"
cp -f arch/arm64/boot/Image "${OUT_DIR}/Image"
cp -f "arch/arm64/boot/dts/rockchip/${DTB_NAME}" "${OUT_DIR}/${DTB_NAME}"
[[ -f System.map ]] && cp -f System.map "${OUT_DIR}/System.map"

info "安装模块到 ${MOD_DIR}"
rm -rf "$MOD_DIR"
ensure_dir "$MOD_DIR"
make INSTALL_MOD_PATH="$MOD_DIR" modules_install
# 去掉模块安装产生的符号链接，便于复制到 rootfs
find "$MOD_DIR/lib/modules" -maxdepth 2 -type l -delete 2>/dev/null || true

info "内核输出: ${OUT_DIR}; 模块输出: ${MOD_DIR}/${KVER}"
ls -lh "$OUT_DIR"
