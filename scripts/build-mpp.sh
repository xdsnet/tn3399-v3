#!/usr/bin/env bash
# 交叉编译 Rockchip MPP 用户态库与测试程序。
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_cmd cmake make "$CROSS_COMPILE"gcc "$CROSS_COMPILE"g++
MPP_DIR="${SOURCES_DIR}/mpp"
BUILD_DIR="${MPP_DIR}/build/tn3399"
OUT_DIR="${OUTPUT_DIR}/mpp"

[[ -f "${MPP_DIR}/CMakeLists.txt" ]] || die "未找到 MPP 源码，请先执行 make fetch"

TOOLCHAIN_FILE="${MPP_DIR}/build/linux/aarch64/arm.linux.cross.cmake"
[[ -f "$TOOLCHAIN_FILE" ]] || die "未找到 MPP 交叉编译工具链文件: $TOOLCHAIN_FILE"

rm -rf "$BUILD_DIR"
ensure_dir "$BUILD_DIR"
cd "$BUILD_DIR"

info "配置 MPP（TOOLCHAIN=${CROSS_COMPILE}）"
cmake -DCMAKE_BUILD_TYPE=Release \
      -DTOOLCHAIN="${CROSS_COMPILE}" \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -G "Unix Makefiles" \
      "$MPP_DIR"

info "编译 MPP"
cmake --build . -j"$(nproc)"

info "安装 MPP 到 ${OUT_DIR}（DESTDIR 方式）"
rm -rf "$OUT_DIR"
ensure_dir "$OUT_DIR"
DESTDIR="$OUT_DIR" cmake --install .

info "MPP 输出目录: ${OUT_DIR}"
find "$OUT_DIR" -maxdepth 4 -type f | sort | head -40
