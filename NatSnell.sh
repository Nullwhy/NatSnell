#!/bin/bash
# =========================================================
# 项目: NatSnell (专为 NAT / LXC 优化版)
# 仓库: Nullwhy/NatSnell
# 描述: 用于快速部署与管理 Snell + ShadowTLS 节点，集成 BBR 管理与同网段邻居域名 Top 3 扫描
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

current_version="1.3"
SNELL_VERSION="5"
NEIGHBOR_TOP_N=3
NEIGHBOR_MAX_CANDIDATES=50
LAST_BEST_SNI=""

BBR_SYSCTL="/etc/sysctl.d/99-snell-bbr.conf"
BBR_MODULES="/etc/modules-load.d/snell-bbr.conf"
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_REPO="http://deb.xanmod.org"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
CPUINFO="${BBR_CPUINFO:-/proc/cpuinfo}"
BBR_KEYS="net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem"

check_status() {
    local service_name=$1
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    elif systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        echo -e "${RED}○ 已停止${RESET}"
    else
        echo -e "${YELLOW}◌ 未安装${RESET}"
    fi
}

get_current_dns() {
    grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo "未知"
}

current_cc()    { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知"; }
current_qdisc() { sysctl -n net.core.default_qdisc 2>/dev/null; }
available_cc()  { cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "未知"; }
bbr_available() { available_cc | grep -qw bbr; }

kernel_at_least() {
    local v maj min
    v=$(uname -r)
    maj=${v%%.*}
    v=${v#*.}
    min=${v%%[!0-9]*}
    [ "${maj:-0}" -gt "$1" ] \vert{}\vert{} { [ "${maj:-0}" -eq "$1" ] && [ "${min:-0}" -ge "$2" ]; }
}

in_container() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt -c -q && return 0
        [ "$(systemd-detect-virt 2>/dev/null)" = "openvz" ] && return 0
        return 1
    fi
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] && return 0
    grep -qa 'container=' /proc/1/environ 2>/dev/null && return 0
    [ -d /proc/vz ] && [ ! -d /proc/bc ]
}

secure_boot_on() {
    local f
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [ -r "$f" ] || continue
        [ "$(od -An -t u1 "$f" 2>/dev/null \vert{} awk '{print $NF}')" = "1" ] && return 0
    done
    return 1
}

xanmod_suite_ok() {
    [ "$(curl -s -o /dev/null -w '\%{http_code}' --max-time 15 "${XANMOD_REPO}/dists/$1/Release")" = "200" ]
}

xanmod_running() {
    uname -r | grep -qi xanmod
}

xanmod_installed() {
    command -v dpkg-query >/dev/null 2>&1 && \
        dpkg-query -W -f='${Status}${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | grep -q '^install ok installed'
}

fix_legacy_xanmod_repo() {
    [ -f "$XANMOD_
