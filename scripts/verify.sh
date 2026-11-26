#!/usr/bin/env bash
# 离线校验：确认 dtb 名称、compatible、U-Boot/内核配置与产物完整性。
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_cmd grep

HAVE_DTC=0
command -v dtc >/dev/null 2>&1 && HAVE_DTC=1

FAIL=0
check() {
    if eval "$2"; then
        printf '  [OK]   %s\n' "$1"
    else
        printf '  [FAIL] %s\n' "$1" >&2
        FAIL=1
    fi
}

info "===== 源码与配置校验 ====="
check "板级 DTS 存在" "test -f '${CONFIG_DIR}/kernel/rk3399-tn3399-v3.dts'"
check "DTS compatible 正确" "grep -q 'compatible = \"tiannuo,tn3399-v3\", \"rockchip,rk3399\"' '${CONFIG_DIR}/kernel/rk3399-tn3399-v3.dts'"
check "DTS 使用 vendor rk3399-linux.dtsi (MPP)" "grep -q '#include \"rk3399-linux.dtsi\"' '${CONFIG_DIR}/kernel/rk3399-tn3399-v3.dts'"
check "U-Boot 默认 FDT 名称正确" "grep -q 'CONFIG_DEFAULT_DEVICE_TREE=\"rockchip/rk3399-tn3399-v3\"' '${CONFIG_DIR}/u-boot/0001-add-tn3399-v3.patch'"
check "U-Boot 串口 1500000" "grep -q 'CONFIG_BAUDRATE=1500000' '${CONFIG_DIR}/u-boot/0001-add-tn3399-v3.patch'"
check "内核配置启用 MPP service" "grep -q '^CONFIG_ROCKCHIP_MPP_SERVICE=y' '${CONFIG_DIR}/kernel/tn3399-v3.config'"
check "内核配置启用 AP6255 bcmdhd" "grep -q '^CONFIG_BCMDHD=m' '${CONFIG_DIR}/kernel/tn3399-v3.config'"
check "内核配置启用 RTL8211E PHY" "grep -q '^CONFIG_REALTEK_PHY=y' '${CONFIG_DIR}/kernel/tn3399-v3.config'"
check "首次启动扩容脚本存在且可执行" "test -x '${ROOTFS_DIR}/tn3399-firstboot-resize'"
check "首次启动扩容 service 存在" "test -f '${ROOTFS_DIR}/tn3399-firstboot-resize.service'"
check "扩容脚本复用 Armbian 官方实现" "grep -q 'armbian-resize-filesystem' '${ROOTFS_DIR}/tn3399-firstboot-resize'"
check "镜像组装脚本安装扩容服务" "grep -q 'tn3399-firstboot-resize.service' '${PROJECT_ROOT}/scripts/assemble-image.sh'"
check "首次启动初始化脚本存在且可执行" "test -x '${ROOTFS_DIR}/tn3399-firstboot-setup'"
check "首次启动初始化 service 存在" "test -f '${ROOTFS_DIR}/tn3399-firstboot-setup.service'"
check "初始化脚本覆盖密码/用户/镜像/内核/主机" "grep -q 'passwd root' '${ROOTFS_DIR}/tn3399-firstboot-setup' && grep -q 'usermod -aG' '${ROOTFS_DIR}/tn3399-firstboot-setup' && grep -q 'apt-mark hold' '${ROOTFS_DIR}/tn3399-firstboot-setup' && grep -q 'hostnamectl' '${ROOTFS_DIR}/tn3399-firstboot-setup'"
check "镜像组装脚本安装初始化服务" "grep -q 'tn3399-firstboot-setup.service' '${PROJECT_ROOT}/scripts/assemble-image.sh'"

info "===== 构建产物校验 ====="
DTB="${OUTPUT_DIR}/kernel/${DTB_NAME}"
if [[ -f "$DTB" ]]; then
    if [[ $HAVE_DTC -eq 1 ]]; then
        tmp="$(mktemp)"
        dtc -I dtb -O dts -o "$tmp" "$DTB" >/dev/null 2>&1 || true
        check "DTB 可反编译" "test -s '$tmp'"
        check "DTB compatible=tiannuo,tn3399-v3" "grep -q 'tiannuo,tn3399-v3' '$tmp'"
        # vendor 6.1 DTS 生成的节点名为 mpp-srv（连字符），主线为 mpp_service（下划线）
        check "DTB 含 MPP service 节点" "grep -qE 'mpp[-_]srv|mpp[-_]service' '$tmp'"
        rm -f "$tmp"
    else
        warn "未安装 dtc，跳过 DTB 反编译校验（可执行 apt install device-tree-compiler）"
    fi
else
    warn "尚未构建 DTB: ${DTB}（执行 make kernel 后重新校验）"
fi

STRICT="${STRICT:-0}"
artifact_check() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        check "$label" "test -e '$path'"
    elif [[ "$STRICT" == "1" ]]; then
        check "$label" "test -e '$path'"
    else
        warn "尚未生成: ${path}（STRICT=1 时此项会判为失败）"
    fi
}
artifact_check "U-Boot 产物存在" "${OUTPUT_DIR}/bootloader/u-boot-rockchip.bin"
artifact_check "内核 Image 存在" "${OUTPUT_DIR}/kernel/Image"
artifact_check "MPP 库已构建" "${OUTPUT_DIR}/mpp/usr/lib"

FINAL="$(find "${OUTPUT_DIR}" -maxdepth 1 -name 'Armbian_TN3399_V3_*.img' | head -1 || true)"
if [[ -n "$FINAL" ]]; then
    check "最终镜像存在" "test -s '$FINAL'"
    if command -v xxd >/dev/null 2>&1; then
        check "U-Boot 写入 32KiB 偏移" "test \"\$(dd if='$FINAL' bs=1 skip=32768 count=4 status=none | xxd -p)\" != '00000000'"
    else
        check "U-Boot 写入 32KiB 偏移" "test \"\$(dd if='$FINAL' bs=1 skip=32768 count=4 status=none | od -An -tx1 | tr -d ' \\n')\" != '00000000'"
    fi
else
    warn "尚未生成最终镜像（执行 make image 后重新校验）"
fi

if [[ $FAIL -eq 0 ]]; then
    info "所有可执行校验通过。"
else
    die "存在校验失败项，请检查上方 [FAIL]。"
fi
