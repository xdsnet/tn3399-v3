#!/usr/bin/env bash
# 深度校验构建产物：文件类型、DTB 结构/节点、Image 架构、MPP 库、最终镜像分区与关键偏移。
# 可在宿主机、KVM 内的 Linux 虚拟机中运行；只读，不修改任何产物。
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

FAIL=0
check() {
    local label="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        printf '  [OK]   %s\n' "$label"
    else
        printf '  [FAIL] %s\n' "$label" >&2
        FAIL=1
    fi
}
warn_skip() { printf '  [SKIP] %s\n' "$*" >&2; }

DTB="${OUTPUT_DIR}/kernel/${DTB_NAME}"
KIMAGE="${OUTPUT_DIR}/kernel/Image"
UBOOT="${OUTPUT_DIR}/bootloader/u-boot-rockchip.bin"
FINAL="$(find "${OUTPUT_DIR}" -maxdepth 1 -name 'Armbian_TN3399_V3_*.img' 2>/dev/null | head -1 || true)"

info "===== 1. 文件类型与架构 ====="
if command -v file >/dev/null 2>&1; then
    [[ -f "$UBOOT" ]] && check "U-Boot 二进制存在且非文本" "file '$UBOOT' | grep -v -q 'ASCII text'"
    [[ -f "$KIMAGE" ]] && check "内核 Image 为 ARM64 可执行镜像" "file '$KIMAGE' | grep -q -E 'ARM aarch64|ARM64|ELF 64-bit.*ARM'"
    [[ -f "$DTB" ]] && check "DTB 为 flattened device tree blob" "file '$DTB' | grep -qi 'device tree'"
else
    warn_skip "未安装 file，跳过文件类型检查"
fi

# 内核 Image 是裸的 boot 镜像（非 ELF），用 file 识别架构即可。
if command -v file >/dev/null 2>&1; then
    [[ -f "$KIMAGE" ]] && check "内核 Image 为 ARM64 boot 镜像" \
        "file '$KIMAGE' | grep -qiE 'ARM64|ARM aarch64'"
fi

info "===== 2. 设备树结构校验 ====="
DTB_TXT=""
if [[ -f "$DTB" ]]; then
    if command -v dtc >/dev/null 2>&1; then
        DTB_TXT="$(mktemp)"
        if dtc -I dtb -O dts -o "$DTB_TXT" "$DTB" >/dev/null 2>&1; then
            check "DTB 可反编译" "test -s '$DTB_TXT'"
            check "compatible 含 tiannuo,tn3399-v3" "grep -q 'tiannuo,tn3399-v3' '$DTB_TXT'"
            check "compatible 含 rockchip,rk3399" "grep -q 'rockchip,rk3399' '$DTB_TXT'"
            check "串口节点 ttyS2 @ ff1a0000" "grep -q 'ff1a0000' '$DTB_TXT'"
            check "ethernet @ fe300000 (RTL8211E GMAC)" "grep -q 'fe300000' '$DTB_TXT'"
            check "dwmmc @ fe310000 (SDIO WiFi)" "grep -q 'fe310000' '$DTB_TXT'"
            # 本项目 AP6255 走 vendor bcmdhd 路线（wireless-wlan/ap6255），非主线 brcmfmac
            check "含 AP6255 WiFi 节点 (bcmdhd)" "grep -qiE 'ap6255|wlan-platdata|brcm' '$DTB_TXT'"
            check "含 CPU opp 表（A72/A53）" "grep -qi 'opp' '$DTB_TXT'"
        else
            check "DTB 可反编译" false
        fi
    else
        warn_skip "未安装 dtc，跳过 DTB 结构与节点检查"
    fi
    # DTB 头部 magic 固定为 0xd00dfeed（大端），直接读前 4 字节验证，避免管道重定向陷阱
    if command -v xxd >/dev/null 2>&1; then
        check "DTB header magic 正确 (d00dfeed)" \
            "test \"\$(dd if='$DTB' bs=1 count=4 status=none | xxd -p)\" = 'd00dfeed'"
    fi
else
    warn_skip "尚未构建 DTB: ${DTB}"
fi

info "===== 3. 内核配置与模块 ====="
KCONF="${OUTPUT_DIR}/kernel/.config"
# 对 tristate 模块符号，用 .config 检查（bcmdhd/蓝牙/PHY 都是模块或=y，可靠）
if [[ -f "$KCONF" ]]; then
    for sym in CONFIG_BCMDHD CONFIG_BT_HCIUART_BCM CONFIG_REALTEK_PHY CONFIG_ROCKCHIP_MPP_OSAL; do
        check "内核启用 ${sym}" "grep -q '^${sym}=m\|^${sym}=y' '$KCONF'"
    done
else
    warn_skip "尚未生成内核 .config: ${KCONF}"
fi
# 对 vendor BSP 内建驱动（MPP service/rkvdec/RGA），符号是 bool 子项且不在 .config 显式列出，
# 用 System.map 中的内核符号验证是否真正编进 Image（最权威）。
SYSMAP="${OUTPUT_DIR}/kernel/System.map"
if [[ -f "$SYSMAP" ]]; then
    check "内核含 MPP service 驱动" "grep -q 'mpp_dev_register_srv' '$SYSMAP'"
    check "内核含 RKVDEC 解码驱动" "grep -q 'rkvdec_isr' '$SYSMAP'"
    check "内核含 RGA 2D 加速驱动" "grep -q 'rga_drv_probe' '$SYSMAP'"
else
    warn_skip "未找到 System.map: ${SYSMAP}"
fi
if [[ -d "${OUTPUT_DIR}/modules" ]]; then
    check "内核模块目录非空" "find '${OUTPUT_DIR}/modules' -name '*.ko' -print -quit | grep -q ."
    # vendor 6.1 的 MPP 驱动（mpp_service/rkvdec/vdpu/vepu）编译进内核 Image，非独立 .ko。
    # 用编译产物 System.map 或模块目录中的 MPP_OSAL 判断。
    check "MPP 驱动已编入内核" \
        "grep -q 'CONFIG_ROCKCHIP_MPP_OSAL=y' '${OUTPUT_DIR}/kernel/.config' 2>/dev/null || find '${OUTPUT_DIR}/modules' -name '*mpp*.ko' -print -quit | grep -q ."
    check "存在 bcmdhd 驱动模块" "find '${OUTPUT_DIR}/modules' -name 'bcmdhd.ko' -print -quit | grep -q ."
else
    warn_skip "尚未安装内核模块到 ${OUTPUT_DIR}/modules"
fi

info "===== 4. MPP 用户态库 ====="
if [[ -d "${OUTPUT_DIR}/mpp/usr" ]]; then
    check "MPP 头文件存在" "find '${OUTPUT_DIR}/mpp/usr/include' -name 'mpp*.h' -print -quit | grep -q ."
    check "MPP 动态库存在" "find '${OUTPUT_DIR}/mpp/usr/lib' -name 'librockchip_mpp.so*' -print -quit | grep -q ."
    check "MPP 测试程序存在" "find '${OUTPUT_DIR}/mpp/usr/bin' -name 'mpi_dec_test' -print -quit | grep -q ."
else
    warn_skip "尚未构建 MPP: ${OUTPUT_DIR}/mpp/usr"
fi

info "===== 5. 最终刷机镜像 ====="
if [[ -n "$FINAL" && -f "$FINAL" ]]; then
    check "最终镜像非空" "test -s '$FINAL'"
    if command -v fdisk >/dev/null 2>&1; then
        check "镜像含分区表" "fdisk -l '$FINAL' 2>/dev/null | grep -qi 'Disklabel type\\|Device.*Boot.*Start'"
    fi
    if command -v xxd >/dev/null 2>&1; then
        HEX="$(dd if="$FINAL" bs=1 skip=32768 count=4 status=none | xxd -p)"
    else
        HEX="$(dd if="$FINAL" bs=1 skip=32768 count=4 status=none | od -An -tx1 | tr -d ' \n')"
    fi
    check "U-Boot 在 32KiB 偏移处非空" "test \"$HEX\" != '00000000'"
else
    warn_skip "尚未生成最终镜像"
fi

info "===== 6. 镜像内首次启动一次性服务 ====="
if [[ -n "$FINAL" && -f "$FINAL" && "$(id -u)" -eq 0 ]] && command -v losetup >/dev/null 2>&1; then
    RI_LOOP="$(losetup -f --show -P "$FINAL")"
    RI_MNT="$(mktemp -d /tmp/tn3399-verify-firstboot.XXXXXX)"
    cleanup_firstboot_verify() {
        set +e
        umount -R "$RI_MNT" >/dev/null 2>&1
        losetup -d "$RI_LOOP" >/dev/null 2>&1
        rm -rf "$RI_MNT"
    }
    trap cleanup_firstboot_verify EXIT
    mount -o ro "${RI_LOOP}p1" "$RI_MNT"

    for RI_UNIT in tn3399-firstboot-resize tn3399-firstboot-setup; do
        case "$RI_UNIT" in
            *resize) RI_WANTS="basic.target.wants" ;;
            *setup)  RI_WANTS="multi-user.target.wants" ;;
        esac
        RI_LINK="${RI_MNT}/etc/systemd/system/${RI_WANTS}/${RI_UNIT}.service"
        RI_TARGET="$(readlink "$RI_LINK" 2>/dev/null || true)"
        if [[ "$RI_TARGET" == /* ]]; then
            RI_TARGET_PATH="${RI_MNT}${RI_TARGET}"
        elif [[ -n "$RI_TARGET" ]]; then
            RI_TARGET_PATH="$(dirname "$RI_LINK")/${RI_TARGET}"
        else
            RI_TARGET_PATH=""
        fi
        check "镜像已安装 ${RI_UNIT} 脚本" "test -x '${RI_MNT}/usr/local/sbin/${RI_UNIT}'"
        check "镜像已安装 ${RI_UNIT} service" "test -f '${RI_MNT}/usr/lib/systemd/system/${RI_UNIT}.service'"
        check "镜像已启用 ${RI_UNIT}" "test -L '${RI_LINK}'"
        check "${RI_UNIT} 软链接目标存在" "test -n '${RI_TARGET_PATH}' && test -f '${RI_TARGET_PATH}'"
    done
    check "Armbian 原扩容服务已移除（避免重复执行）" "! test -e '${RI_MNT}/etc/systemd/system/basic.target.wants/armbian-resize-filesystem.service'"
    check "镜像处于未初始化状态" "! test -e '${RI_MNT}/var/lib/tn3399-firstboot-resize.done' && ! test -e '${RI_MNT}/var/lib/tn3399-firstboot-setup.done'"
    check "镜像未带入旧镜像/内核锁记录" "! test -e '${RI_MNT}/etc/tn3399-mirror.choice' && ! test -e '${RI_MNT}/etc/tn3399-kernel-lock'"
    cleanup_firstboot_verify
    trap - EXIT
else
    warn_skip "需要 root 权限和最终镜像才能检查镜像内首次启动服务"
fi

info "===== 7. 结论 ====="
if [[ $FAIL -eq 0 ]]; then
    info "深度产物校验通过（跳过项不计失败）。"
else
    die "深度产物校验存在失败项。"
fi
