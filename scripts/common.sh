#!/usr/bin/env bash
# 公共函数库：日志、校验、下载、Git 克隆
set -euo pipefail

# 部分容器/精简环境的 PATH 不含 /usr/sbin，导致 losetup/partprobe 等命令"消失"。
case ":${PATH}:" in
    *:/usr/sbin:*) ;;
    *) PATH="${PATH}:/usr/sbin:/sbin"; export PATH ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/config"
SOURCES_DIR="${PROJECT_ROOT}/sources"
OUTPUT_DIR="${PROJECT_ROOT}/output"
FIRMWARE_DIR="${PROJECT_ROOT}/firmware"
ROOTFS_DIR="${CONFIG_DIR}/rootfs"

# shellcheck disable=SC1091
source "${CONFIG_DIR}/project.env"

info()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
run()   { info "执行: $*"; "$@"; }

ensure_dir() { mkdir -p "$1"; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "缺少命令: ${c}，请先安装。"
    done
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# 对 GitHub 的 raw / codeload / github.com URL 自动加国内代理前缀。
proxy_url() {
    local url="$1"
    if [[ "${USE_GH_PROXY:-0}" != "1" || -z "${GH_PROXY:-}" ]]; then
        printf '%s' "$url"
        return
    fi
    case "$url" in
        https://github.com/*|https://raw.githubusercontent.com/*|https://codeload.github.com/*)
            printf '%s/%s' "${GH_PROXY%/}" "$url"
            ;;
        *)
            printf '%s' "$url"
            ;;
    esac
}

# fetch_repo <owner/repo> <commit> <dest> <name>
# 用 codeload tarball 代替 git clone：代理支持好、可重试、不受 git 协议卡顿影响。
fetch_repo() {
    local repo="$1" commit="$2" dest="$3" name="$4"
    local marker="${dest}/.tn3399-fetched"
    local tarball_dir="${SOURCES_DIR}/.tarballs"
    local tarball="${tarball_dir}/${name}-${commit}.tar.gz"
    local url staging

    ensure_dir "$tarball_dir"
    if [[ -f "$marker" ]] && grep -q "$commit" "$marker" && [[ -f "${dest}/Makefile" || -f "${dest}/CMakeLists.txt" ]]; then
        info "已存在且版本一致，跳过: ${dest}"
        return 0
    fi

    url="$(proxy_url "https://codeload.github.com/${repo}/tar.gz/${commit}")"
    if [[ ! -s "$tarball" ]]; then
        info "下载 ${name} (${commit})"
        info "  ${url}"
        curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 30 --max-time 1800 \
             -o "${tarball}.part" "$url" \
             || die "下载失败: ${url}"
        file "${tarball}.part" | grep -qi 'gzip compressed' \
             || die "下载内容不是 gzip tarball，请检查代理是否返回错误页: ${url}"
        mv -f "${tarball}.part" "$tarball"
    else
        info "复用已下载 tarball: ${tarball}"
    fi

    staging="${dest}.staging.$$"
    rm -rf "$staging"
    mkdir -p "$staging"
    # -m/--touch：不恢复 tarball 里的 mtime。容器/overlay 文件系统上恢复时间戳可能
    # 触发大量 "无法 utime: 不允许的操作" 并使 tar 返回失败，对构建内容无影响。
    tar -xzmf "$tarball" -C "$staging" --strip-components=1 \
        2>>"${tarball_dir}/extract-warnings.log" \
        || die "解压失败: ${tarball}（详见 ${tarball_dir}/extract-warnings.log）"
    rm -rf "$dest"
    mv "$staging" "$dest"
    printf '%s\n' "$commit" > "$marker"
    info "已就绪: ${dest}"
}

# fetch_file <url> <dest> [sha256]
fetch_file() {
    local url="$1" dest="$2" sha="${3:-}" tmp
    ensure_dir "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        if [[ -z "$sha" ]] || [[ "$(sha256_of "$dest")" == "$sha" ]]; then
            info "已存在，跳过: ${dest}"
            return 0
        fi
        warn "已有文件校验不匹配，重新下载: ${dest}"
    fi
    tmp="${dest}.part"
    local fetch_url max_time="${FETCH_MAX_TIME:-7200}"
    fetch_url="$(proxy_url "$url")"
    info "下载: ${fetch_url}"
    local ok=0
    for i in 1 2 3 4 5; do
        # -C - 断点续传：超时/中断后保留已下载部分，下次从断点继续（不归零）。
        if curl -fsSL -C - --retry 2 --retry-delay 2 --connect-timeout 30 \
                --max-time "$max_time" -o "$tmp" "$fetch_url"; then
            ok=1
            break
        fi
        warn "下载中断（第 ${i}/5 次），保留断点续传: ${url}（已下载 $(du -h "$tmp" 2>/dev/null | cut -f1 || echo 0)）"
        [[ $i -eq 5 ]] && break
        sleep 3
    done
    [[ $ok -eq 1 ]] || die "下载失败（已重试 5 次）: ${url}"
    if [[ -n "$sha" ]]; then
        local got
        got="$(sha256_of "$tmp")"
        [[ "$got" == "$sha" ]] || die "SHA256 校验失败: ${dest} (got=${got}, want=${sha})"
    fi
    mv -f "$tmp" "$dest"
}

# clone_ref <repo> <ref> <dest> [commit]
clone_ref() {
    local repo="$1" ref="$2" dest="$3" commit="${4:-}" i
    if [[ -d "${dest}/.git" ]]; then
        info "已存在仓库，跳过: ${dest}"
        return 0
    fi
    rm -rf "$dest"
    ensure_dir "$(dirname "$dest")"
    info "克隆 ${repo} (${ref}) -> ${dest}"
    for i in 1 2 3; do
        if git -c http.version=HTTP/1.1 clone --depth 1 --branch "$ref" "$repo" "$dest"; then
            break
        fi
        warn "克隆失败（第 ${i}/3 次）: ${repo}"
        rm -rf "$dest"
        [[ $i -eq 3 ]] && die "克隆失败: ${repo}"
    done
    if [[ -n "$commit" ]]; then
        local head
        head="$(git -C "$dest" rev-parse HEAD)"
        if [[ "$head" != "$commit" ]]; then
            info "固定到指定 commit: ${commit}"
            git -C "$dest" fetch --depth 1 origin "$commit" || true
            git -C "$dest" checkout -q "$commit" || die "无法切换到 ${commit}"
        fi
    fi
}

# 检查是否为 root（仅组装镜像和解包 rootfs 需要）
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "此步骤需要 root 权限（losetup/mount/chroot）。请用 sudo 执行。"
}
