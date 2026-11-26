#!/usr/bin/env bash
# 在 KVM 虚拟机内执行构建（脱敏/参数化版本）。
#
# 设计目标：
#   - 仓库中不含任何真实 IP、用户名、密钥路径或虚拟机名（全部来自 config/vm.env，已 gitignore）。
#   - 支持两种连接方式：guest-agent（推荐，无需 SSH 凭据）与 ssh。
#   - 宿主机只负责"同步源文件 → 触发 VM 内 make → 回拷产物"，重负载编译在 VM 内完成。
#
# 用法：
#   bash scripts/build-in-vm.sh check                 # 检查连接与配置
#   bash scripts/build-in-vm.sh sync                  # 同步项目源文件到 VM
#   bash scripts/build-in-vm.sh run <make-target>...  # 在 VM 内执行 make 目标
#   bash scripts/build-in-vm.sh pull                  # 回拷 VM 的 output/ 到宿主机
#   bash scripts/build-in-vm.sh all                   # sync + make all + pull
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/config"
VM_ENV="${CONFIG_DIR}/vm.env"
VM_ENV_EXAMPLE="${CONFIG_DIR}/vm.env.example"

info() { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$VM_ENV" ]] || die "未找到 ${VM_ENV}。请复制 ${VM_ENV_EXAMPLE} 为 ${VM_ENV} 并填写你的环境值（该文件不会入库）。"
# shellcheck disable=SC1090
source "$VM_ENV"

: "${VM_CONNECT:=guest-agent}"
: "${VM_LIBVIRT_URI:=qemu:///system}"
: "${VM_NAME:=tn3399-builder}"
: "${VM_SSH_TARGET:=}"
: "${VM_SSH_PORT:=22}"
: "${VM_SSH_KEY:=}"
: "${VM_PROJECT_DIR:=/home/user/tn3399}"
: "${VM_SYNC_SOURCE:=1}"
: "${VM_PULL_OUTPUT:=1}"

# 拼接 SSH 选项（不打印密钥内容，仅用于命令参数）
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -p "${VM_SSH_PORT}")
[[ -n "$VM_SSH_KEY" ]] && SSH_OPTS+=(-i "${VM_SSH_KEY/#\~/$HOME}")

# ---------- 传输通道抽象 ----------
# vm_run '<远程 shell 命令>'：[guest-agent] 直接执行；[ssh] 通过 ssh 执行。
vm_run() {
    local cmd="$1"
    if [[ "$VM_CONNECT" == "guest-agent" ]]; then
        python3 "${SCRIPT_DIR}/vm-exec.py" --uri "$VM_LIBVIRT_URI" "$VM_NAME" "$cmd" 3600
    elif [[ "$VM_CONNECT" == "ssh" ]]; then
        [[ -n "$VM_SSH_TARGET" ]] || die "VM_CONNECT=ssh 时必须设置 VM_SSH_TARGET"
        ssh "${SSH_OPTS[@]}" "$VM_SSH_TARGET" "$cmd"
    else
        die "未知 VM_CONNECT=${VM_CONNECT}（应为 guest-agent 或 ssh）"
    fi
}

# vm_put <本地文件> <远程路径>：把文件放进 VM。
vm_put() {
    local src="$1" dst="$2"
    if [[ "$VM_CONNECT" == "ssh" ]]; then
        [[ -n "$VM_SSH_TARGET" ]] || die "VM_CONNECT=ssh 时必须设置 VM_SSH_TARGET"
        scp "${SSH_OPTS[@]}" "$src" "${VM_SSH_TARGET}:${dst}"
    else
        # guest-agent 无文件通道：用 base64 通过 guest-exec 传输（适合小文件）
        local b64
        b64="$(base64 -w0 "$src")"
        vm_run "mkdir -p '\$(dirname '$dst')' && printf %s '$b64' | base64 -d > '$dst'"
    fi
}

# vm_get <远程路径> <本地文件>：从 VM 取回文件。
vm_get() {
    local src="$1" dst="$2"
    if [[ "$VM_CONNECT" == "ssh" ]]; then
        mkdir -p "$(dirname "$dst")"
        scp "${SSH_OPTS[@]}" "${VM_SSH_TARGET}:${src}" "$dst"
    else
        # guest-agent：远程 base64 输出，本地解码（适合中等大小产物；超大镜像建议用 ssh/scp）
        local b64
        b64="$(vm_run "base64 -w0 '$src'")"
        mkdir -p "$(dirname "$dst")"
        printf '%s' "$b64" | base64 -d > "$dst"
    fi
}

# ---------- 子命令 ----------
cmd_check() {
    info "VM 构建配置（已脱敏）："
    printf '  连接方式 : %s\n' "$VM_CONNECT"
    printf '  虚拟机名 : %s\n' "$VM_NAME"
    printf '  VM 项目目录: %s\n' "$VM_PROJECT_DIR"
    if [[ "$VM_CONNECT" == "ssh" ]]; then
        printf '  SSH 目标 : %s\n' "$VM_SSH_TARGET"
        printf '  SSH 密钥 : %s\n' "${VM_SSH_KEY:+<已配置>}${VM_SSH_KEY:-<使用默认>}"
    fi
    info "测试连接..."
    vm_run "echo VM_OK; uname -m; nproc; free -m | head -2; df -h '$VM_PROJECT_DIR' | tail -1" \
        || die "无法连接虚拟机，请检查 config/vm.env 配置"
}

cmd_sync() {
    info "打包宿主机项目源文件（config/scripts/docs/Makefile）..."
    local tarball
    tarball="$(mktemp /tmp/tn3399-src.XXXXXX.tar.gz)"
    tar czf "$tarball" -C "$PROJECT_ROOT" Makefile README.md .gitignore config scripts docs
    vm_run "mkdir -p '$VM_PROJECT_DIR'"
    vm_put "$tarball" "${VM_PROJECT_DIR}/.tn3399-sync.tar.gz"
    info "在 VM 内解包（保留 sources/output/firmware 不被覆盖）..."
    vm_run "cd '$VM_PROJECT_DIR' && tar xzf .tn3399-sync.tar.gz && chmod +x scripts/*.sh scripts/*.py && echo SYNC_OK"
    rm -f "$tarball"
}

cmd_run() {
    local targets=("$@")
    [[ ${#targets[@]} -gt 0 ]] || targets=("$VM_MAKE_TARGET")
    info "在 VM 内执行: make ${targets[*]}"
    vm_run "cd '$VM_PROJECT_DIR' && make ${targets[*]}"
}

cmd_pull() {
    info "回拷 VM 产物到宿主机 output/ ..."
    mkdir -p "${PROJECT_ROOT}/output"
    # 优先按目录逐个取回；guest-agent 模式对超大镜像改用 ssh 提示
    vm_run "cd '$VM_PROJECT_DIR' && find output -type f 2>/dev/null | sed 's#^output/##'" > "${PROJECT_ROOT}/.vm-filelist"
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        vm_get "${VM_PROJECT_DIR}/output/${rel}" "${PROJECT_ROOT}/output/${rel}"
    done < "${PROJECT_ROOT}/.vm-filelist"
    rm -f "${PROJECT_ROOT}/.vm-filelist"
    info "回拷完成。"
}

cmd_all() {
    [[ "$VM_SYNC_SOURCE" == "1" ]] && cmd_sync
    cmd_run all
    [[ "$VM_PULL_OUTPUT" == "1" ]] && cmd_pull
}

case "${1:-help}" in
    check) cmd_check ;;
    sync)  cmd_sync ;;
    run)   shift; cmd_run "$@" ;;
    pull)  cmd_pull ;;
    all)   cmd_all ;;
    *)
        printf '%s\n' \
          '用法: bash scripts/build-in-vm.sh <子命令> [参数]' \
          '  check              检查 VM 连接与配置' \
          '  sync               同步项目源文件到 VM' \
          '  run <make目标>...  在 VM 内执行 make（默认 all）' \
          '  pull               回拷 VM 产物到宿主机 output/' \
          '  all                sync + make all + pull'
        ;;
esac
